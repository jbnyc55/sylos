-- Silo edits arrive as ONE approvable Inbox card.
--
-- Syla could already propose a single include/exclude through
-- syla_approvals kind 'silo_membership', but any real sharing change
-- still left the owner assembling it by hand: create the silo, flip its
-- defaults, write its rules, place the tables, admit the followers —
-- five screens for "share my health data with Anna". This migration adds
-- kind 'silo_edit': one card carrying the whole structured change, which
-- the OWNER'S CLIENT applies on approve. House pattern throughout — the
-- claude role gains no write on silos, silo_rules, table_silos or
-- silo_followers from any of this; it still only inserts pending cards
-- through propose_approval, and nothing happens until the owner taps
-- Approve in the Inbox.
--
-- The payload IS the plan, and the client applies nothing beyond it:
--
--   {
--     "silo_id":   "<uuid>",        an existing silo (wins over silo_name)
--     "silo_name": "health",        else find-or-create by this name
--     "description": "…",           set when the silo is created
--     "default_allows_sql":     true|false,   silo defaults to set
--     "default_allows_prompts": true|false,
--     "default_allows_edits":   true|false,
--     "rules":  [{"kind": "only_include", "body": "health data only"}],
--                                   silo_rules sentences to add
--     "tables": ["health_samples"], whole tables to place (data_tables
--                                   names — every row or none)
--     "remove_tables": ["…"],       placements to lift
--     "followers": [{"follower_id": "<uuid>", "name": "Anna",
--                    "allows_sql": true}],
--                                   silo_followers to admit or update;
--                                   flags omitted = the silo's defaults
--                                   (the seeding trigger), name is
--                                   display only — the id is what applies
--     "remove_followers": ["<uuid>"]
--   }

-- ── The kind joins the check and the comments ────────────────────────────

alter table public.syla_approvals
    drop constraint syla_approvals_kind_check;
alter table public.syla_approvals
    add constraint syla_approvals_kind_check
    check (kind in ('conclusion', 'calendar_add', 'silo_membership', 'silo_edit', 'other'));

comment on table public.syla_approvals is
    'The generic Inbox card: Syla × Syla conclusions, calendar adds, silo membership changes, whole silo edits, and other judgments — pending until the owner rules. The agent inserts pending rows through propose_approval(); applying an approved card is the owner''s own client''s write (e.g. inserting the events row from a calendar_add payload, or building the silo a silo_edit describes), never the agent''s.';
comment on column public.syla_approvals.payload is
    'What approving applies, by kind — calendar_add: {title, start_date, start_time, end_time} for the events insert; silo_membership: {silo_id, action, subject}; silo_edit: {silo_id | silo_name, description, default_allows_*, rules, tables, remove_tables, followers, remove_followers} — the structured silo change the owner''s client builds on approve. The client applies nothing beyond its kind''s documented fields.';

-- ── propose_approval learns the kind ─────────────────────────────────────
--
-- Same signature, same grants; the kind list widens and a silo_edit must
-- actually carry its plan (a payload naming the silo), so an approved
-- card can never be an empty gesture.

create or replace function public.propose_approval(
    _kind        text,
    _title       text,
    _detail      text default null,
    _payload     jsonb default null,
    _chat_id     uuid default null,
    _follower_id uuid default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _profile uuid;
    _id      uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _kind not in ('conclusion', 'calendar_add', 'silo_membership', 'silo_edit', 'other') then
        raise exception 'kind must be conclusion, calendar_add, silo_membership, silo_edit or other';
    end if;
    if _title is null or char_length(btrim(_title)) not between 1 and 200 then
        raise exception 'the title must be 1–200 characters';
    end if;
    if _detail is not null and char_length(_detail) > 2000 then
        raise exception 'the detail is longer than 2000 characters';
    end if;
    if _payload is not null and jsonb_typeof(_payload) <> 'object' then
        raise exception 'the payload must be a JSON object';
    end if;
    if _kind = 'silo_edit' then
        if _payload is null then
            raise exception 'a silo_edit needs its payload — the structured change the owner approves';
        end if;
        if coalesce(btrim(_payload ->> 'silo_name'), '') = ''
           and coalesce(btrim(_payload ->> 'silo_id'), '') = '' then
            raise exception 'the silo_edit payload must name its silo (silo_name or silo_id)';
        end if;
    end if;

    select id into _profile from public.profiles where is_owner;
    if _profile is null then
        raise exception 'this database has no owner yet';
    end if;

    if (select count(*) from public.syla_approvals
        where profile_id = _profile and status = 'pending') >= 30 then
        raise exception 'there are already 30 pending approvals — wait for the owner to resolve some first';
    end if;

    insert into public.syla_approvals
        (profile_id, kind, chat_id, follower_id, title, detail, payload)
    values
        (_profile, _kind, _chat_id, _follower_id, btrim(_title), _detail, _payload)
    returning id into _id;

    return jsonb_build_object('id', _id, 'kind', _kind, 'status', 'pending');
end;
$$;

comment on function public.propose_approval(text, text, text, jsonb, uuid, uuid) is
    'Files one pending Inbox card as the claude role — a Syla × Syla conclusion, a calendar add (payload = the events fields), a silo membership change, a whole silo edit (payload = the structured plan the owner''s client applies), or another judgment. Applying is the owner''s client''s write on approve. Capped at 30 pending. Gated by assert_claude_rq_key().';

-- ── The skill that binds the procedure ───────────────────────────────────
--
-- Seeded once; the owner's later edits are theirs (insert-if-absent, the
-- house pattern for doc seeds).

insert into public.docs (path, title, html)
select 'skills/silo-edits', 'Silo edits: propose the whole change, the owner approves', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Silo edits: propose the whole change, the owner approves</title>
<style>
  body { margin: 0 auto; max-width: 42rem; padding: 2rem 1.25rem 4rem;
         font: 16px/1.6 system-ui, sans-serif; color: #1a1a1a; background: #fdfdfc; }
  h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
  code, pre { font-family: ui-monospace, monospace; background: #f0efec; border-radius: 4px; }
  code { padding: 0.1em 0.3em; } pre { padding: 0.75rem; overflow-x: auto; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e6e3; background: #16181a; }
    code, pre { background: #24272b; }
  }
</style></head>
<body>
<h1>Silo edits: propose the whole change, the owner approves</h1>
<p>Silos are pure data slices, and you have <strong>no write path</strong> into the vocabulary — not <code>silos</code>, not <code>silo_rules</code>, not <code>table_silos</code>, not <code>silo_followers</code>. When the owner wants a sharing change ("share my health data with Anna"), do not send them a to-do list of screens. Propose the WHOLE change as one Inbox card; approving it applies every step from their own session.</p>
<h2>One card, the whole plan</h2>
<pre>scripts/propose-silo-edit \
  --title "Share health data with Anna" \
  --detail "Creates a health silo with SQL reads on, places health_samples in it, and admits Anna." \
  --payload '{
    "silo_name": "health",
    "default_allows_sql": true,
    "rules": [{"kind": "only_include", "body": "health data only"}],
    "tables": ["health_samples"],
    "followers": [{"follower_id": "<uuid>", "name": "Anna"}]
  }'</pre>
<p>The payload is the plan, and the owner's client applies nothing beyond it:</p>
<ul>
<li><code>silo_id</code> — an existing silo (wins over <code>silo_name</code>); <code>silo_name</code> — find-or-create by name (lowercase, like the app). One of the two is required.</li>
<li><code>description</code> — set when the silo is created.</li>
<li><code>default_allows_sql</code> / <code>default_allows_prompts</code> / <code>default_allows_edits</code> — the silo's defaults for newly admitted followers.</li>
<li><code>rules</code> — <code>silo_rules</code> sentences to add: <code>{"kind", "body"}</code>, kinds <code>only_include</code>, <code>except_tag</code>, <code>except_source</code>, <code>except_time</code>, <code>except_words</code>.</li>
<li><code>tables</code> / <code>remove_tables</code> — whole tables to place in or lift from the silo, by <code>data_tables.table_name</code>. A whole table is every row or none.</li>
<li><code>followers</code> / <code>remove_followers</code> — people to admit (or remove), by <code>followers.id</code>. Flags omitted on admit mean the silo's defaults; include <code>"name"</code> for the card's display only.</li>
</ul>
<h2>Do the reads first</h2>
<p>Resolve every id and name before proposing — a card that fails to apply wastes the owner's tap:</p>
<pre>scripts/rq "select id, name from followers order by name"
scripts/rq "select id, name, default_allows_sql from silos order by name"
scripts/rq "select table_name, siloed_at from data_tables where siloing = 'table' order by table_name"</pre>
<p>Only tables registered <code>siloing = 'table'</code> can be placed whole; the per-row types (notes, docs, todos, events, apps) keep their own junctions — propose those moves through kind <code>silo_membership</code> as before.</p>
<h2>Keep it honest</h2>
<ul>
<li>One card per silo per ask. Put the why in <code>detail</code> — the owner reads it above the plan.</li>
<li>Read the silo's existing <code>silo_rules</code> sentences first and respect them; never propose a change that contradicts a rule the owner wrote.</li>
<li>Propose the narrowest change that serves the ask. Admitting a follower to a silo shares EVERYTHING in it, now and later — say so in the detail when it matters.</li>
<li>Declined is an answer: a dismissed card is precedent, not an invitation to re-file.</li>
</ul>
<footer>doc <code>skills/silo-edits</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/silo-edits');

-- Into the skills silo, where the rest of the library sits (guarded like
-- 20260929000000's placements).
insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'skills'
where d.path = 'skills/silo-edits'
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);

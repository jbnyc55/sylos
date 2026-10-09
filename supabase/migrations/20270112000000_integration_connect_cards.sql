-- Syla proposes the integration — the card wears the connect flow.
--
-- The chat-first design always had this move (the "Syla proposes an
-- integration" board): she posts a card, the card opens the connect
-- sheet, and the owner never hunts through menus. It shipped — but only
-- for follower chats, as the needs-integration rule suggestion
-- (20261216000000_integration_moment.sql). The SYLA conversation had no
-- vehicle for the same move: reply-rule suggestions are follower-scoped,
-- and the only interactive syla_approvals card was calendar_add. So the
-- first-run walkthrough fell back to dictating taps — "Tap Home, tap
-- Integrations, tap Health" — while the whole connect flow sat one
-- surface away.
--
-- kind 'integration_connect' is the bridge: one pending card whose
-- payload names the integration slug. In the app, tapping Connect opens
-- the same connect sheet the follower chats use — a native integration
-- (health, location, contacts, Apple Calendar, notifications) presents
-- its own flow, a registry integration runs its OAuth consent in place.
-- House pattern throughout: the claude role still only inserts pending
-- cards through propose_approval; connecting is the owner's own act on
-- their own device, and a card can never turn an integration on by
-- itself.

-- ── The kind joins the check and the comments ────────────────────────────

alter table public.syla_approvals
    drop constraint syla_approvals_kind_check;
alter table public.syla_approvals
    add constraint syla_approvals_kind_check
    check (kind in ('conclusion', 'calendar_add', 'silo_membership', 'silo_edit', 'integration_connect', 'other'));

comment on table public.syla_approvals is
    'The generic Inbox card: Syla × Syla conclusions, calendar adds, silo membership changes, whole silo edits, integration-connect proposals, and other judgments — pending until the owner rules. The agent inserts pending rows through propose_approval(); applying an approved card is the owner''s own client''s write (e.g. inserting the events row from a calendar_add payload, building the silo a silo_edit describes, or running the connect flow an integration_connect names), never the agent''s.';
comment on column public.syla_approvals.payload is
    'What approving applies, by kind — calendar_add: {title, start_date, start_time, end_time} for the events insert; silo_membership: {silo_id, action, subject}; silo_edit: {silo_id | silo_name, description, default_allows_*, rules, tables, remove_tables, followers, remove_followers} — the structured silo change the owner''s client builds on approve; integration_connect: {integration} — the slug whose connect flow the card opens (the card flips approved only once the flow finishes). The client applies nothing beyond its kind''s documented fields.';

-- ── propose_approval learns the kind ─────────────────────────────────────
--
-- Same signature, same grants; the kind list widens and an
-- integration_connect must name its integration, so the card the owner
-- taps always knows which connect flow to open.

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

    if _kind not in ('conclusion', 'calendar_add', 'silo_membership', 'silo_edit', 'integration_connect', 'other') then
        raise exception 'kind must be conclusion, calendar_add, silo_membership, silo_edit, integration_connect or other';
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
    if _kind = 'integration_connect'
       and coalesce(btrim(_payload ->> 'integration'), '') = '' then
        raise exception 'the integration_connect payload must name its integration slug';
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
    'Files one pending Inbox card as the claude role — a Syla × Syla conclusion, a calendar add (payload = the events fields), a silo membership change, a whole silo edit (payload = the structured plan the owner''s client applies), an integration-connect proposal (payload = {integration}; the card opens the connect flow), or another judgment. Applying is the owner''s client''s write on approve. Capped at 30 pending. Gated by assert_claude_rq_key().';

-- ── The first run proposes instead of directing ──────────────────────────
--
-- Stage one of skills/first-run stops sending the owner through four
-- screens and files the card first, keeping the taps as the no-card
-- fallback. Doc edits are the house pattern: targeted text swaps,
-- guarded so an owner's own edits survive and a re-run no-ops.

update public.docs
set html = replace(html,
    $old$<p>Send the welcome and the connect steps. The owner may still be on the web finishing setup — the message simply waits in their chat, so write it to be read whenever they arrive:</p>
<blockquote>Hey, I'm Syla 👋 Let's build your first app — a live chart of your own health data.<br>
First, connect Apple Health:<br>
1. Tap <strong>Home</strong> (bottom right)<br>
2. Tap <strong>Integrations</strong><br>
3. Tap <strong>Health</strong>, then <strong>Start mirroring</strong><br>
4. Allow what you're happy to share<br>
Then come back here and reply <em>done</em>.</blockquote>$old$,
    $new$<p>Propose the connection as a card first — in the app the card carries the whole connect flow, right inside this conversation, so the owner never hunts through menus. The card must ride the Syla conversation to render there:</p>
<pre>scripts/rq "select id from chats where kind = 'syla'"
scripts/propose-integration --slug health --chat &lt;that id&gt; \
    --title "Connect Apple Health" \
    --detail "Powers your first app — a live chart of your own health data."</pre>
<p>One card, once — if a pending connect card for health already exists, don't file another. Then send the welcome pointing at it. The owner may still be on the web finishing setup — the message simply waits in their chat, so write it to be read whenever they arrive:</p>
<blockquote>Hey, I'm Syla 👋 Let's build your first app — a live chart of your own health data.<br>
First, connect Apple Health: tap <strong>Connect</strong> on the card right below and allow what you're happy to share.<br>
(No card? Tap <strong>Home</strong>, then <strong>Integrations</strong>, then <strong>Health</strong>, then <strong>Start mirroring</strong>.)<br>
Then come back here and reply <em>done</em>.</blockquote>$new$)
where path = 'skills/first-run'
  and html not like '%propose-integration%';

update public.docs
set html = replace(html,
    'The walkthrough files <strong>no todos and no events</strong> — none of these messages is a task for the calendar.',
    'The walkthrough files <strong>no todos and no events</strong> — none of these messages is a task for the calendar; the stage-one connect card is an approval, not a calendar entry.')
where path = 'skills/first-run'
  and html not like '%the stage-one connect card is an approval%';

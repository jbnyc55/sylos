-- save_note — the one-call quick capture for the agent.
--
-- Until now, "something worth keeping came up in conversation" cost the
-- agent the whole docs discipline before a single byte was durable: list
-- the skills docs, read skills/docs, read the doc tree, compose a complete
-- self-contained HTML document, save_doc, then read the silo vocabulary
-- and place it. That is the right ceremony for editing the library and the
-- wrong one for capture — and the schema already says so: the chute's
-- promise is "you never file at capture time", the capture is raw text and
-- the scheduled sort does the careful filing with full context.
--
-- So the fast path is a chute drop the agent can make: save_note(_body)
-- appends one raw text chute_items row and nothing else. Append-only (the
-- claude role gains insert of raw text items and no new update or delete),
-- provenance-marked (a new source column, so an agent capture never
-- masquerades as the owner's own drop), and filed later by the same Chute
-- sort runs that file everything else, receipt and undo included. The
-- connector exposes it as a first-class tool whose description is the
-- whole manual — no skills to load before saving.

-- ── Provenance ───────────────────────────────────────────────────────────

alter table public.chute_items
    add column source text not null default 'owner'
    check (source in ('owner', 'syla'));

comment on column public.chute_items.source is
    'Who dropped it: ''owner'' (the capture drawer) or ''syla'' (the agent''s save_note — a note worth keeping from a conversation or a run). Clients may label syla drops; the sort files both alike.';

-- ── The claude role may append raw text notes, nothing more ──────────────

grant insert (profile_id, kind, body, source) on public.chute_items to claude;

create policy "claude drops notes into the chute"
    on public.chute_items for insert to claude
    with check (
        kind = 'text'
        and status = 'raw'
        and source = 'syla'
        and upload_id is null
        and profile_id = (select id from public.profiles where is_owner limit 1)
    );

-- ── The gated RPC ────────────────────────────────────────────────────────

create function public.save_note(_body text)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _owner uuid;
    _id uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _body is null or char_length(btrim(_body)) not between 1 and 8000 then
        raise exception 'the note must be 1–8000 characters of plain text';
    end if;

    select id into _owner from public.profiles where is_owner limit 1;
    if _owner is null then
        raise exception 'no owner profile exists yet';
    end if;

    insert into public.chute_items (profile_id, kind, body, source)
    values (_owner, 'text', btrim(_body), 'syla')
    returning id into _id;

    return jsonb_build_object(
        'id', _id,
        'status', 'raw',
        'note', 'captured; the next chute sort files it'
    );
end;
$$;

comment on function public.save_note(text) is
    'The agent''s one-call quick capture: appends one raw text item to the owner''s chute (source ''syla''), as the claude role — durable immediately, filed by the next scheduled Chute sort like any drop. The fast path for "this belongs in Sylos"; editing the docs library stays save_doc''s job. Gated by assert_claude_rq_key().';

revoke all on function public.save_note(text) from public;
grant execute on function public.save_note(text) to anon;

-- ── Teach the sort what a syla drop is ───────────────────────────────────
--
-- The capability doc gains one paragraph; everything else is as seeded in
-- 20261124000000. (A full replace, as doc reseeds are.)

update public.docs
set html = $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>The chute: capture now, sort on schedule</title>
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
<h1>The chute: capture now, sort on schedule</h1>
<p>The chute (<code>chute_items</code>) is the owner's zero-friction capture surface: text, photos, files and voice notes land with <code>status = 'raw'</code> and no filing decision. Filing is YOUR job, on the schedule in <code>chute_settings</code> (hourly / 09:00-13:00-18:00 / once daily) — the dispatcher queues the seeded <em>Chute sort</em> event whenever raw items wait, and <code>syla/chute-sort</code> is that run's exact procedure. The owner can also fire it immediately ("Sort now").</p>
<h2>Your two verbs here</h2>
<ul>
<li><code>file_chute_item(_item_id, _filed_to, _filed_locator)</code> — after the item really landed somewhere through a gated write. <code>_filed_to</code> is for the owner's eyes ("Notes · Gift ideas"); <code>_filed_locator</code> is <code>table:id</code> for the client.</li>
<li><code>ask_chute_question(_item_id, _question)</code> — the ambiguity path; the card shows in the Inbox and the owner's reply arrives in the row's <code>answer</code>.</li>
</ul>
<p>Both move only <code>raw</code> items — dismissing and undoing are the owner's verbs, and an undo (back to raw) simply hands the item to your next run. Every move you make is in <code>row_edits</code>; that log is the undo UI, so file decisively and legibly rather than hedging.</p>
<h2>Your drops: save_note</h2>
<p>Capture works for you too. <code>save_note(_body)</code> (script <code>scripts/save-note</code>; a first-class tool on the connector) appends one raw text item with <code>source = 'syla'</code> — the one-call way to keep something that came up in a conversation or a run, with no doc to compose and no path or silo to choose at capture time. The sort files a syla drop exactly like an owner drop. Saving a note is never the moment to load the docs skill; filing time is.</p>
<p>Done looks like: zero raw items, each filed one wearing an honest <code>filed_to</code>, questions only where a human genuinely has to choose.</p>
<footer>doc <code>skills/chute</code></footer>
</body></html>$doc$
where path = 'skills/chute';

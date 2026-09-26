-- Silo asks: the state where Syla asks for help.
--
-- The siloing job places a record when it is sure and leaves a silo off
-- when it is not — a wrong placement shows the record to real people, a
-- missing one only hides it. That left no room for the middle: a note that
-- strongly fits a silo, where the one open question is exactly what the
-- owner could answer in a second ("is this the Acme deal, or the side
-- project?"). A SILO ASK is that middle. Instead of guessing, Syla files the
-- record here with the silos she weighed — each with how sure she was — and
-- one question; the owner answers from the Syla tab's Couldn't Silo list,
-- and the answer is kept, so it reads as precedent on later runs.
--
-- Scope follows the job's write paths: notes and docs. An ask points at
-- exactly one of them, by foreign key, so deleting the record takes its
-- asks with it. One OPEN ask per record (a re-ask replaces the question and
-- candidates in place); answered asks accumulate as history.

create table public.silo_asks (
    id                 uuid primary key default gen_random_uuid(),
    note_id            uuid references public.manual_notes (id) on delete cascade,
    doc_id             uuid references public.docs (id) on delete cascade,
    -- What she needs to know — one specific, answerable question.
    question           text not null check (char_length(question) between 1 and 1000),
    status             text not null default 'open'
                       check (status in ('open', 'answered')),
    -- The owner's ruling: the silos the record went into once answered —
    -- empty for "none of these". Null while open.
    answered_silo_ids  uuid[],
    answered_at        timestamptz,
    created_at         timestamptz not null default now(),
    updated_at         timestamptz not null default now(),
    check (num_nonnulls(note_id, doc_id) = 1),
    check ((status = 'open') = (answered_at is null))
);

comment on table public.silo_asks is
    'Records Syla strongly considered placing in a silo but was not sure enough to: one open question per note or doc, answered by the owner on the Syla tab (Couldn''t Silo). Answered rows are kept as precedent for later siloing runs.';

create unique index silo_asks_one_open_note
    on public.silo_asks (note_id) where status = 'open' and note_id is not null;
create unique index silo_asks_one_open_doc
    on public.silo_asks (doc_id) where status = 'open' and doc_id is not null;

create trigger silo_asks_set_updated_at
    before update on public.silo_asks
    for each row execute function public.set_updated_at();

-- The silos she weighed, each with how sure she was. A surrogate id so the
-- row_edits logging (attached by the event trigger, like every table) has a
-- row_id; deleting a silo drops it from every ask.
create table public.silo_ask_candidates (
    id          uuid primary key default gen_random_uuid(),
    ask_id      uuid not null references public.silo_asks (id) on delete cascade,
    silo_id     uuid not null references public.silos (id) on delete cascade,
    -- Percent sure the record belongs in this silo.
    confidence  smallint not null check (confidence between 0 and 100),
    created_at  timestamptz not null default now(),
    unique (ask_id, silo_id)
);

comment on table public.silo_ask_candidates is
    'The silos one silo ask weighed, with Syla''s confidence (percent) in each — the one-tap answers on the Couldn''t Silo list.';

create index silo_ask_candidates_silo_id_idx on public.silo_ask_candidates (silo_id);

-- ── Row level security ───────────────────────────────────────────────────

alter table public.silo_asks enable row level security;
alter table public.silo_ask_candidates enable row level security;

-- The owner reads the asks and answers them (an update); members never see
-- them — an ask is about where a record should go, which is itself private.
create policy "Silo asks are viewable by the owner"
    on public.silo_asks for select to authenticated
    using (public.is_owner());
create policy "Silo asks are answerable by the owner"
    on public.silo_asks for update to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "Silo asks are deletable by the owner"
    on public.silo_asks for delete to authenticated
    using (public.is_owner());
create policy "Silo ask candidates are viewable by the owner"
    on public.silo_ask_candidates for select to authenticated
    using (public.is_owner());

-- The claude role files and re-files asks through ask_silo_help below, and
-- reads the answered ones as precedent.
create policy "claude reads silo asks"
    on public.silo_asks for select to claude using (true);
create policy "claude files silo asks"
    on public.silo_asks for insert to claude with check (status = 'open');
create policy "claude re-files open silo asks"
    on public.silo_asks for update to claude
    using (status = 'open') with check (status = 'open');
create policy "claude reads silo ask candidates"
    on public.silo_ask_candidates for select to claude using (true);
create policy "claude writes silo ask candidates"
    on public.silo_ask_candidates for insert to claude with check (true);
create policy "claude replaces silo ask candidates"
    on public.silo_ask_candidates for delete to claude using (true);

grant select, update, delete on public.silo_asks to authenticated;
grant select on public.silo_ask_candidates to authenticated;
grant select, insert, update on public.silo_asks to claude;
grant select, insert, delete on public.silo_ask_candidates to claude;

-- ── ask_silo_help — the siloing job's write ──────────────────────────────
--
-- Same shape as set_note_silos / set_doc_silos: gated by
-- assert_claude_rq_key(), running as the claude role, wrapped by
-- scripts/silo-ask. The record is a note id OR a doc path (the docs pass
-- addresses docs by path). _candidates is a JSON array of
-- {"silo_id": uuid, "confidence": 0-100}, at least one. Re-asking about a
-- record with an open ask replaces its question and candidates in place,
-- so a re-run is idempotent; it never touches the record's placements.

create function public.ask_silo_help(
    _note_id uuid, _doc_path text, _question text, _candidates jsonb
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _doc_id  uuid;
    _ask_id  uuid;
    _existed boolean;
    _count   integer;
begin
    perform public.assert_claude_rq_key();

    if num_nonnulls(_note_id, _doc_path) <> 1 then
        raise exception 'give exactly one of a note id or a doc path';
    end if;
    if _question is null or char_length(trim(_question)) = 0 then
        raise exception 'a question is required';
    end if;
    if _candidates is null or jsonb_typeof(_candidates) <> 'array'
       or jsonb_array_length(_candidates) = 0 then
        raise exception 'candidates must be a non-empty array of {silo_id, confidence}';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    if _note_id is not null then
        if not exists (select 1 from public.manual_notes where id = _note_id) then
            raise exception 'no such note: %', _note_id;
        end if;
    else
        select id into _doc_id from public.docs where path = _doc_path;
        if _doc_id is null then
            raise exception 'no doc at %', _doc_path;
        end if;
    end if;

    if exists (
        select 1 from jsonb_array_elements(_candidates) c
        where not exists (
            select 1 from public.silos s where s.id::text = c->>'silo_id'
        )
    ) then
        raise exception 'every candidate must name an existing silo_id';
    end if;

    select id into _ask_id
    from public.silo_asks
    where status = 'open'
      and (note_id = _note_id or doc_id = _doc_id);
    _existed := _ask_id is not null;

    if _existed then
        update public.silo_asks set question = trim(_question) where id = _ask_id;
        delete from public.silo_ask_candidates where ask_id = _ask_id;
    else
        insert into public.silo_asks (note_id, doc_id, question)
        values (_note_id, _doc_id, trim(_question))
        returning id into _ask_id;
    end if;

    insert into public.silo_ask_candidates (ask_id, silo_id, confidence)
    select _ask_id, (c->>'silo_id')::uuid,
           greatest(0, least(100, round((c->>'confidence')::numeric)))::smallint
    from jsonb_array_elements(_candidates) c
    on conflict (ask_id, silo_id) do nothing;
    get diagnostics _count = row_count;

    return jsonb_build_object(
        'ask_id',     _ask_id,
        'note_id',    _note_id,
        'doc_id',     _doc_id,
        'candidates', _count,
        'op',         case when _existed then 'updated' else 'created' end
    );
end;
$$;

comment on function public.ask_silo_help(uuid, text, text, jsonb) is
    'Files (or re-files) one open silo ask for a note or doc, as the claude role: the question and the candidate silos with confidence. Never changes placements. Gated by assert_claude_rq_key().';

revoke all on function public.ask_silo_help(uuid, text, text, jsonb) from public;
grant execute on function public.ask_silo_help(uuid, text, text, jsonb) to anon;

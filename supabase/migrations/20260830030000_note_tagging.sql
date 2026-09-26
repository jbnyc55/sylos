-- The daily note-tagging routine: vetting stamps, sub-notes, and the claude
-- role's write paths for both (skills/note-tagging).
--
-- Tagging moved out of the client (the save-with-types UI is gone); a daily
-- Claude routine now assigns types by reading each note. Two questions have
-- to be answerable from data alone:
--
--   "Are this note's tags up to date?" — tags_vetted_at, compared against
--   the vocabulary watermark max(note_types.created_at). A type added today
--   makes every earlier vetting stale, because no note has been read with
--   that type in mind yet. The stamp is written even when no type fits, so
--   an untagged-but-vetted note is distinguishable from a never-tried one.
--
--   "Was this multi-type note ever split?" — split_attempted_at, plus
--   parent_note_id on the sub-notes a successful split creates. The stamp is
--   written even when no clean split exists, so the routine never re-chews
--   the same note.
--
-- Writes follow the upsert_day_summary pattern (20260828080000): structured
-- RPCs gated on the Vault key, `set local role claude`, column-scoped
-- grants, no dynamic SQL. The role still cannot delete a note or touch a
-- note's body — its only deletes are junction rows, and its only inserts
-- are sub-notes (the insert policy requires parent_note_id).

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------

alter table public.manual_notes
    add column tags_vetted_at     timestamptz,
    add column split_attempted_at timestamptz,
    add column parent_note_id     uuid references public.manual_notes (id) on delete cascade;

comment on column public.manual_notes.tags_vetted_at is
    'When the tagging routine last read this note against the type vocabulary. Stale when null or older than max(note_types.created_at); set even when no type fit.';

comment on column public.manual_notes.split_attempted_at is
    'When the routine last tried to split this multi-type note into sub-notes. Set even when no clean split existed.';

comment on column public.manual_notes.parent_note_id is
    'For a sub-note: the multi-type note it was split out of. Null for ordinary notes.';

-- "Does this note have sub-notes?" is asked per parent.
create index manual_notes_parent_note_id_idx
    on public.manual_notes (parent_note_id)
    where parent_note_id is not null;

-- ---------------------------------------------------------------------------
-- Row level security + grants for the claude role
-- ---------------------------------------------------------------------------

-- Junction rows are the tags themselves: the routine adds and removes them.
create policy "claude tags notes"
    on public.manual_note_types for insert
    to claude
    with check (true);

create policy "claude untags notes"
    on public.manual_note_types for delete
    to claude
    using (true);

-- The routine stamps notes; the column-scoped grant below keeps everything
-- else (body included) out of reach even though the policy is broad.
create policy "claude stamps notes"
    on public.manual_notes for update
    to claude
    using (true)
    with check (true);

-- The routine's only insert is a sub-note: a row that names its parent.
create policy "claude inserts sub-notes"
    on public.manual_notes for insert
    to claude
    with check (parent_note_id is not null);

grant insert, delete on public.manual_note_types to claude;
grant update (tags_vetted_at, split_attempted_at) on public.manual_notes to claude;
-- created_at is in the list so a sub-note lands on its parent's day, not the
-- day the routine happened to run; tags_vetted_at so it is born vetted.
grant insert (profile_id, body, parent_note_id, created_at, tags_vetted_at)
    on public.manual_notes to claude;

-- ---------------------------------------------------------------------------
-- tag_note — one note's vetting, over HTTPS
-- ---------------------------------------------------------------------------
--
-- Sets the note's tag set to exactly _type_ids and stamps tags_vetted_at.
-- An empty array is the "read it, nothing fits" outcome — the junction rows
-- go away (if any) and the stamp is still written. Idempotent.

create or replace function public.tag_note(_note_id uuid, _type_ids uuid[])
returns jsonb
language plpgsql
security invoker
as $$
declare
    removed integer;
    added   integer;
begin
    perform public.assert_claude_rq_key();

    if _type_ids is null then
        raise exception 'type_ids must be an array (possibly empty), not null';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    if not exists (select 1 from public.manual_notes where id = _note_id) then
        raise exception 'no such note: %', _note_id;
    end if;

    delete from public.manual_note_types
    where note_id = _note_id
      and note_type_id <> all (_type_ids);
    get diagnostics removed = row_count;

    insert into public.manual_note_types (note_id, note_type_id)
    select _note_id, unnest(_type_ids)
    on conflict do nothing;
    get diagnostics added = row_count;

    update public.manual_notes
    set tags_vetted_at = now()
    where id = _note_id;

    return jsonb_build_object(
        'note_id', _note_id,
        'tags',    coalesce(array_length(_type_ids, 1), 0),
        'added',   added,
        'removed', removed
    );
end;
$$;

comment on function public.tag_note(uuid, uuid[]) is
    'Sets one note''s tag set and stamps tags_vetted_at, as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.tag_note(uuid, uuid[]) from public;
grant execute on function public.tag_note(uuid, uuid[]) to anon;

-- ---------------------------------------------------------------------------
-- split_note — one note's split attempt, over HTTPS
-- ---------------------------------------------------------------------------
--
-- _subnotes: [{"body": text, "type_ids": [uuid, ...]}, ...]. Two or more
-- create that many sub-notes (each on the parent's day, born vetted, tagged
-- with its subset) and stamp the parent; an empty array records that a split
-- was tried and no clean one existed — exactly one of those two shapes, a
-- single-element "split" being no split at all.

create or replace function public.split_note(_note_id uuid, _subnotes jsonb)
returns jsonb
language plpgsql
security invoker
as $$
declare
    parent  record;
    sub     record;
    new_id  uuid;
    ids     uuid[] := '{}';
begin
    perform public.assert_claude_rq_key();

    if _subnotes is null or jsonb_typeof(_subnotes) <> 'array' then
        raise exception 'subnotes must be a JSON array';
    end if;
    if jsonb_array_length(_subnotes) = 1 then
        raise exception 'a split needs at least two sub-notes; send [] to record that none was possible';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    select id, profile_id, created_at, parent_note_id
    into parent
    from public.manual_notes
    where id = _note_id;

    if parent.id is null then
        raise exception 'no such note: %', _note_id;
    end if;

    if jsonb_array_length(_subnotes) > 0 then
        -- Splits never chain and never stack: a sub-note stays a leaf, and a
        -- parent that has been split is finished.
        if parent.parent_note_id is not null then
            raise exception 'refusing to split a sub-note: %', _note_id;
        end if;
        if exists (select 1 from public.manual_notes where parent_note_id = _note_id) then
            raise exception 'note % already has sub-notes', _note_id;
        end if;

        for sub in select value from jsonb_array_elements(_subnotes) loop
            if jsonb_typeof(sub.value -> 'body') <> 'string'
               or jsonb_typeof(sub.value -> 'type_ids') <> 'array'
               or jsonb_array_length(sub.value -> 'type_ids') < 1 then
                raise exception 'each sub-note needs a "body" string and a non-empty "type_ids" array';
            end if;

            insert into public.manual_notes
                (profile_id, body, parent_note_id, created_at, tags_vetted_at)
            values
                (parent.profile_id, sub.value ->> 'body', _note_id, parent.created_at, now())
            returning id into new_id;

            insert into public.manual_note_types (note_id, note_type_id)
            select new_id, t.value::uuid
            from jsonb_array_elements_text(sub.value -> 'type_ids') t;

            ids := ids || new_id;
        end loop;
    end if;

    update public.manual_notes
    set split_attempted_at = now()
    where id = _note_id;

    return jsonb_build_object(
        'note_id',      _note_id,
        'created',      coalesce(array_length(ids, 1), 0),
        'sub_note_ids', to_jsonb(ids)
    );
end;
$$;

comment on function public.split_note(uuid, jsonb) is
    'Splits one multi-type note into tagged sub-notes (or records that no split was possible), as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.split_note(uuid, jsonb) from public;
grant execute on function public.split_note(uuid, jsonb) to anon;

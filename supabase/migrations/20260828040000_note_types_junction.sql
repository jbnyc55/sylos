-- Note types become rows, and a note can have many of them.
--
-- note_type was a string column on manual_notes, which caps every note at
-- exactly one type. This migration normalizes it: a note_types lookup table
-- (seeded with the four types in use), a manual_note_types junction, a
-- backfill mapping each note's old string to its junction row, and then the
-- column is dropped. A note with two types — a purchase that is also worth a
-- wellness flag — is now just two junction rows.

-- ---------------------------------------------------------------------------
-- note_types
-- ---------------------------------------------------------------------------

create table public.note_types (
    id          uuid primary key default gen_random_uuid(),
    name        text not null unique check (char_length(name) between 1 and 50),
    created_at  timestamptz not null default now()
);

comment on table public.note_types is
    'The kinds of manual-notes logs. App-wide, not per-profile; a new log starts with a row here.';

insert into public.note_types (name)
values ('money'), ('calories'), ('wellness'), ('goal');

-- ---------------------------------------------------------------------------
-- manual_note_types — the junction
-- ---------------------------------------------------------------------------

create table public.manual_note_types (
    note_id       uuid not null references public.manual_notes (id) on delete cascade,
    note_type_id  uuid not null references public.note_types (id) on delete cascade,
    primary key (note_id, note_type_id)
);

comment on table public.manual_note_types is
    'Which types each manual note has. Both foreign keys in the primary key is what lets PostgREST embed the many-to-many.';

-- The daily aggregation routines read "all notes of type X", which is this.
create index manual_note_types_type_note_idx
    on public.manual_note_types (note_type_id, note_id);

-- ---------------------------------------------------------------------------
-- Backfill from the old column, then drop it
-- ---------------------------------------------------------------------------

insert into public.manual_note_types (note_id, note_type_id)
select n.id, t.id
from public.manual_notes n
join public.note_types t on t.name = n.note_type;

-- Dropping the column also drops its check constraint and the index that
-- included it, so the plain owner index is recreated without the type.
alter table public.manual_notes drop column note_type;

create index manual_notes_profile_created_idx
    on public.manual_notes (profile_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.note_types        enable row level security;
alter table public.manual_note_types enable row level security;

-- note_types: a shared vocabulary — every signed-in user reads it, nobody
-- writes it from the client. New types arrive by migration.
create policy "Note types are viewable by signed-in users"
    on public.note_types for select
    to authenticated
    using (true);

-- manual_note_types: owned through the note it tags. The subquery runs under
-- manual_notes' own policies, which already scope to the caller's profile.
create policy "Note type links are viewable by the note's owner"
    on public.manual_note_types for select
    to authenticated
    using (exists (
        select 1 from public.manual_notes n
        where n.id = note_id
          and n.profile_id = (select public.current_profile_id())
    ));

create policy "Note type links are insertable by the note's owner"
    on public.manual_note_types for insert
    to authenticated
    with check (exists (
        select 1 from public.manual_notes n
        where n.id = note_id
          and n.profile_id = (select public.current_profile_id())
    ));

create policy "Note type links are deletable by the note's owner"
    on public.manual_note_types for delete
    to authenticated
    using (exists (
        select 1 from public.manual_notes n
        where n.id = note_id
          and n.profile_id = (select public.current_profile_id())
    ));

-- The claude role reads both, like every application table.
create policy "claude reads everything"
    on public.note_types for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.manual_note_types for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200).
grant select on public.note_types to authenticated;
grant select, insert, delete on public.manual_note_types to authenticated;

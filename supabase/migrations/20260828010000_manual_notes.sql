-- Consolidate the free-text log tables into one: manual_notes.
--
-- money_entry and food_log_entry were structurally identical — a body column
-- owned by a profile — and every future log (starting with wellness, which
-- never got its own table) would have repeated the same shape again. One table
-- with a note_type discriminator means a new kind of log is a new string, not
-- a new migration, and the daily aggregation routines planned in
-- notes/08-daily-logs-and-plaid.md read one table instead of N.
--
-- Existing rows are carried over with their ids and timestamps intact, then
-- the old tables are dropped. notes and goals are deliberately left alone.

create table public.manual_notes (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    note_type   text not null check (char_length(note_type) between 1 and 50),
    body        text not null check (char_length(body) between 1 and 10000),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

comment on table public.manual_notes is
    'Raw free-text logs, one row per entry, discriminated by note_type (money, calories, wellness, …). Daily routines aggregate later.';

comment on column public.manual_notes.note_type is
    'Which log this entry belongs to. Deliberately not an enum: a new log is a new string, no migration needed.';

-- Every read is scoped to one log, so note_type sits inside the index.
create index manual_notes_profile_type_created_idx
    on public.manual_notes (profile_id, note_type, created_at desc);

create trigger manual_notes_set_updated_at
    before update on public.manual_notes
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Carry the existing rows over, then drop the old tables
-- ---------------------------------------------------------------------------

insert into public.manual_notes (id, profile_id, note_type, body, created_at, updated_at)
select id, profile_id, 'money', body, created_at, updated_at
from public.money_entry;

insert into public.manual_notes (id, profile_id, note_type, body, created_at, updated_at)
select id, profile_id, 'calories', body, created_at, updated_at
from public.food_log_entry;

drop table public.money_entry;
drop table public.food_log_entry;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.manual_notes enable row level security;

-- manual_notes: fully owned by the profile that created them.
create policy "Manual notes are viewable by their owner"
    on public.manual_notes for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Manual notes are insertable by their owner"
    on public.manual_notes for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Manual notes are updatable by their owner"
    on public.manual_notes for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Manual notes are deletable by their owner"
    on public.manual_notes for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads every application table; its select grant arrives via
-- default privileges (see 20260816000300).
create policy "claude reads everything"
    on public.manual_notes for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200).
grant select, insert, update, delete on public.manual_notes to authenticated;

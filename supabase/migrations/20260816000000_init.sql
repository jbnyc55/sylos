-- Initial schema: profiles and notes.
--
-- Identity convention: **profile_id is how this schema refers to users.**
-- `auth.users` is Supabase's table, and it is referenced in exactly one place —
-- `profiles.user_id`. Everything else in the application points at
-- `profiles.id`. That keeps the app's identity namespace its own, so auth can
-- change without rewriting every foreign key.

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------

create table public.profiles (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null unique references auth.users (id) on delete cascade,
    email       text,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

comment on table public.profiles is
    'Application-level identity. profiles.id is the only user identifier the rest of the schema uses.';

create index profiles_user_id_idx on public.profiles (user_id);

-- ---------------------------------------------------------------------------
-- notes
-- ---------------------------------------------------------------------------

create table public.notes (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    body        text not null check (char_length(body) between 1 and 10000),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create index notes_profile_id_created_at_idx
    on public.notes (profile_id, created_at desc);

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------

-- Set updated_at server-side so it cannot be spoofed by the client.
create function public.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger profiles_set_updated_at
    before update on public.profiles
    for each row execute function public.set_updated_at();

create trigger notes_set_updated_at
    before update on public.notes
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Automatic profile creation
-- ---------------------------------------------------------------------------

-- Every user gets a profile the moment they are created, so no code path ever
-- has to cope with a user that has no profile. security definer is required:
-- the trigger runs as the signing-up user, who has no rights on public.profiles.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.profiles (user_id, email)
    values (new.id, new.email)
    on conflict (user_id) do nothing;
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
--
-- The web client queries with the public anon key, so these policies are the
-- entire authorization layer. A table without them is a public table.

-- Resolves the caller's profile id once per statement. security definer so it
-- can read profiles regardless of that table's own policies; stable so the
-- planner does not re-run it per row.
create function public.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select id from public.profiles where user_id = (select auth.uid());
$$;

alter table public.profiles enable row level security;
alter table public.notes    enable row level security;

-- profiles: readable and updatable by their owner. Inserts happen only through
-- handle_new_user(), so there is deliberately no insert policy, and rows are
-- removed by the cascade from auth.users rather than by users deleting them.
create policy "Profiles are viewable by their owner"
    on public.profiles for select
    to authenticated
    using (user_id = (select auth.uid()));

create policy "Profiles are updatable by their owner"
    on public.profiles for update
    to authenticated
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));

-- notes: fully owned by the profile that created them.
create policy "Notes are viewable by their owner"
    on public.notes for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Notes are insertable by their owner"
    on public.notes for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Notes are updatable by their owner"
    on public.notes for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Notes are deletable by their owner"
    on public.notes for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

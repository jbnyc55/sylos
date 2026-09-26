-- The first account becomes the owner — no seed-file edit required.
--
-- The starter used to require editing 20260816000100_seed_first_user.sql
-- (email + temporary password) before the first deploy: error-prone in
-- GitHub's web editor, a plaintext password in git history, and a silent
-- ordering trap (commit before connecting Supabase). That edit is now
-- optional. On a fresh database the seed no-ops (it skips when its
-- placeholder email is unchanged), and ownership is claimed by signing up:
-- the first profile created is crowned `is_owner` by trigger, and the
-- crowning seeds the owner defaults that the older owner-joining seed
-- migrations (20260920000000, 20260924000000, 20260928000000) could not
-- create — they ran while the database had no owner yet.
--
-- The trade, accepted deliberately: between "migrations deployed" and
-- "you signed up" there is a window in which anyone who knows your fresh
-- project's URL and anon key could sign up first and become owner. The
-- project ref is unguessable and the window is minutes; if it ever
-- happens, the project is minutes old — delete it and redeploy.
--
-- On a database that already has an owner (a customized seed, or an
-- existing deployment) everything here is inert: the crowning trigger
-- only fires while no owner exists.

-- ---------------------------------------------------------------------------
-- At most one owner, guaranteed by the database
-- ---------------------------------------------------------------------------
-- Two concurrent first sign-ups could both see "no owner yet"; this index
-- makes the second insert fail instead of minting two owners. That sign-up
-- errors and retries as an ordinary (non-owner) account.

create unique index if not exists profiles_single_owner
    on public.profiles (is_owner)
    where is_owner;

-- ---------------------------------------------------------------------------
-- Crown the first profile
-- ---------------------------------------------------------------------------
-- Runs inside profile creation (handle_new_user, on auth.users insert).
-- Member and guest claims also create profiles, but those flows cannot
-- exist before an owner has added the member row, so "first profile" and
-- "the owner signing up" are the same event in practice.

create function public.crown_first_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if not exists (select 1 from public.profiles where is_owner) then
        new.is_owner := true;
    end if;
    return new;
end
$$;

revoke execute on function public.crown_first_profile() from public, anon, authenticated;

create trigger profiles_crown_first
    before insert on public.profiles
    for each row execute function public.crown_first_profile();

-- ---------------------------------------------------------------------------
-- Seed the owner defaults when the crown lands
-- ---------------------------------------------------------------------------
-- The starter jobs were seeded by migrations that `join profiles on
-- is_owner` — a no-op on a fresh database where no owner exists at deploy
-- time. This replays exactly that seed (same names, docs and times as
-- 20260928000000 / 20260924000000, same not-exists guards) for the newly
-- crowned owner. Docs are seeded unconditionally by migration, so they
-- are already present here.

create function public.seed_owner_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.syla_jobs (profile_id, name, doc_id, fire_at)
    select new.id, s.name, d.id, s.fire_at
    from (values
            ('Morning day summary',  'syla/daily-summary', time '12:00'),
            ('Daily note siloing',   'syla/note-siloing',  time '11:15'),
            ('Daily edit feedback',  'syla/edit-feedback', time '11:30'),
            ('Goal synergy linking', 'syla/goal-synergy',  time '11:45')
         ) as s (name, doc_path, fire_at)
    join public.docs d on d.path = s.doc_path
    where not exists (select 1 from public.syla_jobs e where e.name = s.name);
    return new;
end
$$;

revoke execute on function public.seed_owner_defaults() from public, anon, authenticated;

create trigger profiles_seed_owner_defaults
    after insert on public.profiles
    for each row
    when (new.is_owner)
    execute function public.seed_owner_defaults();

comment on column public.profiles.is_owner is
    'True for the app''s owner: the first account created (crowned by trigger), or the seeded user where the seed migration was customized. Members and guests verifying email on the claim page get ordinary rows with false.';

-- Members get a name; email stops being required.
--
-- Email earned its NOT NULL when it was the identity proof — the claim
-- flow matched a verified inbox against the roster. Invite links ended
-- that (20261027000000): possession of the code the owner personally
-- handed over is the proof, and the email column proves nothing. So the
-- member's primary label becomes what it already was socially — the NAME
-- the owner calls them, "Maya", matching the invite card ("Maya invited
-- you into their Sylos") — and email becomes optional contact metadata
-- the owner may record or skip.
--
-- Existing members are named from their email's local part (deduped);
-- the legacy email-OTP claim still works for any member who has an
-- email, and simply never matches one who doesn't.

alter table public.members
    add column name text;

-- Backfill: the email local part, capitalized; collisions numbered in
-- invitation order.
with base as (
    select id,
           initcap(split_part(email, '@', 1)) as stem,
           row_number() over (
               partition by lower(split_part(email, '@', 1))
               order by created_at, id
           ) as n
    from public.members
)
update public.members m
set name = case when b.n = 1 then b.stem else b.stem || ' ' || b.n::text end
from base b
where b.id = m.id;

alter table public.members
    alter column name set not null,
    add constraint members_name_check check (char_length(name) between 1 and 100);

-- One person per name, case-insensitively — the roster is one owner's
-- circle, and the name is how every list and embed labels them.
create unique index members_name_key on public.members (lower(name));

alter table public.members
    alter column email drop not null;

comment on table public.members is
    'People invited to read shared records through member_rq, named by what the owner calls them. Access is claimed with a single-use invite code the owner shares personally (claim_member_invite); email is optional contact metadata. Tokens and codes live only as sha256 hashes.';
comment on column public.members.name is
    'What the owner calls this person — the roster''s primary label, unique case-insensitively.';
comment on column public.members.email is
    'Optional contact metadata. Only the legacy email-OTP claim (claim_member_token) still reads it; a member without one simply cannot use that path.';

-- The owner writes names alongside the columns they already could; a
-- member's whoami gains their own name.
grant insert (name, email) on public.members to authenticated;
grant update (name, email) on public.members to authenticated;
grant select (name) on public.members to member;

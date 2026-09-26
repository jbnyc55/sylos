-- Guest visibility, the simple way: per group, tags allowed minus tags
-- denied — and the deny always wins.
--
-- The mental model is one sentence: "this group can see these kinds of
-- things, but never those." Concretely, each guest group keeps its allow
-- list (guest_group_tags, unchanged from 20260830050000) and gains a deny
-- list (guest_group_denied_tags). A group may see a record when the record
-- carries at least one of the group's allowed tags AND none of its denied
-- tags — a single denied tag on a record overpowers any number of allowed
-- ones. Each group is judged on its own; a guest sees the union of what
-- their groups may see, so joining another group never shrinks anyone's
-- view.
--
-- This extends to the wiki here too: wiki pages carry the same tags
-- (wiki_page_types, 20260831030000), and the same allow-minus-deny rule now
-- opens them to guests. An untagged record — note or page — matches no
-- allow list and is visible to no guest.
--
-- Tags therefore do double duty on purpose: they organize content (the
-- filter pills, the tagging routine) and they drive visibility. That is
-- the simplicity: tag once — the daily routine already does — and the
-- group settings do the rest. No per-record permission rows to maintain.

-- ---------------------------------------------------------------------------
-- guest_group_denied_tags — the deny list
-- ---------------------------------------------------------------------------

create table public.guest_group_denied_tags (
    group_id      uuid not null references public.guest_groups (id) on delete cascade,
    note_type_id  uuid not null references public.note_types (id) on delete cascade,
    primary key (group_id, note_type_id)
);

comment on table public.guest_group_denied_tags is
    'Tags a guest group must never see. A record carrying any of these is invisible to the group, whatever else it carries — deny overpowers allow.';

alter table public.guest_group_denied_tags enable row level security;

-- The owner toggles denies in the Guests tab, like allows.
grant select, insert, delete on public.guest_group_denied_tags to authenticated;

create policy "Denied tags are viewable by the owner"
    on public.guest_group_denied_tags for select
    to authenticated
    using (public.is_owner());

create policy "Denied tags are insertable by the owner"
    on public.guest_group_denied_tags for insert
    to authenticated
    with check (public.is_owner());

create policy "Denied tags are deletable by the owner"
    on public.guest_group_denied_tags for delete
    to authenticated
    using (public.is_owner());

create policy "claude reads everything"
    on public.guest_group_denied_tags for select
    to claude
    using (true);

-- Guests may read their own groups' deny rows — whoami transparency, like
-- the allow rows: a guest can see what their groups are barred from. The
-- record policies below do NOT rely on this; they go through the
-- SECURITY DEFINER deny checks further down.
grant select on public.guest_group_denied_tags to guest;

create policy "A guest reads their groups' denied tags"
    on public.guest_group_denied_tags for select
    to guest
    using (exists (
        select 1 from public.guest_group_members m
        where m.group_id = guest_group_denied_tags.group_id
          and m.guest_id = public.current_guest_id()
    ));

-- ---------------------------------------------------------------------------
-- The deny check, immune to row level security
-- ---------------------------------------------------------------------------
--
-- The subtlety that makes these two functions necessary: policy subqueries
-- run under the querying role's own RLS, and a guest's view of the tag-link
-- junctions only contains links for types their groups may read. A denied
-- type is by definition not in that view — so an inline "not exists" over
-- the junction would never see the very link that must hide the record.
-- SECURITY DEFINER lets the check read the whole junction; it returns only
-- a boolean, so nothing else escapes.

create function public.note_denied_for_group(_note_id uuid, _group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.manual_note_types j
        join public.guest_group_denied_tags d on d.note_type_id = j.note_type_id
        where j.note_id = _note_id
          and d.group_id = _group_id
    )
$$;

comment on function public.note_denied_for_group(uuid, uuid) is
    'True when the note carries any tag the group denies. SECURITY DEFINER so the check sees all of the note''s tag links, not just the ones guest RLS exposes.';

revoke all on function public.note_denied_for_group(uuid, uuid) from public;
grant execute on function public.note_denied_for_group(uuid, uuid) to guest;

create function public.page_denied_for_group(_page_id uuid, _group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.wiki_page_types j
        join public.guest_group_denied_tags d on d.note_type_id = j.note_type_id
        where j.page_id = _page_id
          and d.group_id = _group_id
    )
$$;

comment on function public.page_denied_for_group(uuid, uuid) is
    'True when the wiki page carries any tag the group denies. Same RLS-bypassing rationale as note_denied_for_group.';

revoke all on function public.page_denied_for_group(uuid, uuid) from public;
grant execute on function public.page_denied_for_group(uuid, uuid) to guest;

-- ---------------------------------------------------------------------------
-- Record visibility: allow minus deny, per group, union across groups
-- ---------------------------------------------------------------------------
--
-- The allow side needs no RLS-bypassing helper: a link that satisfies it is
-- for a type the group allows, which guest RLS on the junction already
-- exposes. The processing-declaration condition from 20260831020000 is
-- preserved on the allow side — an allowing tag must also admit the
-- request's declared processing location, and a missing declaration fails
-- closed. The deny side deliberately ignores processing: a denied tag
-- hides the record for that group under every declaration.

drop policy "Guests read notes tagged for their groups" on public.manual_notes;

create policy "Guests read notes their groups allow and none deny"
    on public.manual_notes for select
    to guest
    using (exists (
        select 1
        from public.guest_group_members m
        where m.guest_id = public.current_guest_id()
          and exists (
              select 1
              from public.manual_note_types j
              join public.note_types nt on nt.id = j.note_type_id
              join public.guest_group_tags a
                on a.note_type_id = j.note_type_id and a.group_id = m.group_id
              where j.note_id = manual_notes.id
                and public.current_guest_processing() = any (nt.allowed_processing)
          )
          and not public.note_denied_for_group(manual_notes.id, m.group_id)
    ));

-- Wiki pages join the same rule. Column-scoped like manual_notes — html is
-- the content being shared; vetting stamps and row_edits stay out of guest
-- reach entirely.
grant select (id, path, title, html, created_at, updated_at)
    on public.wiki_pages to guest;
grant select on public.wiki_page_types to guest;

create policy "Guests read pages their groups allow and none deny"
    on public.wiki_pages for select
    to guest
    using (exists (
        select 1
        from public.guest_group_members m
        where m.guest_id = public.current_guest_id()
          and exists (
              select 1
              from public.wiki_page_types j
              join public.note_types nt on nt.id = j.note_type_id
              join public.guest_group_tags a
                on a.note_type_id = j.note_type_id and a.group_id = m.group_id
              where j.page_id = wiki_pages.id
                and public.current_guest_processing() = any (nt.allowed_processing)
          )
          and not public.page_denied_for_group(wiki_pages.id, m.group_id)
    ));

-- Guests see a visible page's tag links, mirroring the note tag links
-- policy from 20260830050000 (their groups' readable types only).
create policy "Guests read page tag links in their groups"
    on public.wiki_page_types for select
    to guest
    using (exists (
        select 1
        from public.guest_group_tags ggt
        join public.guest_group_members m on m.group_id = ggt.group_id
        where m.guest_id = public.current_guest_id()
          and ggt.note_type_id = wiki_page_types.note_type_id
    ));

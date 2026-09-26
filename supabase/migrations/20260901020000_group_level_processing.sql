-- Processing location becomes a group setting, not a tag setting.
--
-- 20260831020000 hung the local/cloud question on each note type: a guest
-- request declares where its results will be processed, and every tag it
-- reads through has to admit that location. In practice the question being
-- answered is about people, not content: "may family run cloud requests?"
-- is one sentence about the family group, not a toggle repeated across
-- every tag the group can see. So the setting moves to guest_groups: each
-- group lists the processing locations it admits, and a request from a
-- guest reads a record through a group only when that group admits the
-- declared location. Tags go back to doing what they did before
-- 20260831020000 — organizing content and scoping visibility — and the
-- allow/deny lists are unchanged.
--
-- Union semantics carry over unchanged: each group is judged on its own,
-- and a guest sees the union over their groups, so a guest in one
-- local-only group and one cloud-admitting group gets cloud results for
-- exactly what the cloud-admitting group can see.
--
-- The declaration machinery (guest_rq's required _processing argument,
-- current_guest_processing()) is untouched; only what the declaration is
-- checked against changes.

-- ---------------------------------------------------------------------------
-- The group setting
-- ---------------------------------------------------------------------------

alter table public.guest_groups
    add column allowed_processing text[] not null default array['local'],
    add constraint guest_groups_known_processing
        check (allowed_processing <@ array['local', 'cloud']);

comment on column public.guest_groups.allowed_processing is
    'Processing locations a guest request may declare and still read records through this group. Defaults to local-only — cloud is an explicit owner opt-in per group.';

-- Carry the old per-tag settings over without widening access: a group
-- admitted cloud for a given record only through a cloud-admitting tag, so
-- it keeps cloud only if every tag it may read admitted cloud. Mixed groups
-- fall back to local-only — the owner re-opts them in from the Guests tab.
update public.guest_groups g
set allowed_processing = array['local', 'cloud']
where exists (
        select 1 from public.guest_group_tags a
        where a.group_id = g.id
    )
  and not exists (
        select 1
        from public.guest_group_tags a
        join public.note_types nt on nt.id = a.note_type_id
        where a.group_id = g.id
          and not ('cloud' = any (nt.allowed_processing))
    );

-- The owner flips these from the Guests tab, like the tag toggle before.
grant update (allowed_processing) on public.guest_groups to authenticated;

create policy "Guest group settings are updatable by the owner"
    on public.guest_groups for update
    to authenticated
    using (public.is_owner())
    with check (public.is_owner());

-- Guests may see each of their groups' settings, so a refusal is
-- explainable — same whoami transparency the tag setting had.
grant select (allowed_processing) on public.guest_groups to guest;

-- ---------------------------------------------------------------------------
-- Enforcement: the declared location is checked against the group
-- ---------------------------------------------------------------------------
--
-- Same allow-minus-deny shape as 20260831040000, with the processing
-- condition lifted out of the tag join and onto the group membership: a
-- group only connects guest to record for locations it admits. With no
-- declaration stamped, current_guest_processing() is null, = any() is never
-- true, and the policies fail closed, exactly as before.
--
-- The old policies go first: they reference note_types.allowed_processing,
-- and Postgres will not drop that column (below) while a policy depends on
-- it.

drop policy "Guests read notes their groups allow and none deny" on public.manual_notes;
drop policy "Guests read pages their groups allow and none deny" on public.wiki_pages;

create policy "Guests read notes their groups allow and none deny"
    on public.manual_notes for select
    to guest
    using (exists (
        select 1
        from public.guest_group_members m
        join public.guest_groups g on g.id = m.group_id
        where m.guest_id = public.current_guest_id()
          and public.current_guest_processing() = any (g.allowed_processing)
          and exists (
              select 1
              from public.manual_note_types j
              join public.guest_group_tags a
                on a.note_type_id = j.note_type_id and a.group_id = m.group_id
              where j.note_id = manual_notes.id
          )
          and not public.note_denied_for_group(manual_notes.id, m.group_id)
    ));

create policy "Guests read pages their groups allow and none deny"
    on public.wiki_pages for select
    to guest
    using (exists (
        select 1
        from public.guest_group_members m
        join public.guest_groups g on g.id = m.group_id
        where m.guest_id = public.current_guest_id()
          and public.current_guest_processing() = any (g.allowed_processing)
          and exists (
              select 1
              from public.wiki_page_types j
              join public.guest_group_tags a
                on a.note_type_id = j.note_type_id and a.group_id = m.group_id
              where j.page_id = wiki_pages.id
          )
          and not public.page_denied_for_group(wiki_pages.id, m.group_id)
    ));

-- ---------------------------------------------------------------------------
-- The tag setting goes away
-- ---------------------------------------------------------------------------

-- Dropping the column takes its check constraint and the column-scoped
-- grants (owner update, guest select) with it.
alter table public.note_types
    drop column allowed_processing;

-- That column's update grant was the only thing this policy served; the
-- original owner update policy from the init migration still covers
-- note_types updates.
drop policy "Note type settings are updatable by the owner" on public.note_types;

-- Docs learn to be shared by name, not only by tag: tagging grows kinds.
--
-- Until now the only thing a doc could carry was a note_types tag, and
-- member visibility hung entirely off the groups' allow/deny tag lists
-- (20260831040000). The picker in the app now offers four kinds of "tag" —
-- a tag, a person, a member group, and Syla — and each non-tag kind is its
-- own junction here, because each one means something different:
--
--   * doc_guests — the owner names a person on a doc. Explicit, per-record,
--     per-person: that guest reads the doc through guest_rq whatever their
--     groups' tag rules say (a direct grant is the individual exception the
--     group machinery cannot express). A guest in no group at all can be
--     granted a doc this way.
--   * doc_guest_groups — the owner names a member group on a doc. This is a
--     group-level grant, so it stays governed by group-level settings: the
--     group's allows_sql switch and its denied tags still apply — a single
--     denied tag on the doc keeps it invisible to that group, direct grant
--     or not, preserving "deny overpowers everything" at the group level.
--   * doc_syla — the owner marks a doc as Syla's. The claude role already
--     reads every doc, so today this junction changes no access; it exists
--     so Syla is a first-class principal in the same picker (organize her
--     docs, flag one for her attention) and is the hook if her read surface
--     is ever narrowed.
--
-- Tag-based visibility is untouched: the existing allow-minus-deny rule
-- remains one of three OR'd paths in the docs guest policy below. What
-- changes is the sentence "an untagged record is visible to no guest" —
-- now: a record carrying no tag, no person and no group is visible to no
-- guest.
--
-- Sharing stays the owner's decision alone: like guest_group_tags, these
-- junctions give the claude role read (to know what a grant exposes) but no
-- write path. The row_edits event trigger (20260831010000) attaches logging
-- to all three tables at creation, so every grant and revoke is undoable
-- history like any other change. Each junction carries a surrogate uuid id
-- for the same reason doc_note_types does: the log wants a row_id.
--
-- Version note: this file first shipped stamped 20260923000000 — a version
-- production's migration history already held (goal_pause, applied outside
-- the repo alongside 20260924000000 goal_cell_synergy). Versions are the
-- primary key of the tracking table, so the GitHub integration silently
-- skipped this file as already applied and the app asked for tables that
-- did not exist ("could not find a relationship in the schema cache") —
-- the docs_rename lesson (20260908020000) all over again. Re-stamped past
-- the applied history; the body is unchanged.

-- ---------------------------------------------------------------------------
-- The junctions
-- ---------------------------------------------------------------------------

create table public.doc_guests (
    id        uuid primary key default gen_random_uuid(),
    doc_id    uuid not null references public.docs (id) on delete cascade,
    guest_id  uuid not null references public.guests (id) on delete cascade,
    unique (doc_id, guest_id)
);

comment on table public.doc_guests is
    'People named directly on a doc. A listed guest reads the doc through guest_rq regardless of group tag rules — an explicit per-person grant by the owner. Changes land in row_edits by the auto-attached trigger.';

-- "Every doc granted to this guest" is the policy read; doc → people comes
-- free with the unique constraint's index.
create index doc_guests_guest_doc_idx
    on public.doc_guests (guest_id, doc_id);

create table public.doc_guest_groups (
    id        uuid primary key default gen_random_uuid(),
    doc_id    uuid not null references public.docs (id) on delete cascade,
    group_id  uuid not null references public.guest_groups (id) on delete cascade,
    unique (doc_id, group_id)
);

comment on table public.doc_guest_groups is
    'Member groups named directly on a doc. Members read the doc without any allowing tag, but the group''s allows_sql switch and denied tags still apply — deny keeps winning at the group level. Changes land in row_edits by the auto-attached trigger.';

create index doc_guest_groups_group_doc_idx
    on public.doc_guest_groups (group_id, doc_id);

create table public.doc_syla (
    id      uuid primary key default gen_random_uuid(),
    doc_id  uuid not null references public.docs (id) on delete cascade,
    unique (doc_id)
);

comment on table public.doc_syla is
    'Docs marked as Syla''s. Grants nothing today — the claude role already reads every doc — but makes Syla a taggable principal like people and groups, and is the hook if her read surface is ever narrowed.';

-- ---------------------------------------------------------------------------
-- Row level security + grants
-- ---------------------------------------------------------------------------

alter table public.doc_guests       enable row level security;
alter table public.doc_guest_groups enable row level security;
alter table public.doc_syla        enable row level security;

-- The owner grants and revokes from the doc picker, like tag pills.
grant select, insert, delete on public.doc_guests       to authenticated;
grant select, insert, delete on public.doc_guest_groups to authenticated;
grant select, insert, delete on public.doc_syla        to authenticated;

create policy "Doc person grants are viewable by the owner"
    on public.doc_guests for select
    to authenticated
    using (public.is_owner());

create policy "Doc person grants are insertable by the owner"
    on public.doc_guests for insert
    to authenticated
    with check (public.is_owner());

create policy "Doc person grants are deletable by the owner"
    on public.doc_guests for delete
    to authenticated
    using (public.is_owner());

create policy "Doc group grants are viewable by the owner"
    on public.doc_guest_groups for select
    to authenticated
    using (public.is_owner());

create policy "Doc group grants are insertable by the owner"
    on public.doc_guest_groups for insert
    to authenticated
    with check (public.is_owner());

create policy "Doc group grants are deletable by the owner"
    on public.doc_guest_groups for delete
    to authenticated
    using (public.is_owner());

create policy "Doc Syla marks are viewable by the owner"
    on public.doc_syla for select
    to authenticated
    using (public.is_owner());

create policy "Doc Syla marks are insertable by the owner"
    on public.doc_syla for insert
    to authenticated
    with check (public.is_owner());

create policy "Doc Syla marks are deletable by the owner"
    on public.doc_syla for delete
    to authenticated
    using (public.is_owner());

-- claude reads the grants (to know what a doc exposes) but, like the
-- groups' tag allow/deny lists, holds no write path — naming a person is a
-- sharing decision, and sharing decisions are the owner's.
create policy "claude reads everything"
    on public.doc_guests for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.doc_guest_groups for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.doc_syla for select
    to claude
    using (true);

-- Whoami transparency, matching the groups' tag lists: a guest sees their
-- own direct grants and their groups' grants — also what the docs policy
-- below reads, since policy subqueries run under the querying role's RLS.
grant select on public.doc_guests       to guest;
grant select on public.doc_guest_groups to guest;

create policy "A guest reads their own doc grants"
    on public.doc_guests for select
    to guest
    using (guest_id = public.current_guest_id());

create policy "A guest reads their groups' doc grants"
    on public.doc_guest_groups for select
    to guest
    using (exists (
        select 1 from public.guest_group_members m
        where m.group_id = doc_guest_groups.group_id
          and m.guest_id = public.current_guest_id()
    ));

-- ---------------------------------------------------------------------------
-- The docs guest policy: tag path, person path, group path
-- ---------------------------------------------------------------------------
--
-- The 20260908020000 policy, plus two OR'd grant paths. The tag path is
-- byte-for-byte the old rule; the person path is unconditional by design
-- (see the header); the group path repeats the group-level gates.

drop policy "Guests read docs their groups allow and none deny" on public.docs;

create policy "Guests read docs granted by tag, name, or group"
    on public.docs for select
    to guest
    using (
        exists (
            select 1 from public.doc_guests dg
            where dg.doc_id = docs.id
              and dg.guest_id = public.current_guest_id()
        )
        or exists (
            select 1
            from public.doc_guest_groups dgg
            join public.guest_group_members m on m.group_id = dgg.group_id
            join public.guest_groups g on g.id = dgg.group_id
            where dgg.doc_id = docs.id
              and m.guest_id = public.current_guest_id()
              and g.allows_sql
              and not public.doc_denied_for_group(docs.id, dgg.group_id)
        )
        or exists (
            select 1
            from public.guest_group_members m
            join public.guest_groups g on g.id = m.group_id
            where m.guest_id = public.current_guest_id()
              and g.allows_sql
              and exists (
                  select 1
                  from public.doc_note_types j
                  join public.guest_group_tags a
                    on a.note_type_id = j.note_type_id and a.group_id = m.group_id
                  where j.doc_id = docs.id
              )
              and not public.doc_denied_for_group(docs.id, m.group_id)
        )
    );

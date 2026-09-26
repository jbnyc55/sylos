-- Vibe code apps: the tools leave the bundle.
--
-- A VIBE CODE APP is a whole client-side app — dual n-back, a trainer, a
-- utility — bundled by Vite into ONE self-contained HTML file and stored
-- here, the way docs are stored: a table of files, served straight from
-- Supabase over PostgREST with the caller's session deciding what they may
-- read. The main app stops carrying these tools in its own bundle; the
-- Vibe Code Projects list reads this table, and opening an app fetches its
-- html and runs it in an iframe, with the parent handing the session in by
-- postMessage (the contract lives in vibes/README.md).
--
-- Why a table and not a storage bucket: the write path. Agent sessions
-- deploy bundles over the existing HTTPS RPC surface (assert_claude_rq_key
-- → set local role claude), exactly like docs — no service key, no signed
-- URLs, and the row_edits event trigger gives every deploy a full
-- before/after image, so a bad build is one upsert away from undone.
-- Bundles are capped at 5 MB (docs cap at 2; an app bundle carries React).
--
-- Permissioning is the app-wide sentence: a member sees a vibe code app
-- when they are named on it, or it sits in a silo where their membership
-- allows SQL. The junctions are the standard shape (vibe_code_app_silos /
-- vibe_code_app_members) so the long-press drawer's ItemGrants works
-- unchanged, and siloed_at is the usual by-hand stamp.

create table public.vibe_code_apps (
    id          uuid primary key default gen_random_uuid(),
    -- The stable handle deploys upsert on, and the name a built-in tool
    -- page must match to be superseded (web/src/lib/pages.ts ids).
    slug        text not null unique
                check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) <= 100),
    name        text not null check (char_length(name) between 1 and 200),
    -- The list row's second line, like a tool's hint on the Tools page.
    hint        text not null default '' check (char_length(hint) <= 500),
    -- The entire app: one self-contained HTML file, scripts inlined by the
    -- vibes/ build. Same doctype tripwire as docs; self-containedness is
    -- the build's contract, not something SQL can prove.
    html        text not null
                check (html ~* '^\s*<!doctype html' and char_length(html) <= 5000000),
    -- Marked siloed by hand: out of any to-silo backlog without placements.
    siloed_at   timestamptz,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

comment on table public.vibe_code_apps is
    'One row per vibe code app: a complete client-side app as a single self-contained HTML file, deployed by the vibes/ build through save_vibe_code_app and run in an iframe by the web app. Visibility follows silos and members like docs.';
comment on column public.vibe_code_apps.slug is
    'Deploy handle (upsert key). A built-in tool page with this id on the Tools page is hidden once the app row exists — the cutover is the deploy.';
comment on column public.vibe_code_apps.html is
    'The whole app, scripts and styles inlined. The parent page posts the Supabase session into the iframe; vibes/README.md holds the message contract.';

create trigger vibe_code_apps_set_updated_at
    before update on public.vibe_code_apps
    for each row execute function public.set_updated_at();

-- ── The junctions: the standard silos-and-members shape ──────────────────

create table public.vibe_code_app_silos (
    app_id      uuid not null references public.vibe_code_apps (id) on delete cascade,
    silo_id     uuid not null references public.silos (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (app_id, silo_id)
);
create table public.vibe_code_app_members (
    app_id      uuid not null references public.vibe_code_apps (id) on delete cascade,
    member_id   uuid not null references public.members (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (app_id, member_id)
);

comment on table public.vibe_code_app_silos is
    'Which silos a vibe code app sits in. Placing the app in a silo IS the grant to that silo''s members, same as every record type.';
comment on table public.vibe_code_app_members is
    'The individual exception: the named member reads the app whatever the silo placements say.';

create index vibe_code_app_silos_silo_id_idx on public.vibe_code_app_silos (silo_id);
create index vibe_code_app_members_member_id_idx on public.vibe_code_app_members (member_id);

-- ── The source, next to the bundle ───────────────────────────────────────
--
-- The bundle is what runs; the SOURCE is what gets edited next time, and
-- it must not depend on GitHub: an agent session changes an app by
-- reading these rows (scripts/rq), editing, rebuilding with any generic
-- Vite toolchain (the repo's vibes/ workspace is one), and saving bundle
-- and source back in one deploy. One row per file, path-addressed like
-- docs — the app's source tree as data. The repo's vibes/<slug>/ folder
-- is a seed and a working copy; after the first deploy, this table is
-- canonical.

create table public.vibe_code_app_files (
    id          uuid primary key default gen_random_uuid(),
    app_id      uuid not null references public.vibe_code_apps (id) on delete cascade,
    -- Relative path inside the app folder: main.tsx, lib/engine.ts.
    path        text not null
                check (path ~ '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'
                       and char_length(path) <= 300),
    content     text not null check (char_length(content) <= 1000000),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    unique (app_id, path)
);

comment on table public.vibe_code_app_files is
    'The app''s source tree, one row per file — so changing a vibe code app needs the database and a generic build toolchain, never the git repo. Replaced wholesale by save_vibe_code_app_files on each deploy.';

create trigger vibe_code_app_files_set_updated_at
    before update on public.vibe_code_app_files
    for each row execute function public.set_updated_at();

-- ── Row level security ───────────────────────────────────────────────────

alter table public.vibe_code_apps enable row level security;
alter table public.vibe_code_app_silos enable row level security;
alter table public.vibe_code_app_members enable row level security;
alter table public.vibe_code_app_files enable row level security;

-- The owner runs the show from the app, docs-style (no profile_id: this is
-- a single-owner system and the apps are the system's, like docs).
create policy "Vibe code apps are viewable by the owner"
    on public.vibe_code_apps for select to authenticated
    using (public.is_owner());
create policy "Vibe code apps are insertable by the owner"
    on public.vibe_code_apps for insert to authenticated
    with check (public.is_owner());
create policy "Vibe code apps are updatable by the owner"
    on public.vibe_code_apps for update to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "Vibe code apps are deletable by the owner"
    on public.vibe_code_apps for delete to authenticated
    using (public.is_owner());

-- The claude role deploys: full DML through the RPCs below, every write
-- imaged into row_edits by the event trigger like everywhere else.
create policy "claude reads vibe code apps"
    on public.vibe_code_apps for select to claude using (true);
create policy "claude writes vibe code apps"
    on public.vibe_code_apps for insert to claude with check (true);
create policy "claude updates vibe code apps"
    on public.vibe_code_apps for update to claude using (true) with check (true);
create policy "claude deletes vibe code apps"
    on public.vibe_code_apps for delete to claude using (true);

-- Members read an app when they share a silo with it (their own
-- membership's allows_sql, the member-held permission) or it names them —
-- the docs sentence, verbatim.
create policy "Members read vibe code apps in their silos or naming them"
    on public.vibe_code_apps for select
    to member
    using (
        exists (
            select 1
            from public.vibe_code_app_silos j
            join public.silo_members sm on sm.silo_id = j.silo_id
            where j.app_id = vibe_code_apps.id
              and sm.member_id = public.current_member_id()
              and sm.allows_sql
        )
        or exists (
            select 1 from public.vibe_code_app_members am
            where am.app_id = vibe_code_apps.id
              and am.member_id = public.current_member_id()
        )
    );

-- Source is the owner's and the deployer's; members get the running app,
-- never the tree it was built from.
create policy "Vibe app files are viewable by the owner"
    on public.vibe_code_app_files for select to authenticated
    using (public.is_owner());
create policy "claude reads vibe app files"
    on public.vibe_code_app_files for select to claude using (true);
create policy "claude writes vibe app files"
    on public.vibe_code_app_files for insert to claude with check (true);
create policy "claude updates vibe app files"
    on public.vibe_code_app_files for update to claude using (true) with check (true);
create policy "claude deletes vibe app files"
    on public.vibe_code_app_files for delete to claude using (true);

create policy "Vibe app silos follow the owner"
    on public.vibe_code_app_silos for all to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "Vibe app members follow the owner"
    on public.vibe_code_app_members for all to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "claude reads vibe app silos"
    on public.vibe_code_app_silos for select to claude using (true);
create policy "claude reads vibe app members"
    on public.vibe_code_app_members for select to claude using (true);

-- The member policy on vibe_code_apps runs its subqueries under these
-- tables' own RLS, so members need read on the junction rows that concern
-- them — the same backing the docs member policy has on doc_silos and
-- doc_members (20260926000000).
create policy "A member reads app silo links in their silos"
    on public.vibe_code_app_silos for select
    to member
    using (exists (
        select 1 from public.silo_members sm
        where sm.silo_id = vibe_code_app_silos.silo_id
          and sm.member_id = public.current_member_id()
    ));
create policy "A member reads app links naming them"
    on public.vibe_code_app_members for select
    to member
    using (member_id = public.current_member_id());

grant select, insert, update, delete on public.vibe_code_apps to authenticated;
grant select, insert, delete on public.vibe_code_app_silos to authenticated;
grant select, insert, delete on public.vibe_code_app_members to authenticated;
grant select, insert, update, delete on public.vibe_code_apps to claude;
grant select on public.vibe_code_app_silos to claude;
grant select on public.vibe_code_app_members to claude;
grant select on public.vibe_code_app_files to authenticated;
grant select, insert, update, delete on public.vibe_code_app_files to claude;
grant select on public.vibe_code_apps to member;
grant select on public.vibe_code_app_silos to member;
grant select on public.vibe_code_app_members to member;

-- ── The deploy RPCs — save_vibe_code_app, delete_vibe_code_app ───────────
--
-- Same shape as save_doc / delete_doc: gated by assert_claude_rq_key(),
-- running as the claude role, wrapped by scripts/vibe-save. The upsert key
-- is the slug, so redeploying an app is one call and one row_edits entry.

create function public.save_vibe_code_app(
    _slug text, _name text, _hint text, _html text
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _existed boolean;
    _id      uuid;
begin
    perform public.assert_claude_rq_key();

    if _slug is null or _name is null or _html is null then
        raise exception 'slug, name and html are all required';
    end if;

    set local statement_timeout = '60s';
    set local role claude;

    _existed := exists (select 1 from public.vibe_code_apps where slug = _slug);

    insert into public.vibe_code_apps (slug, name, hint, html)
    values (_slug, _name, coalesce(_hint, ''), _html)
    on conflict (slug) do update
        set name = excluded.name,
            hint = excluded.hint,
            html = excluded.html
    returning id into _id;

    return jsonb_build_object(
        'app_id', _id,
        'slug',   _slug,
        'op',     case when _existed then 'updated' else 'created' end
    );
end;
$$;

comment on function public.save_vibe_code_app(text, text, text, text) is
    'Creates or replaces one vibe code app by slug, as the claude role. Gated by assert_claude_rq_key().';

create function public.delete_vibe_code_app(_slug text)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _id uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    delete from public.vibe_code_apps
    where slug = _slug
    returning id into _id;

    if _id is null then
        raise exception 'no vibe code app with slug %', _slug;
    end if;

    return jsonb_build_object('app_id', _id, 'slug', _slug);
end;
$$;

comment on function public.delete_vibe_code_app(text) is
    'Deletes one vibe code app by slug, as the claude role — recoverable, the row image is already logged. Gated by assert_claude_rq_key().';

-- Replace an app's source tree wholesale: _files is a JSON array of
-- {path, content}. Wholesale like set_doc_silos, so a deploy can never
-- leave a stale file behind, and idempotent for identical trees.
create function public.save_vibe_code_app_files(_slug text, _files jsonb)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _id    uuid;
    _count integer;
begin
    perform public.assert_claude_rq_key();

    if _slug is null or _files is null or jsonb_typeof(_files) <> 'array' then
        raise exception 'slug and a files array are required';
    end if;

    set local statement_timeout = '60s';
    set local role claude;

    select id into _id from public.vibe_code_apps where slug = _slug;
    if _id is null then
        raise exception 'no vibe code app with slug % — save the bundle first', _slug;
    end if;

    delete from public.vibe_code_app_files where app_id = _id;

    insert into public.vibe_code_app_files (app_id, path, content)
    select _id, f->>'path', f->>'content'
    from jsonb_array_elements(_files) f;

    get diagnostics _count = row_count;

    return jsonb_build_object('app_id', _id, 'slug', _slug, 'files', _count);
end;
$$;

comment on function public.save_vibe_code_app_files(text, jsonb) is
    'Replaces one vibe code app''s source tree wholesale, as the claude role. Gated by assert_claude_rq_key(). Source lives here so editing an app never needs the git repo.';

revoke all on function public.save_vibe_code_app(text, text, text, text) from public;
grant execute on function public.save_vibe_code_app(text, text, text, text) to anon;
revoke all on function public.delete_vibe_code_app(text) from public;
grant execute on function public.delete_vibe_code_app(text) to anon;
revoke all on function public.save_vibe_code_app_files(text, jsonb) from public;
grant execute on function public.save_vibe_code_app_files(text, jsonb) to anon;

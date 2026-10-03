-- Minis: the vibe code apps take their product name.
--
-- The product calls them MINIS now — the little apps Syla builds and
-- people share, already "minis" in the chat vocabulary (chat_minis on
-- the company side) — and the database agrees, the same move
-- 20261119000000 made when members became followers. One word, every
-- object:
--
--   * vibe_code_apps → minis, and the junctions and source follow:
--     vibe_code_app_silos → mini_silos, vibe_code_app_followers →
--     mini_followers, vibe_code_app_files → mini_files, with app_id →
--     mini_id in all three.
--   * The deploy surface speaks the same word: save_vibe_code_app →
--     save_mini, save_vibe_code_app_files → save_mini_files,
--     set_vibe_code_app_open → set_mini_open, delete_vibe_code_app →
--     delete_mini (scripts/vibe-save → scripts/mini-save in the same
--     commit). The RPCs' result key app_id becomes mini_id.
--   * The travelling share message follows: chat_messages kind
--     'app_share' → 'mini_share', app_slug → mini_slug — existing
--     share rows are restamped so one kind means one thing.
--
-- Like the followers rename, NO app-named wrappers remain: the point is
-- that the word is gone. The clients and scripts in the two repos move
-- in the same commit. row_edits history keeps the old table names in
-- old rows, append-only by contract; readers match both.
--
-- Mechanics, same as last time: policies, grants, junction registry
-- rows (data_tables matches on table_oid) and constraint expressions
-- track renames by oid, so ALTER ... RENAME carries them; plpgsql
-- bodies do NOT, so the four deploy RPCs are re-created below with the
-- new names. Constraint, index and trigger NAMES are renamed
-- programmatically — they are many, mechanical, and the pattern is the
-- whole rule.

-- ─── The tables take their real names ────────────────────────────────────

alter table public.vibe_code_apps rename to minis;
alter table public.vibe_code_app_silos rename to mini_silos;
alter table public.vibe_code_app_followers rename to mini_followers;
alter table public.vibe_code_app_files rename to mini_files;

alter table public.mini_silos rename column app_id to mini_id;
alter table public.mini_followers rename column app_id to mini_id;
alter table public.mini_files rename column app_id to mini_id;

-- The registry follows the oids; one explicit pass rather than waiting
-- for the next DDL to re-enter the warden.
select public.reconcile_table_siloing();

-- ─── Constraint, index and trigger names follow ──────────────────────────
--
-- Every name is a mechanical derivation of the table and column names
-- (vibe_code_apps_pkey, vibe_code_app_files_app_id_fkey,
-- vibe_code_apps_log_edits, …), so the rename is the same derivation:
-- vibe_code_apps → minis, vibe_code_app → mini, app_id → mini_id.
-- Renaming a constraint renames its backing index with it; the index
-- loop below only catches the plain ones left over.

do $$
declare
    r record;
    f text;
begin
    for r in
        select conrelid::regclass as rel, conname
        from pg_constraint
        where connamespace = 'public'::regnamespace
          and conname like '%vibe_code_app%'
    loop
        f := replace(replace(replace(r.conname,
                 'vibe_code_apps', 'minis'),
                 'vibe_code_app', 'mini'),
                 'app_id', 'mini_id');
        execute format('alter table %s rename constraint %I to %I', r.rel, r.conname, f);
    end loop;

    for r in
        select indexname
        from pg_indexes
        where schemaname = 'public' and indexname like '%vibe_code_app%'
    loop
        f := replace(replace(replace(r.indexname,
                 'vibe_code_apps', 'minis'),
                 'vibe_code_app', 'mini'),
                 'app_id', 'mini_id');
        execute format('alter index public.%I rename to %I', r.indexname, f);
    end loop;

    for r in
        select tgname, tgrelid::regclass as rel
        from pg_trigger
        where not tgisinternal and tgname like '%vibe_code_app%'
    loop
        f := replace(replace(r.tgname,
                 'vibe_code_apps', 'minis'),
                 'vibe_code_app', 'mini');
        execute format('alter trigger %I on %s rename to %I', r.tgname, r.rel, f);
    end loop;
end;
$$;

-- ─── Policy names follow ─────────────────────────────────────────────────

alter policy "Vibe code apps are viewable by the owner" on public.minis rename to "Minis are viewable by the owner";
alter policy "Vibe code apps are insertable by the owner" on public.minis rename to "Minis are insertable by the owner";
alter policy "Vibe code apps are updatable by the owner" on public.minis rename to "Minis are updatable by the owner";
alter policy "Vibe code apps are deletable by the owner" on public.minis rename to "Minis are deletable by the owner";
alter policy "claude reads vibe code apps" on public.minis rename to "claude reads minis";
alter policy "claude writes vibe code apps" on public.minis rename to "claude writes minis";
alter policy "claude updates vibe code apps" on public.minis rename to "claude updates minis";
alter policy "claude deletes vibe code apps" on public.minis rename to "claude deletes minis";
alter policy "Followers read vibe code apps in their silos or naming them" on public.minis rename to "Followers read minis in their silos or naming them";
alter policy "Followers read vibe code apps in public silos" on public.minis rename to "Followers read minis in public silos";
alter policy "Signed-in users read vibe code apps open to them" on public.minis rename to "Signed-in users read minis open to them";

alter policy "Vibe app silos follow the owner" on public.mini_silos rename to "Mini silos follow the owner";
alter policy "claude reads vibe app silos" on public.mini_silos rename to "claude reads mini silos";
alter policy "A follower reads app silo links in their silos" on public.mini_silos rename to "A follower reads mini silo links in their silos";
alter policy "A follower reads app silo links into public silos" on public.mini_silos rename to "A follower reads mini silo links into public silos";

alter policy "Vibe app followers follow the owner" on public.mini_followers rename to "Mini followers follow the owner";
alter policy "claude reads vibe app followers" on public.mini_followers rename to "claude reads mini followers";
alter policy "A follower reads app links naming them" on public.mini_followers rename to "A follower reads mini links naming them";

alter policy "Vibe app files are viewable by the owner" on public.mini_files rename to "Mini files are viewable by the owner";
alter policy "claude reads vibe app files" on public.mini_files rename to "claude reads mini files";
alter policy "claude writes vibe app files" on public.mini_files rename to "claude writes mini files";
alter policy "claude updates vibe app files" on public.mini_files rename to "claude updates mini files";
alter policy "claude deletes vibe app files" on public.mini_files rename to "claude deletes mini files";
alter policy "Followers read an app's manifest in their silos or naming them" on public.mini_files rename to "Followers read a mini's manifest in their silos or naming them";

-- ─── The comments speak minis ────────────────────────────────────────────

comment on table public.minis is
    'One row per mini: a complete client-side app as a single self-contained HTML file, deployed through save_mini and run in an iframe/web view by the shells. Visibility follows silos and followers like docs.';
comment on column public.minis.slug is
    'Deploy handle (upsert key). A built-in tool page with this id is hidden once the mini row exists — the cutover is the deploy.';
comment on column public.minis.html is
    'The whole mini, scripts and styles inlined. The Sylos app runs it in a WKWebView with window.SYLOS_CONFIG (supabaseUrl, supabaseAnonKey, session) injected before any script executes — the skills/minis doc holds the contract.';
comment on column public.minis.icon is
    'The home-screen icon: an emoji, or one inline <svg> element. Shells render svg as an <img> data URI (an image, never a script context) and anything else as text; empty means a tinted glyph square derived from the name.';
comment on column public.minis.open_to_signed_in is
    'When true, any signed-in session may read (and so run) this mini, not just the owner and its followers. Set by set_mini_open (scripts/mini-save --open-to-signed-in).';
comment on table public.mini_silos is
    'Which silos a mini sits in. Placing the mini in a silo IS the grant to that silo''s followers, same as every record type.';
comment on table public.mini_followers is
    'The individual exception: the named follower reads the mini whatever the silo placements say.';
comment on table public.mini_files is
    'The mini''s source tree, one row per file — so changing a mini needs the database and a generic build toolchain, never the git repo. Replaced wholesale by save_mini_files on each deploy. sylos-manifest.json rides here too.';

-- ─── The deploy RPCs, re-created under the new names ─────────────────────
--
-- Bodies are the 20261115000000 / 20261010000000 / 20261008000000
-- versions with the new object names; the result key app_id becomes
-- mini_id. The old functions are dropped — no wrappers.

drop function public.save_vibe_code_app(text, text, text, text, text);
drop function public.save_vibe_code_app_files(text, jsonb);
drop function public.set_vibe_code_app_open(text, boolean);
drop function public.delete_vibe_code_app(text);

create function public.save_mini(
    _slug text, _name text, _hint text, _html text, _icon text default null
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

    _existed := exists (select 1 from public.minis where slug = _slug);

    insert into public.minis (slug, name, hint, html, icon)
    values (_slug, _name, coalesce(_hint, ''), _html, coalesce(_icon, ''))
    on conflict (slug) do update
        set name = excluded.name,
            hint = excluded.hint,
            html = excluded.html,
            icon = coalesce(_icon, minis.icon)
    returning id into _id;

    return jsonb_build_object(
        'mini_id', _id,
        'slug',    _slug,
        'op',      case when _existed then 'updated' else 'created' end
    );
end;
$$;

comment on function public.save_mini(text, text, text, text, text) is
    'Creates or replaces one mini by slug, as the claude role. _icon null keeps the stored icon, '''' clears it. Gated by assert_claude_rq_key().';

revoke all on function public.save_mini(text, text, text, text, text) from public;
grant execute on function public.save_mini(text, text, text, text, text) to anon;

create function public.save_mini_files(_slug text, _files jsonb)
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

    select id into _id from public.minis where slug = _slug;
    if _id is null then
        raise exception 'no mini with slug % — save the bundle first', _slug;
    end if;

    delete from public.mini_files where mini_id = _id;

    insert into public.mini_files (mini_id, path, content)
    select _id, f->>'path', f->>'content'
    from jsonb_array_elements(_files) f;

    get diagnostics _count = row_count;

    return jsonb_build_object('mini_id', _id, 'slug', _slug, 'files', _count);
end;
$$;

comment on function public.save_mini_files(text, jsonb) is
    'Replaces one mini''s source tree wholesale, as the claude role. Gated by assert_claude_rq_key(). Source lives here so editing a mini never needs the git repo.';

revoke all on function public.save_mini_files(text, jsonb) from public;
grant execute on function public.save_mini_files(text, jsonb) to anon;

create function public.set_mini_open(_slug text, _open boolean)
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

    update public.minis
    set open_to_signed_in = coalesce(_open, false)
    where slug = _slug
    returning id into _id;

    if _id is null then
        raise exception 'no mini with slug %', _slug;
    end if;

    return jsonb_build_object(
        'mini_id', _id, 'slug', _slug, 'open_to_signed_in', coalesce(_open, false));
end;
$$;

comment on function public.set_mini_open(text, boolean) is
    'Opens (or closes) one mini to every signed-in session, as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.set_mini_open(text, boolean) from public;
grant execute on function public.set_mini_open(text, boolean) to anon;

create function public.delete_mini(_slug text)
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

    delete from public.minis
    where slug = _slug
    returning id into _id;

    if _id is null then
        raise exception 'no mini with slug %', _slug;
    end if;

    return jsonb_build_object('mini_id', _id, 'slug', _slug);
end;
$$;

comment on function public.delete_mini(text) is
    'Deletes one mini by slug, as the claude role — recoverable, the row image is already logged. Gated by assert_claude_rq_key().';

revoke all on function public.delete_mini(text) from public;
grant execute on function public.delete_mini(text) to anon;

-- ─── The share message follows: app_share → mini_share ──────────────────
--
-- The kind check has to be re-created to change its value set, and the
-- existing share rows are restamped in the same breath, so 'mini_share'
-- is the one spelling on both sides of the constraint. The body check
-- tracks the column rename by attnum and stays.

alter table public.chat_messages drop constraint chat_messages_kind_check;
alter table public.chat_messages drop constraint chat_messages_app_share_check;
alter table public.chat_messages rename column app_slug to mini_slug;

update public.chat_messages set kind = 'mini_share' where kind = 'app_share';

alter table public.chat_messages
    add constraint chat_messages_kind_check
        check (kind in ('text', 'auto_reply', 'ask_human', 'syla_status',
                        'mini_share')),
    add constraint chat_messages_mini_share_check
        check ((kind = 'mini_share') = (mini_slug is not null));

comment on column public.chat_messages.kind is
    'text: an ordinary message. auto_reply: sent by my Syla on my behalf under an active reply rule — always attributed; peers render it "signed as Syla". ask_human: the travelling ask-for-the-human flag — a receiving client marks its chat waiting_on_human. syla_status: Syla''s own status/receipt lines inside the Syla chat. mini_share: this side shared a mini — mini_slug names it here; the receiving client renders the card and one accept copies the bundle home and grants back the silo its manifest names.';
comment on column public.chat_messages.mini_slug is
    'For kind mini_share only: the shared mini''s slug in THIS database. The receiver reads the mini row, its sylos-manifest.json and (on accept) the bundle over their follower key — the sender''s client named them on the mini (mini_followers) at share time — then rebuilds it locally; minis are never served between databases.';

-- ─── The docs speak minis ────────────────────────────────────────────────
--
-- The skill doc takes the new path and title, then one sweep swaps the
-- identifiers and the old phrase in every doc that carries them — a
-- guarded replace, docs-are-data style, so an owner's own edits ride
-- through untouched where the old words don't appear.

update public.docs
set path = 'skills/minis', title = 'Building a mini'
where path = 'skills/vibe-apps';

update public.docs
set html =
    replace(replace(replace(replace(replace(replace(replace(replace(replace(
    replace(replace(replace(replace(replace(replace(replace(replace(replace(
    replace(replace(
        html,
        'save_vibe_code_app_files', 'save_mini_files'),
        'save_vibe_code_app', 'save_mini'),
        'set_vibe_code_app_open', 'set_mini_open'),
        'delete_vibe_code_app', 'delete_mini'),
        'vibe_code_app_followers', 'mini_followers'),
        'vibe_code_app_silos', 'mini_silos'),
        'vibe_code_app_files', 'mini_files'),
        'vibe_code_apps', 'minis'),
        'vibe_code_app', 'mini'),
        'scripts/vibe-save', 'scripts/mini-save'),
        'vibe-save', 'mini-save'),
        'skills/vibe-apps', 'skills/minis'),
        'app_share', 'mini_share'),
        'app_slug', 'mini_slug'),
        'Vibe code apps', 'Minis'),
        'vibe code apps', 'minis'),
        'Vibe code app', 'Mini'),
        'vibe code app', 'mini'),
        'vibe apps', 'minis'),
        'vibe app', 'mini')
where html like '%vibe%'
   or html like '%app_share%'
   or html like '%app_slug%';

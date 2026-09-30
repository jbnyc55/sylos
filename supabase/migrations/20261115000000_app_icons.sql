-- The home screen: every app wears an icon.
--
-- The client's front page is now a HOME SCREEN — a grid of the apps a
-- person can open, icon over name, the way a phone's home screen
-- works (the client repos carry the UI; notes/10-apps-and-chat.md the
-- story). The uniform app format grows its third piece: the CODE (the
-- html bundle and its source rows, 20261008000000), the MANIFEST
-- (sylos-manifest.json, 20261030000000), and now an ICON. The icon is
-- a column on the row, not a file in the tree, because the home screen
-- lists apps without fetching bundles — the list query stays one cheap
-- select of short columns.
--
-- The format is deliberately narrow: an emoji (a grapheme or two), or
-- one inline <svg> element for a drawn icon. Shells render an svg icon
-- inside an <img src="data:image/svg+xml,…"> — an image context, where
-- scripts do not run — and anything else as plain text, so the column
-- stays display-only however hostile its content. Empty is fine: the
-- shell derives a tinted glyph square from the app's name.

alter table public.vibe_code_apps
    add column icon text not null default ''
        check (char_length(icon) <= 20000);

comment on column public.vibe_code_apps.icon is
    'The home-screen icon: an emoji, or one inline <svg> element. Shells render svg as an <img> data URI (an image, never a script context) and anything else as text; empty means a tinted glyph square derived from the name.';

-- Members and followers read the icon with the rest of the row: the
-- member grant on vibe_code_apps is table-wide (20261008000000), so
-- the new column travels wherever the select policies already say yes.

-- ── The deploy RPC learns the icon ───────────────────────────────────────
--
-- Same function, one more argument. _icon defaults to null = KEEP the
-- icon already on the row (so every existing vibe-save call, and any
-- redeploy that doesn't think about icons, leaves them alone); pass ''
-- to clear one deliberately.

drop function public.save_vibe_code_app(text, text, text, text);

create function public.save_vibe_code_app(
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

    _existed := exists (select 1 from public.vibe_code_apps where slug = _slug);

    insert into public.vibe_code_apps (slug, name, hint, html, icon)
    values (_slug, _name, coalesce(_hint, ''), _html, coalesce(_icon, ''))
    on conflict (slug) do update
        set name = excluded.name,
            hint = excluded.hint,
            html = excluded.html,
            icon = coalesce(_icon, vibe_code_apps.icon)
    returning id into _id;

    return jsonb_build_object(
        'app_id', _id,
        'slug',   _slug,
        'op',     case when _existed then 'updated' else 'created' end
    );
end;
$$;

comment on function public.save_vibe_code_app(text, text, text, text, text) is
    'Creates or replaces one vibe code app by slug, as the claude role. _icon null keeps the stored icon, '''' clears it. Gated by assert_claude_rq_key().';

revoke all on function public.save_vibe_code_app(text, text, text, text, text) from public;
grant execute on function public.save_vibe_code_app(text, text, text, text, text) to anon;

-- ── skills/vibe-apps learns the icon ─────────────────────────────────────
--
-- A targeted edit, docs-are-data style: the icon section slides in
-- ahead of the runtime contract. A database whose owner rewrote or
-- deleted the doc is left alone (replace finds no anchor, or the
-- update matches no row), and the edit lands in row_edits like any.

update public.docs
set html = replace(
    html,
    '<h2>The runtime contract</h2>',
    $doc$<h2>The icon</h2>
<p>Every app carries a home-screen icon in the <code>icon</code> column: an emoji, or one inline <code>&lt;svg&gt;</code> element (shells render svg as an image, never as markup — keep it self-contained, no external references). Deploy it with <code>scripts/vibe-save … --icon '…'</code> (or <code>--icon-file icon.svg</code>); omitting the flag keeps the stored icon, so redeploys don't strip it. An app with no icon shows as a tinted square wearing its name's first letter.</p>
<h2>The runtime contract</h2>$doc$
)
where path = 'skills/vibe-apps'
  and position('<h2>The icon</h2>' in html) = 0;

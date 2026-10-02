-- The Notes row returns, exactly as seeded.
--
-- 20261204000000 retired it on the theory that the Drop tab had taken
-- its job; the owner wants the Notes app back. Migrations are
-- append-only, so the retirement stays in history and this re-seeds
-- the same row (20261117000000's values, verbatim). on conflict do
-- nothing: an install where the delete never ran, or where a real
-- build already answers to the slug, keeps what it has.

insert into public.vibe_code_apps (slug, name, hint, sort_rank, icon, html)
values
    ('notes', 'Notes', 'quick lines, kept raw', 20, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#F8EDD1"/><g transform="translate(19 19) scale(1.083)" fill="none" stroke="#8A6A1C" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20l4-1L20 7l-3-3L5 16z"/><path d="M14 6l3 3"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Notes</title>
<p>Notes — quick lines, kept raw.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>')
on conflict do nothing;

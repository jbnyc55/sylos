-- The Files app: any file, held onto — and on record for Syla.
--
-- A place to put a file so it is simply KEPT: the web app's Files page
-- lists public.uploads — the same content-addressed store note
-- attachments live in (one row per owner per SHA-256, objects in the
-- private "uploads" bucket at <profile_id>/<hash>.<ext>) — and lets
-- the owner upload any type straight into it, rename the display
-- name, and delete. Nothing new to store: the store already existed,
-- this gives it a front door of its own, and every file lands where
-- Syla's reads already reach (the claude role reads uploads metadata
-- like every application table; the bytes stay in the owner's private
-- bucket).
--
-- Two pieces:
--   1. the owner may UPDATE their upload rows — the rename was the
--      one verb the original policies left out (display name only;
--      hash, path and bytes describe the immutable object);
--   2. the Files app's row, seeded like the rest of the shell's
--      basic apps (stock_app_rows): optional, renameable, deletable —
--      delete it and the tile is gone, the files themselves stay.

create policy "Uploads are updatable by their owner"
    on public.uploads for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

insert into public.vibe_code_apps (slug, name, hint, sort_rank, icon, html)
values
    ('files', 'Files', 'any file, held onto — and on record for Syla', 35, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#DCE8E4"/><g transform="translate(19 19) scale(1.083)" fill="none" stroke="#3F6B5E" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7h6l2 2h10v10H3z"/><path d="M12 16.5v-5M9.5 13.5L12 11l2.5 2.5"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Files</title>
<p>Files — any file, held onto — and on record for Syla.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>')
on conflict (slug) do nothing;

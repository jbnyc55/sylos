-- Stock app rows: the shell's basic apps become rows the owner keeps.
--
-- The home screen is just apps, and apps travel between people by
-- copying rows — so the shell's own parts stop being fixtures. The
-- CORE is the home screen itself and the Apps app (the manager and the
-- door: rendered from the bundle, never rows, never deletable).
-- Everything else — Chat, Notes, Docs, Todos, Goals, Calendar, Syla
-- Jobs, Silos, Followers, Inbox — is an ordinary vibe_code_apps row in
-- the owner's OWN database: optional, renameable, shareable through
-- silos and members, deletable (delete removes the app from the lists;
-- the data it read stays in its silos), and replaceable by a build of
-- Syla's. This migration seeds those rows once, with the tile icons
-- the bundle draws and a stub document naming the shell as the
-- renderer. Seeding by migration rather than from the client is what
-- makes deletion stick: migrations run once, so a deleted row stays
-- deleted.
--
-- Also here: every vibe app's content fingerprint. html_sha256 is a
-- GENERATED column — the database computes it from html itself, so it
-- can never drift from the content — and it answers "is this shared
-- copy the same build as mine?" without fetching megabytes of html.
-- It is a divergence detector, not a tamper-proof: anyone who may
-- rewrite html gets the matching hash for free. Provenance beyond
-- that would need signing, which is not this column's job.

alter table public.vibe_code_apps
    add column if not exists html_sha256 text
    generated always as (encode(extensions.digest(html, 'sha256'), 'hex')) stored;

comment on column public.vibe_code_apps.html_sha256 is
    'The bundle''s content fingerprint, computed by the database from html. Two rows with equal hashes hold the identical build; a shared copy whose hash differs from yours has been changed. Divergence detection only — it proves nothing about who changed what.';

-- The shell's apps, seeded once. on conflict do nothing: a row the
-- owner already holds (an earlier client-side registration, or Syla's
-- real deployed build) is theirs, not ours to touch — and a row the
-- owner deleted after this migration ran never comes back.
insert into public.vibe_code_apps (slug, name, hint, sort_rank, icon, html)
values
    ('mash', 'Chat', 'chats, and the vibes you code into them', 10, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#5646D4"/><g transform="translate(18 18) scale(1.167)" fill="#FFFFFF"><path d="M21 11.5a8.5 8.5 0 0 1-8.5 8.5H4l1.9-3.1A8.5 8.5 0 1 1 21 11.5z"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Chat</title>
<p>Chat — chats, and the vibes you code into them.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>'),
    ('notes', 'Notes', 'quick lines, kept raw', 20, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#F8EDD1"/><g transform="translate(19 19) scale(1.083)" fill="none" stroke="#8A6A1C" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20l4-1L20 7l-3-3L5 16z"/><path d="M14 6l3 3"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Notes</title>
<p>Notes — quick lines, kept raw.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>'),
    ('docs', 'Docs', 'living pages you and Syla edit', 30, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#E9E3FB"/><g transform="translate(19 19) scale(1.083)" fill="none" stroke="#5646D4" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h9l4 4v14H6z"/><path d="M15 3v5h4"/><path d="M9 13h6M9 17h6"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Docs</title>
<p>Docs — living pages you and Syla edit.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>'),
    ('todos', 'Todos', 'today, and every day around it', 40, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#E3EEDD"/><g transform="translate(19 19) scale(1.083)" fill="none" stroke="#4A7040" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="5"/><path d="M8.5 12.5l2.5 2.5 5-5.5"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Todos</title>
<p>Todos — today, and every day around it.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>'),
    ('goals', 'Goals', 'the map of what you are building', 50, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#E9E3FB"/><g transform="translate(19 19) scale(1.083)"><path d="M12 5v6M12 11L4 19M12 11l8 8" fill="none" stroke="#5646D4" stroke-width="2.2" stroke-linecap="round"/><circle cx="12" cy="4" r="3.4" fill="#5646D4"/><circle cx="3.5" cy="20" r="2.8" fill="#FFFFFF" stroke="#5646D4" stroke-width="2"/><circle cx="20.5" cy="20" r="2.8" fill="#FFFFFF" stroke="#D95B43" stroke-width="2"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Goals</title>
<p>Goals — the map of what you are building.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>'),
    ('calendar', 'Calendar', 'events, and the todos inside them', 60, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#FBE3D6"/><g transform="translate(19 19) scale(1.083)" fill="none" stroke="#B94A2C" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="5" width="16" height="15" rx="3"/><path d="M4 10h16M9 3v4M15 3v4"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Calendar</title>
<p>Calendar — events, and the todos inside them.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>'),
    ('syla-jobs', 'Syla Jobs', 'her calendar — the events she performs, and how they ran', 70, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#5646D4"/><g transform="translate(19 19) scale(1.083)" fill="none" stroke="#FFFFFF" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="5" width="16" height="15" rx="3"/><path d="M4 10h16M9 3v4M15 3v4"/><path d="M10.5 14.5h.01M13.5 14.5h.01"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Syla Jobs</title>
<p>Syla Jobs — her calendar — the events she performs, and how they ran.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>'),
    ('silos', 'Silos', 'who reads what, and the undo log', 80, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#262033"/><g transform="translate(19 19) scale(1.083)" fill="none" stroke="#F7F4EE" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="6" rx="7" ry="3"/><path d="M5 6v12c0 1.7 3.1 3 7 3s7-1.3 7-3V6"/><path d="M5 12c0 1.7 3.1 3 7 3s7-1.3 7-3"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Silos</title>
<p>Silos — who reads what, and the undo log.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>'),
    ('follows', 'Followers', 'who reads your silos, and whose you read', 90, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#F7E1EC"/><g transform="translate(19 19) scale(1.083)" fill="none" stroke="#B02E68" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="8" r="3.6"/><path d="M3 20c0-3.3 2.7-6 6-6s6 2.7 6 6"/><circle cx="17.5" cy="9" r="2.8"/><path d="M16 14.4c.5-.2 1-.3 1.5-.3 2.5 0 4.5 2.1 4.5 4.7"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Followers</title>
<p>Followers — who reads your silos, and whose you read.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>'),
    ('inbox', 'Inbox', 'what waits on you — her proposals and questions', 100, '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="20" fill="#FFFFFF"/><g transform="translate(19 19) scale(1.083)" fill="none" stroke="#D95B43" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11L2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/></g></svg>', '<!doctype html>
<meta charset="utf-8">
<title>Inbox</title>
<p>Inbox — what waits on you — her proposals and questions.</p>
<p>This app is rendered by the Sylos shell; this row is its record in your database. Its silos and members decide who it reaches, and Syla can replace this document with a build of her own.</p>')
on conflict (slug) do nothing;

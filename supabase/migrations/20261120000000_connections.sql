-- Connections: one relationship, presented whole; the data stays directional.
--
-- The product now says "connected" where it used to say follower/following:
-- every relationship presents as bidirectional, even though the data layer
-- keeps its two directions (my `followers` row for a person — their key into
-- my database — and my `following` row for theirs — my key into their
-- database). Nothing about the machinery changes; what is new is the LINK
-- between the two directions, and the reply ladder each connection carries:
--
--   * peer_following_id ties my roster row for a person to my following row
--     for their database. Both halves set is what the client presents as
--     CONNECTED; the lifecycle before that is read off the columns that
--     already exist — invited (invite_code_hash set, claimed_at null),
--     wants-to-connect (claimed_at set, peer_following_id null). The state
--     before all of these — in my contacts, not yet invited — lives only on
--     the phone; contacts never land in any database.
--   * syla_reply_mode is the reply ladder for THIS person: how my Syla may
--     answer them. 'propose' (drafts only, I approve every send), 'auto'
--     (she may send where an active reply rule covers it), 'syla_syla'
--     (auto, plus the two agents may talk; needs the other side too).
--   * syla_syla_peer_ok records that their side has allowed Syla × Syla as
--     well — learned from an attributed message in the chat, never from
--     reading their database. Strict one-sided visibility holds: everything
--     on this row is MY side of the relationship (my rules, my sharing);
--     their copy of the same relationship lives in their database.
--
-- The reply rules themselves (the per-person preflight the modes gate on)
-- are the next migration, 20261122000000_reply_rules.sql. Visibility of
-- these columns is unchanged: followers rows are the owner's (and each
-- follower reads only their own row, which now shows them nothing new worth
-- hiding — the mode and link are the owner's own settings); claude keeps
-- read-only, the write path being the owner's session and, for rule
-- suggestions, the gated RPCs of 20261122.

alter table public.followers
    add column peer_following_id uuid
        references public.following (id) on delete set null,
    add column syla_reply_mode text not null default 'propose'
        check (syla_reply_mode in ('propose', 'auto', 'syla_syla')),
    add column syla_syla_peer_ok boolean not null default false;

comment on column public.followers.peer_following_id is
    'The owner''s following row for this person''s own database, when they have one. Both directions held — claimed_at set here, and this link set — is what the client presents as CONNECTED; the data layer stays directional.';
comment on column public.followers.syla_reply_mode is
    'The reply ladder for this connection: how the owner''s Syla may answer this person. propose = drafts only, the owner approves every send; auto = Syla may send where an active reply rule covers it (always attributed); syla_syla = auto, plus the two agents may talk — needs syla_syla_peer_ok too.';
comment on column public.followers.syla_syla_peer_ok is
    'Their side has allowed Syla × Syla as well, learned from an attributed message in the chat. Both this and syla_reply_mode = syla_syla are needed before agents talk; either side flipping back stops it.';

create index followers_peer_following_id_idx
    on public.followers (peer_following_id);

-- The owner edits the ladder and the link from the app; everything else on
-- the row keeps its existing column-scoped grants. (Grants are the outer
-- gate — the owner policies on followers already govern row access.)
grant update (peer_following_id, syla_reply_mode, syla_syla_peer_ok)
    on public.followers to authenticated;

-- ── The home screen says Connections ─────────────────────────────────────
--
-- The stock app row seeded as 'Followers' (20261117000000) presents the
-- whole lifecycle now, so it wears the product's word. Matched on the
-- seeded name so an owner's own rename is never clobbered; the slug (and
-- any default_app preference pointing at it) stays `follows`.

update public.vibe_code_apps
set name = 'Connections',
    hint = 'everyone you''re connected to — invites, rules, and what each side shares'
where slug = 'follows' and name = 'Followers';

-- ── The sharing skill learns the word too ────────────────────────────────
--
-- Docs are data: this lands in row_edits like any edit. Patched only while
-- the seeded footer is intact and the section is absent, so an owner's
-- edits are never overwritten.

update public.docs
set html = replace(html,
    '<footer>doc <code>skills/followers</code></footer>',
    '<h2>Connections and reply modes</h2>'
    || '<p>The app presents each relationship as a <strong>connection</strong>: one person, both directions. The data stays directional — a <code>followers</code> row is their key into this database, a <code>following</code> row is the owner''s key into theirs, and <code>followers.peer_following_id</code> links the two when both exist. Each connection also carries the owner''s reply ladder for that person in <code>followers.syla_reply_mode</code> (<code>propose</code> / <code>auto</code> / <code>syla_syla</code>) — how you may answer them in chat. That is the gate <code>skills/chat-replies</code> works under; you never change the mode, the link, or any other column of <code>followers</code> — those are the owner''s settings.</p>'
    || '<footer>doc <code>skills/followers</code></footer>')
where path = 'skills/followers'
  and html like '%<footer>doc <code>skills/followers</code></footer>%'
  and html not like '%Connections and reply modes%';

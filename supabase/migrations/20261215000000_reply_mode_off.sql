-- The reply ladder: a new bottom rung, one fewer at the top.
--
--   * 'off' joins below 'propose': Syla stays out of the chat entirely —
--     no drafts, no auto-replies, no suggestions, no waiting flags. Some
--     owners want a plain conversation with proposals nowhere in it.
--   * 'syla_syla' retires: in practice it was both sides on auto — the
--     agents already talk wherever each side's rules allow a send, so the
--     separate rung (and its handshake flag) bought nothing. Existing
--     rows step down to 'auto', which changes no behavior: every gate
--     that accepted syla_syla (send_auto_reply, send_group_auto_reply)
--     accepted auto too. syla_syla_peer_ok stays as a dormant column —
--     history is append-only.

update public.followers
set syla_reply_mode = 'auto'
where syla_reply_mode = 'syla_syla';

alter table public.followers
    drop constraint followers_syla_reply_mode_check;
alter table public.followers
    add constraint followers_syla_reply_mode_check
        check (syla_reply_mode in ('off', 'propose', 'auto'));

comment on column public.followers.syla_reply_mode is
    'The reply ladder for this connection: how the owner''s Syla may answer this person. off = Syla stays out of the chat entirely (no drafts, no replies, no suggestions); propose = drafts only, the owner approves every send; auto = Syla may send where an active reply rule covers it (always attributed).';
comment on column public.followers.syla_syla_peer_ok is
    'Dormant since 20261215000000: the syla_syla rung retired (both sides on auto is the same thing). Kept because history is append-only.';

-- ── The docs learn the new ladder ────────────────────────────────────────
--
-- Targeted text swaps on the seeded pages (20261205000000's pattern), so
-- an owner's own edits elsewhere survive; an already-edited sentence
-- just no-ops.

update public.docs
set html = replace(html,
    '<code>propose</code> — you draft, the owner sends; <code>auto</code> — you may send where an <em>active reply rule</em> covers it; <code>syla_syla</code> — auto, plus the two agents may talk (only when <code>syla_syla_peer_ok</code> is true as well). You never change the mode.',
    '<code>off</code> — you stay out of the chat entirely: no drafts, no auto-replies, no suggestions, no waiting flags; <code>propose</code> — you draft, the owner sends; <code>auto</code> — you may send where an <em>active reply rule</em> covers it. You never change the mode.')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    '<h2>Drafting (every mode)</h2>',
    '<h2>Drafting (propose and auto — never off)</h2>')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    'Only in mode <code>auto</code> or <code>syla_syla</code>, and only through',
    'Only in mode <code>auto</code>, and only through')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    'exactly as above: a draft in propose mode,',
    'exactly as above: nothing at all in off mode, a draft in propose mode,')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    ' — in syla_syla this is what keeps the two agents'' turn-taking going.</p>',
    ' — with both sides on auto this is what keeps the two agents'' turn-taking going.</p>')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    '(<code>propose</code> / <code>auto</code> / <code>syla_syla</code>)',
    '(<code>off</code> / <code>propose</code> / <code>auto</code>)')
where path = 'skills/followers';

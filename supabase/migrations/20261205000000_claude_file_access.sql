-- Syla can look at files: the claude-file gate.
--
-- Media drops are objects in the PRIVATE uploads bucket; Syla's rq path
-- is SQL, which carries metadata, never bytes — so a photo in the chute
-- could only become a question ("I can't see what's in this photo").
-- The new claude-file edge function closes the gap: she posts an upload
-- id with her rq key and gets a short-lived signed URL to download the
-- file and actually look at it. This migration is the function's SQL
-- half, the gate-and-lookup in one call, following-relay's pattern
-- (following_relay_target): SECURITY DEFINER to read the vault,
-- executable by service_role ONLY (the edge function's client), raising
-- the same way on a wrong key and an unknown id.
--
-- The docs catch up too: the chute-sort procedure now says to LOOK at a
-- photo or file before filing it (scripts/file-url), and that voice
-- drops carry their transcript in body — the phone transcribes at
-- capture, on device, so the words arrive with the drop.

create function public.claude_file_target(_key text, _upload_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    expected text;
    _row     record;
begin
    select decrypted_secret into expected
    from vault.decrypted_secrets
    where name = 'claude_rq_key';

    if expected is null or expected = '' then
        raise exception 'claude_rq_key is not configured in Vault; agent access is disabled'
            using errcode = '28000';
    end if;
    if _key is null or _key = '' or _key is distinct from expected then
        raise exception 'missing or invalid key' using errcode = '28000';
    end if;

    select path, mime, bytes into _row
    from public.uploads where id = _upload_id;
    if _row is null then
        raise exception 'missing or invalid key' using errcode = '28000';
    end if;

    return jsonb_build_object('path', _row.path, 'mime', _row.mime, 'bytes', _row.bytes);
end;
$$;

comment on function public.claude_file_target(text, uuid) is
    'The claude-file edge function''s gate and lookup in one: verifies the rq key against Vault secret claude_rq_key and answers the uploads row''s bucket path, mime and size — to service_role only, so the signed URL is minted server-side and the bucket stays private. A wrong key and an unknown id raise identically.';

revoke all on function public.claude_file_target(text, uuid) from public;
revoke all on function public.claude_file_target(text, uuid) from anon;
revoke all on function public.claude_file_target(text, uuid) from authenticated;
grant execute on function public.claude_file_target(text, uuid) to service_role;

-- ── The chute docs: look before filing; transcripts ride the drop ────────
--
-- Targeted text swaps on the seeded docs, so an owner's own edits
-- elsewhere in the page survive; a rewritten sentence just no-ops.

update public.docs
set html = replace(html,
    'a photo/file/voice drop already lives in <code>uploads</code> — filing can mean just naming where it belongs.',
    'a photo or file drop: LOOK at it first — <code>scripts/file-url &lt;upload_id&gt;</code> answers a short-lived signed link to the private bucket; download it, read the content, and file it where it truly belongs. A voice drop carries its transcript in <code>body</code> (the phone transcribes at capture, on device) — file it like text; only an older drop with no transcript still needs a question.')
where path = 'syla/chute-sort';

update public.docs
set html = replace(html,
    '<footer>doc <code>skills/chute</code></footer>',
    '<h2>Seeing media</h2>
<p>A media drop''s bytes live in the private <code>uploads</code> bucket, which SQL cannot reach. <code>scripts/file-url &lt;upload_id&gt;</code> posts to the claude-file edge function with your rq key and answers <code>{url, mime, bytes}</code> — a signed link that expires in minutes. Download and look before filing a photo or document. Voice memos need no fetching: the phone transcribes them at capture and the words arrive in the drop''s <code>body</code>.</p>
<footer>doc <code>skills/chute</code></footer>')
where path = 'skills/chute';

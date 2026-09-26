-- push-relay setup — run ONCE on the DEVELOPER project (the one hosting
-- supabase-oauth), never on a user's, and never with real values checked
-- into this file: the credentials go straight into that project's Vault.
-- This is NOT a migration — supabase/migrations/ deploys to every user
-- project, which must never see the APNs key.
--
-- Alternative: set APNS_TEAM_ID / APNS_KEY_ID / APNS_PRIVATE_KEY as Edge
-- Function secrets on the developer project instead; env wins over Vault.

-- The credentials (replace the placeholders):
select vault.create_secret('<TEAM_ID>', 'apns_team_id');
select vault.create_secret('<KEY_ID>', 'apns_key_id');
select vault.create_secret('-----BEGIN PRIVATE KEY-----
<contents of the .p8 file>
-----END PRIVATE KEY-----', 'apns_private_key');

-- How the relay reads them: service-role-only, so nothing a client key
-- can reach. The relay's auto-injected service role key authorizes it.
create or replace function public.push_relay_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select jsonb_build_object(
        'team_id',     (select decrypted_secret from vault.decrypted_secrets where name = 'apns_team_id'),
        'key_id',      (select decrypted_secret from vault.decrypted_secrets where name = 'apns_key_id'),
        'private_key', (select decrypted_secret from vault.decrypted_secrets where name = 'apns_private_key'),
        'topic',       (select decrypted_secret from vault.decrypted_secrets where name = 'apns_topic')
    )
$$;

revoke all on function public.push_relay_config() from public;
grant execute on function public.push_relay_config() to service_role;

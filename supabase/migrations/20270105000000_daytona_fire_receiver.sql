-- The fire webhook may point at this project's own syla-fire function.
--
-- set_syla_webhook() has always pinned the stored URL to Anthropic's
-- routine fire endpoint, so a leaked rq key could rotate or break the
-- webhook but never redirect the bearer token to a host that would
-- capture it. The Daytona worker path (daytona/README.md) needs the
-- webhook to target the owner's own syla-fire edge function instead —
-- so the pin gains exactly one more allowed shape: THIS project's
-- functions URL, and no other host.
--
-- "This project" is read from the request itself: the setter is only
-- ever called through PostgREST (scripts/syla-set-webhook), where the
-- Host header is the project's own domain. Comparing against it keeps
-- the original property — an attacker with the rq key still cannot
-- point the token anywhere that isn't Anthropic or the very project
-- the key already belongs to.

create or replace function public.set_syla_webhook(_url text, _token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _name text;
    _value text;
    _existing uuid;
    _host text;
begin
    perform public.assert_claude_rq_key();

    if _url is null or _token is null then
        raise exception 'url and token are both required';
    end if;

    _host := coalesce(nullif(current_setting('request.headers', true), ''),
                      '{}')::jsonb ->> 'host';

    if _url !~ '^https://api\.anthropic\.com/v1/claude_code/routines/[A-Za-z0-9_]+/fire$'
       and (_host is null
            or _url <> 'https://' || _host || '/functions/v1/syla-fire') then
        raise exception 'url must be an Anthropic routine fire endpoint or this project''s own syla-fire function';
    end if;

    for _name, _value in
        select * from (values ('syla_webhook_url', _url),
                              ('syla_webhook_token', _token)) as s (n, v)
    loop
        select id into _existing from vault.secrets where name = _name;
        if _existing is null then
            perform vault.create_secret(_value, _name);
        else
            perform vault.update_secret(_existing, _value);
        end if;
    end loop;

    return jsonb_build_object('ok', true);
end;
$$;

comment on function public.set_syla_webhook(text, text) is
    'Stores the Syla fire URL and bearer token as Vault secrets syla_webhook_url / syla_webhook_token. Gated by assert_claude_rq_key(); the URL is pinned to api.anthropic.com or this project''s own syla-fire function, so the token cannot be redirected to a capturing host.';

revoke all on function public.set_syla_webhook(text, text) from public;
grant execute on function public.set_syla_webhook(text, text) to anon;

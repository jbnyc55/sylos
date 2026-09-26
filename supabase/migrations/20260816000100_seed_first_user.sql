-- Seeds the first user — the app's owner. OPTIONAL since 20260930000000:
-- leave this file untouched and it no-ops (the placeholder email guard
-- below), and the first account created in the app becomes the owner
-- instead. Customize it only if you specifically want a pre-created,
-- pre-confirmed account — then change v_email to your email address and
-- pick a fresh temporary password on the crypt() line before the first
-- merge to main.
--
-- ⚠️  This migration contains a plaintext password, which is now in git history
--     permanently and readable by anyone with repository access. Change the
--     password from the Supabase dashboard (Authentication → Users) after the
--     first successful login, and treat the value below as burned. Creating the
--     user from the dashboard instead would avoid this entirely.
--
-- ⚠️  Writing to auth.users couples this migration to GoTrue's internal schema,
--     which Supabase can change without notice. If a future Supabase upgrade
--     makes this migration fail, delete it rather than repairing it — by then
--     the user already exists and the migration has served its purpose.
--
-- The profile is NOT created here. The on_auth_user_created trigger from the
-- previous migration fires on this insert and creates it, which also serves as
-- a live test that automatic profile creation works.

do $$
declare
    v_user_id uuid := gen_random_uuid();
    v_email   text := 'owner@example.com';  -- optional: your email (see header)
begin
    if v_email = 'owner@example.com' then
        raise notice 'Placeholder email unchanged — skipping seed. The first account created in the app becomes the owner (20260930000000_first_signup_owner).';
        return;
    end if;

    if exists (select 1 from auth.users where email = v_email) then
        raise notice 'User % already exists, skipping seed', v_email;
        return;
    end if;

    insert into auth.users (
        instance_id,
        id,
        aud,
        role,
        email,
        encrypted_password,
        email_confirmed_at,
        created_at,
        updated_at,
        raw_app_meta_data,
        raw_user_meta_data,
        confirmation_token,
        recovery_token,
        email_change_token_new,
        email_change
    ) values (
        '00000000-0000-0000-0000-000000000000',
        v_user_id,
        'authenticated',
        'authenticated',
        v_email,
        extensions.crypt('change-me-after-first-login', extensions.gen_salt('bf')),  -- ⚠️ pick your own
        now(),                        -- pre-confirmed, so no verification email
        now(),
        now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        '{}'::jsonb,
        '', '', '', ''                -- GoTrue expects empty strings, not nulls
    );

    -- Email/password sign-in resolves through auth.identities; without this row
    -- the user exists but cannot log in.
    insert into auth.identities (
        id,
        user_id,
        provider_id,
        identity_data,
        provider,
        last_sign_in_at,
        created_at,
        updated_at
    ) values (
        gen_random_uuid(),
        v_user_id,
        v_user_id::text,
        jsonb_build_object(
            'sub', v_user_id::text,
            'email', v_email,
            'email_verified', true,
            'phone_verified', false
        ),
        'email',
        now(),
        now(),
        now()
    );

    raise notice 'Seeded user % with profile via trigger', v_email;
end
$$;

-- Contacts: the phone's address book, mirrored into rows.
--
-- CNContactStore lives on the device, so the app is the sync engine: with
-- Contacts access granted it uploads the whole book through
-- record_contacts (a phone_devices key with scope 'contacts'), wholesale —
-- the mirror is replaced each sync, so deletions and edits on the phone
-- fall out for free, exactly like gcal_event. Syncs run when iOS posts a
-- contacts-changed notification and on stale foregrounds, not on a clock.
--
-- What this buys: Syla can resolve "dinner with Sam" to a person, see
-- whose birthday is coming, and address people by how the owner actually
-- writes them — without the app in the loop. Read-only: nothing here ever
-- writes back to the address book.
--
-- Who sees what, same sentence as user_locations: each person reads their
-- own mirror, the owner reads everyone's, claude reads everything. Notes
-- and photos are deliberately NOT mirrored — contact notes need a special
-- Apple entitlement and neither earns its weight in rows.

create table public.device_contacts (
    id               uuid primary key default gen_random_uuid(),
    profile_id       uuid not null references public.profiles (id) on delete cascade,
    device_id        uuid references public.phone_devices (id) on delete set null,
    -- CNContact.identifier — stable per contact per device.
    contact_id       text not null check (char_length(contact_id) <= 300),
    given_name       text not null default '' check (char_length(given_name) <= 300),
    family_name      text not null default '' check (char_length(family_name) <= 300),
    nickname         text not null default '' check (char_length(nickname) <= 300),
    organization     text not null default '' check (char_length(organization) <= 300),
    job_title        text not null default '' check (char_length(job_title) <= 300),
    -- Labeled values, as arrays of {label, value}: a contact has however
    -- many phones/emails/addresses it has, and nothing aggregates them.
    phones           jsonb not null default '[]'::jsonb check (jsonb_typeof(phones) = 'array'),
    emails           jsonb not null default '[]'::jsonb check (jsonb_typeof(emails) = 'array'),
    postal_addresses jsonb not null default '[]'::jsonb check (jsonb_typeof(postal_addresses) = 'array'),
    -- Split, because iOS birthdays may omit the year.
    birthday_year    integer check (birthday_year between 1 and 9999),
    birthday_month   integer check (birthday_month between 1 and 12),
    birthday_day     integer check (birthday_day between 1 and 31),
    synced_at        timestamptz not null default now(),

    unique (profile_id, contact_id)
);

comment on table public.device_contacts is
    'Read-only mirror of the phone''s address book, replaced wholesale by record_contacts each sync (a phone_devices key with scope contacts). Each person reads their own, the owner everyone''s; nothing writes back to the phone.';

create index device_contacts_profile_id_idx on public.device_contacts (profile_id);

alter table public.device_contacts enable row level security;

create policy "Contacts are viewable by their profile or the owner"
    on public.device_contacts for select to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());
create policy "Contacts are deletable by their profile or the owner"
    on public.device_contacts for delete to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());

create policy "claude reads contacts"
    on public.device_contacts for select to claude using (true);

-- record_contacts is the only write path; delete stays so the owner can
-- clear a mirror any time (the log is the undo).
grant select, delete on public.device_contacts to authenticated;
grant select on public.device_contacts to claude;

-- ---------------------------------------------------------------------------
-- record_contacts — the phone's upload, as anon with the device key
-- ---------------------------------------------------------------------------
--
-- _contacts is a JSON array of {contact_id, given_name, family_name,
-- nickname, organization, job_title, phones, emails, postal_addresses,
-- birthday_year, birthday_month, birthday_day}. Wholesale replace: the
-- call carries the entire book, so it must never be used for a partial
-- batch. Rows without a contact_id are dropped rather than failing the
-- batch — a phone must never retry one bad row forever.

create function public.record_contacts(_token text, _contacts jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _device   record;
    _given    integer;
    _inserted integer;
begin
    select * into _device from public.phone_device_for(_token, 'contacts');

    if _contacts is null or jsonb_typeof(_contacts) <> 'array' then
        raise exception 'contacts must be a JSON array';
    end if;
    _given := jsonb_array_length(_contacts);
    if _given > 10000 then
        raise exception 'at most 10000 contacts per call (got %)', _given;
    end if;

    set local statement_timeout = '60s';

    delete from public.device_contacts where profile_id = _device.profile_id;

    insert into public.device_contacts (
        profile_id, device_id, contact_id, given_name, family_name, nickname,
        organization, job_title, phones, emails, postal_addresses,
        birthday_year, birthday_month, birthday_day)
    select _device.profile_id, _device.device_id,
           left(c.contact_id, 300),
           left(coalesce(c.given_name, ''), 300),
           left(coalesce(c.family_name, ''), 300),
           left(coalesce(c.nickname, ''), 300),
           left(coalesce(c.organization, ''), 300),
           left(coalesce(c.job_title, ''), 300),
           case when jsonb_typeof(c.phones) = 'array' then c.phones else '[]'::jsonb end,
           case when jsonb_typeof(c.emails) = 'array' then c.emails else '[]'::jsonb end,
           case when jsonb_typeof(c.postal_addresses) = 'array' then c.postal_addresses else '[]'::jsonb end,
           case when c.birthday_year between 1 and 9999 then c.birthday_year end,
           case when c.birthday_month between 1 and 12 then c.birthday_month end,
           case when c.birthday_day between 1 and 31 then c.birthday_day end
    from jsonb_to_recordset(_contacts) as c (
        contact_id text, given_name text, family_name text, nickname text,
        organization text, job_title text, phones jsonb, emails jsonb,
        postal_addresses jsonb,
        birthday_year integer, birthday_month integer, birthday_day integer)
    where c.contact_id is not null and c.contact_id <> ''
    on conflict (profile_id, contact_id) do nothing;

    get diagnostics _inserted = row_count;

    return jsonb_build_object('inserted', _inserted, 'received', _given);
end;
$$;

comment on function public.record_contacts(text, jsonb) is
    'Replaces the device key''s profile''s contacts mirror with this batch — the whole address book each call, so phone-side deletions fall out. Raises 28000 for an unknown or wrong-scope key.';

revoke all on function public.record_contacts(text, jsonb) from public;
grant execute on function public.record_contacts(text, jsonb) to anon, authenticated;

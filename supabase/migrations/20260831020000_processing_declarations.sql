-- Guest requests must declare where the results will be processed.
--
-- Reading data is never just reading: the requester's client processes it
-- somewhere — on their own device, or shipped to a cloud service (an LLM, an
-- analytics pipeline). Those are different acts of trust, so the request now
-- carries the claim and the tag carries the owner's answer: each note type
-- lists the processing locations it admits, and a guest request must declare
-- exactly one location, which the RLS policy checks against every tag it
-- reads through. "Family can read my workouts, but only locally" is now a
-- database-enforced sentence.
--
-- Honest limits, by design: the database cannot verify where bytes actually
-- go after they leave — the declaration is consent machinery, not physics.
-- What it does guarantee: no data flows without a declaration, a location
-- the tag's settings exclude returns nothing rather than data-with-a-wish,
-- and a client that declares 'local' and processes elsewhere is provably in
-- breach of what it asked for.
--
-- Vocabulary is rules, membership is data: which locations exist is a
-- migration (this one knows 'local' and 'cloud'); which a tag admits is a
-- row edit the owner toggles in the app, logged and undoable like any other.

-- ---------------------------------------------------------------------------
-- Tag settings: which processing locations each note type admits
-- ---------------------------------------------------------------------------

alter table public.note_types
    add column allowed_processing text[] not null default array['local'],
    add constraint note_types_known_processing
        check (allowed_processing <@ array['local', 'cloud']);

comment on column public.note_types.allowed_processing is
    'Processing locations a guest request may declare and still read notes through this tag. Defaults to local-only — cloud is an explicit owner opt-in per tag.';

-- The owner flips these from the app (column-scoped, like every app grant).
grant update (allowed_processing) on public.note_types to authenticated;

create policy "Note type settings are updatable by the owner"
    on public.note_types for update
    to authenticated
    using (public.is_owner())
    with check (public.is_owner());

-- Guests may see each tag's settings, so a refusal is explainable: the CLI
-- can show "workouts is local-only" instead of silently returning nothing.
grant select (allowed_processing) on public.note_types to guest;

-- ---------------------------------------------------------------------------
-- The declaration: one location per request, stamped like the guest id
-- ---------------------------------------------------------------------------

create function public.current_guest_processing()
returns text
language sql
stable
as $$
    select nullif(current_setting('app.guest_processing', true), '')
$$;

comment on function public.current_guest_processing() is
    'The processing location guest_rq stamped on this transaction, or null. Guest note policies scope through this; null fails closed.';

-- guest_rq grows a required declaration. The old two-argument form is
-- dropped rather than kept as a lenient overload — an undeclared request is
-- exactly what must stop working (and two overloads would be ambiguous to
-- PostgREST anyway). The parameter has a null default only so the error is
-- ours and says what to do, instead of PostgREST's signature mismatch.
drop function public.guest_rq(text, text);

create function public.guest_rq(_token text, q text, _processing text default null)
returns jsonb
language plpgsql
security invoker
as $$
declare
    gid    uuid;
    result jsonb;
begin
    gid := public.authenticate_guest(_token);

    if _processing is null or _processing not in ('local', 'cloud') then
        raise exception
            'declare where the results will be processed: pass processing = ''local'' (stays on your device) or ''cloud'' (sent to a remote service)'
            using errcode = '28000';
    end if;

    if q is null or btrim(q) = '' then
        raise exception 'empty query';
    end if;
    if btrim(q) like '%;' then
        raise exception 'send one statement without a trailing semicolon';
    end if;

    perform set_config('app.guest_id', gid::text, true);
    perform set_config('app.guest_processing', _processing, true);

    set local statement_timeout = '15s';
    set local role guest;
    set local transaction_read_only = on;

    execute format(
        'select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', q)
    into result;

    return result;
end;
$$;

comment on function public.guest_rq(text, text, text) is
    'Runs one read-only SQL statement as the guest role, scoped by the token''s guest, their groups, and the declared processing location. Returns rows as a JSON array.';

revoke all on function public.guest_rq(text, text, text) from public;
grant execute on function public.guest_rq(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- Enforcement: a tag only connects guest to note for admitted locations
-- ---------------------------------------------------------------------------
--
-- Same policy as 20260830050000, with one more condition on the joining
-- tag: it must admit the declared location. A note reachable through two
-- tags stays readable if either tag admits the declaration — the tag is the
-- grant, so any satisfied grant suffices. With no declaration stamped,
-- current_guest_processing() is null, = any() is never true, and the policy
-- fails closed.

drop policy "Guests read notes tagged for their groups" on public.manual_notes;

create policy "Guests read notes tagged for their groups"
    on public.manual_notes for select
    to guest
    using (exists (
        select 1
        from public.manual_note_types j
        join public.note_types nt on nt.id = j.note_type_id
        join public.guest_group_tags ggt on ggt.note_type_id = j.note_type_id
        join public.guest_group_members m on m.group_id = ggt.group_id
        where j.note_id = manual_notes.id
          and m.guest_id = public.current_guest_id()
          and public.current_guest_processing() = any (nt.allowed_processing)
    ));

-- Deliberately unchanged: the whoami policies (a guest's own row, groups,
-- memberships, tag grants and tag settings) ignore the declaration — a
-- guest may always see what they hold and why a location was refused.

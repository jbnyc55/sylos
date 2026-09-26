-- Let signed-in users add note types from the app.
--
-- note_types began as migration-seeded vocabulary (20260828040000). With a
-- Note types tab in the app, creation moves to the client: insert only. No
-- update or delete from the client — renaming or removing a type changes the
-- meaning of every note linked to it, so that stays a deliberate,
-- by-migration act.

create policy "Note types are insertable by signed-in users"
    on public.note_types for insert
    to authenticated
    with check (true);

grant insert on public.note_types to authenticated;

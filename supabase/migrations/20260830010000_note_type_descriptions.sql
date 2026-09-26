-- Note types get an optional description.
--
-- A one-word name like "wellness" carries less than it seems once the
-- vocabulary grows; a short free-text description lets a type say what
-- belongs in it. Optional, so the seeded types and quick additions stay a
-- bare name. Insertable through the existing client insert policy; like
-- name changes, editing a description later stays a by-migration act.

alter table public.note_types
    add column description text
        check (description is null or char_length(description) between 1 and 200);

comment on column public.note_types.description is
    'Optional short note on what this type is for. Null for types created without one.';

-- Notes carry files now, not only photos.
--
-- The uploads pipeline (20261001000000_note_uploads) was already
-- file-agnostic — content-addressed objects, mime + bytes metadata, a
-- junction per record type — only the bucket's mime allowlist and the
-- app's pickers said "images". Two changes widen it:
--
-- 1. The bucket accepts any content type. That is safe here because the
--    bucket is private with owner-folder policies (nobody else can read
--    or write an object), the 25 MB size cap stands, and nothing ever
--    serves these objects publicly — the only read path is the owner's
--    own signed URL. An allowlist would just be a catalog to keep
--    chasing.
--
-- 2. uploads gains the original filename, display only. Photos stay
--    content-named (a camera roll image has no name worth keeping), but
--    "report.pdf" attached from Files should read as "report.pdf" in the
--    stream, not as a hash.

update storage.buckets set allowed_mime_types = null where id = 'uploads';

alter table public.uploads add column name text
    check (name is null or char_length(name) between 1 and 200);

comment on column public.uploads.name is
    'The original filename, kept for display only — the object itself is content-named by its hash. Null for camera/library photos, which arrive nameless.';

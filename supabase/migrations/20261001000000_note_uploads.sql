-- Photos on notes.
--
-- A note can now carry images: the composer's camera button uploads the
-- file, and the note references it. Design decisions:
--
--   * Files live in a PRIVATE storage bucket ("uploads"), under the
--     owner's profile-id folder, NAMED BY THEIR SHA-256 — content-addressed,
--     so the same photo uploaded twice is one object and one uploads row,
--     and a duplicate is detected by its name alone. The client hashes
--     before uploading and reuses the existing row when the hash is known.
--   * public.uploads is the metadata (owner, hash, path, mime, bytes);
--     note_uploads is the junction. Junction-per-record-type on purpose:
--     doc_uploads or todo_uploads can join later without touching this.
--     Attaching uploads to NOTES (rather than a free-floating gallery) is
--     the visibility story: a note's photo goes where the note goes — Syla
--     silos the note, and the photo inherits the audience.
--   * Access: the owner reads and writes their own folder and rows; the
--     claude role reads metadata like every application table (so Syla can
--     reason about what a note carries). Members do NOT get storage access
--     here — member delivery needs a signed-URL RPC (an edge function),
--     which lands with the member photo feature, not before. Until then a
--     member sharing the note's silo sees the note's text only.
--
-- The row_edits event trigger attaches history to both tables on creation.

-- ---------------------------------------------------------------------------
-- Metadata
-- ---------------------------------------------------------------------------

create table public.uploads (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    -- The file's SHA-256, lowercase hex — also its name in the bucket.
    hash        text not null check (hash ~ '^[0-9a-f]{64}$'),
    -- The object's full path in the uploads bucket: <profile_id>/<hash>.<ext>
    path        text not null check (char_length(path) between 1 and 300),
    mime        text not null check (char_length(mime) between 1 and 100),
    bytes       bigint not null check (bytes > 0 and bytes <= 26214400),
    created_at  timestamptz not null default now(),
    -- One row per distinct file per owner: the dedup contract.
    unique (profile_id, hash)
);

comment on table public.uploads is
    'One stored file per owner per content hash. Objects live in the private "uploads" bucket at <profile_id>/<hash>.<ext>; rows here are the metadata records go through (note_uploads). Content-addressed: a re-upload of the same bytes lands on the same row.';
comment on column public.uploads.hash is
    'SHA-256 of the file contents, lowercase hex. Doubles as the object''s basename, so duplicates are impossible to store twice.';

create table public.note_uploads (
    note_id     uuid not null references public.manual_notes (id) on delete cascade,
    upload_id   uuid not null references public.uploads (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (note_id, upload_id)
);

comment on table public.note_uploads is
    'Which uploads a note carries. The junction — not a column — so one file can sit on several notes and other record types can grow their own junctions later.';

create index note_uploads_upload_id_idx on public.note_uploads (upload_id);

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.uploads enable row level security;
alter table public.note_uploads enable row level security;

create policy "Uploads are viewable by their owner"
    on public.uploads for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Uploads are insertable by their owner"
    on public.uploads for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Uploads are deletable by their owner"
    on public.uploads for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads it, like every application table.
create policy "claude reads everything"
    on public.uploads for select
    to claude
    using (true);

-- The junction follows the note's owner.
create policy "Note uploads are viewable by the note's owner"
    on public.note_uploads for select
    to authenticated
    using (exists (
        select 1 from public.manual_notes n
        where n.id = note_id
          and n.profile_id = (select public.current_profile_id())
    ));

create policy "Note uploads are insertable by the note's owner"
    on public.note_uploads for insert
    to authenticated
    with check (
        exists (
            select 1 from public.manual_notes n
            where n.id = note_id
              and n.profile_id = (select public.current_profile_id())
        )
        and exists (
            select 1 from public.uploads u
            where u.id = upload_id
              and u.profile_id = (select public.current_profile_id())
        )
    );

create policy "Note uploads are deletable by the note's owner"
    on public.note_uploads for delete
    to authenticated
    using (exists (
        select 1 from public.manual_notes n
        where n.id = note_id
          and n.profile_id = (select public.current_profile_id())
    ));

create policy "claude reads note uploads"
    on public.note_uploads for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200).
grant select, insert, delete on public.uploads to authenticated;
grant select, insert, delete on public.note_uploads to authenticated;
grant select on public.uploads to claude;
grant select on public.note_uploads to claude;

-- ---------------------------------------------------------------------------
-- Storage: the private bucket and its owner-folder policies
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('uploads', 'uploads', false, 26214400, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'image/gif'])
on conflict (id) do nothing;

-- The bucket is private: without a policy nobody reads anything. Each
-- owner works only inside their own profile-id folder.
create policy "Owners read their upload folder"
    on storage.objects for select
    to authenticated
    using (
        bucket_id = 'uploads'
        and (storage.foldername(name))[1] = (select public.current_profile_id())::text
    );

create policy "Owners add to their upload folder"
    on storage.objects for insert
    to authenticated
    with check (
        bucket_id = 'uploads'
        and (storage.foldername(name))[1] = (select public.current_profile_id())::text
    );

create policy "Owners delete from their upload folder"
    on storage.objects for delete
    to authenticated
    using (
        bucket_id = 'uploads'
        and (storage.foldername(name))[1] = (select public.current_profile_id())::text
    );

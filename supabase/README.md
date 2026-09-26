# supabase

Database schema for the production Supabase project, managed as versioned SQL
migrations.

## Layout

| Path          | Purpose                                                     |
| ------------- | ----------------------------------------------------------- |
| `config.toml` | Local Supabase stack config (ports, auth, API).              |
| `migrations/` | Ordered SQL migrations. Filenames are timestamps — never edit a file that has already been applied to production. |

## Schema

| Table | Purpose |
| ----- | ------- |
| `public.profiles` | Application identity. One row per user, created automatically by a trigger on `auth.users`. |
| `public.notes` | A note: `body`, `created_at`, `updated_at`, and the `profile_id` that owns it. |
| `public.goals` | A goal: same shape as a note — `body`, timestamps, owning `profile_id`. |

**`profile_id` is how this schema refers to users.** `auth.users` is referenced
in exactly one place — `profiles.user_id` — and everything else points at
`profiles.id`. That keeps the application's identity namespace its own, so
authentication can change without rewriting every foreign key.

Two consequences worth remembering:

- Nothing needs to create a profile. `handle_new_user()` fires on insert into
  `auth.users`, so a user without a profile is a fault, not a state to code
  around.
- RLS policies resolve the caller through `public.current_profile_id()`, a
  `stable security definer` function that maps `auth.uid()` to a profile id once
  per statement rather than once per row.

## Local development

Requires Docker and the [Supabase CLI](https://supabase.com/docs/guides/local-development).

```bash
supabase start        # boot Postgres, Auth, Studio locally
supabase db reset     # drop and replay every migration from scratch
supabase stop
```

Studio runs at http://localhost:54323, the API at http://localhost:54321.

## Adding a migration

Write the SQL by hand:

```bash
supabase migration new add_tags_to_notes
# edit supabase/migrations/<timestamp>_add_tags_to_notes.sql
supabase db reset     # verify it replays cleanly from empty
```

Or let the CLI diff changes you made in Studio:

```bash
supabase db diff -f add_tags_to_notes
```

## Deploying

You never run `db push` against production by hand, and there is no CI runner
involved. The Supabase GitHub integration watches this repo with **Deploy to
production** enabled: merging a change under `supabase/migrations/` to `main`
makes Supabase apply it to the production database itself.

Supabase also posts a migration check on pull requests — keep it as a required
status check on `main`.

See [`../notes/`](../notes/) for the accounts, setup, and runbooks behind this.

## Rules that keep this safe

1. **Migrations are append-only.** Once a migration has run in production, fix
   forward with a new migration instead of editing the old one — the CLI tracks
   applied migrations by filename and will not re-run an edited file.
2. **RLS on every table.** The web app queries with the public anon key, so an
   unprotected table is a public table.
3. **Grants as well as policies.** They are separate gates and a row needs both.
   A new table with perfect policies and no `grant` fails every query with
   "permission denied for table ..." before RLS is ever consulted. Grant exactly
   the verbs the policies describe, so a table can never be reachable in a way no
   policy covers.
4. **Test the replay, not just the change.** `supabase db reset` proves the
   whole migration history still builds an empty database. Nothing in the
   pipeline does this for you, so it only happens if you run it.
5. **Destructive changes get a two-step.** Ship the additive migration, deploy
   the code that stops using the old column, then drop it in a later migration.

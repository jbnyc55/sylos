---
name: docs
description: Creates, updates, moves, silos and deletes docs — self-contained HTML documents nested by folder-style paths, placed in the shared silos vocabulary that both organizes content and drives member visibility (a silo's members read what sits in it), every change captured in the row_edits undo log. Use when the user asks to add something to the docs, write up a topic as a doc, reorganize, re-silo, share or delete docs, or asks what the docs say.
---

# Docs

The docs live in the `docs` table: one row per doc, each a **complete,
self-contained HTML document** addressed by a folder-style path like
`health/sleep/experiments`. Read it with `scripts/rq`; write it only through
`scripts/doc-save`, `scripts/doc-move` and `scripts/doc-delete`. Every
insert, update and delete — yours or the user's — is captured with full
before/after row images in `row_edits` by a database trigger you cannot
skip or edit, so any change is undoable. Edit freely; the log has your back.

## When to use this

- The user asks to add, update, reorganize or delete doc content.
- The user asks what the docs say about something (read via `rq`).
- Another routine produced knowledge worth keeping as a doc.

## The self-contained contract

A doc must render identically in the app, as a downloaded file, and as an
email attachment. That means, for every doc:

- Starts with `<!doctype html>` (the database refuses fragments) and is one
  full document: `<html>`, `<head>` with `<meta charset>`, `<title>`, one
  inline `<style>`, and a `<body>`.
- **No external requests of any kind**: no linked stylesheets, no scripts,
  no web fonts, no remote images. System font stack only; images, if truly
  needed, as `data:` URIs; diagrams as inline SVG.
- No JavaScript. Docs are documents, not apps, and the viewer renders them
  in a sandboxed iframe where scripts are blocked anyway.
- Cross-references name the target doc by its path in text (e.g. "see
  `health/sleep`"). A standalone file cannot hyperlink into the app, so do
  not fabricate links that only work in one context.

Template to start from (adjust content, keep the shape):

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Doc title</title>
<style>
  body { margin: 0 auto; max-width: 42rem; padding: 2rem 1.25rem 4rem;
         font: 16px/1.6 system-ui, sans-serif; color: #1a1a1a; background: #fdfdfc; }
  h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
  code, pre { font-family: ui-monospace, monospace; background: #f0efec;
              border-radius: 4px; }
  code { padding: 0.1em 0.3em; } pre { padding: 0.75rem; overflow-x: auto; }
  a { color: #175dd6; }
  footer { margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #ddd;
           font-size: 0.85rem; color: #777; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e6e3; background: #16181a; }
    code, pre { background: #24272b; }
    a { color: #7fb0ff; } footer { border-color: #333; color: #999; }
  }
</style>
</head>
<body>
<h1>Doc title</h1>
<p>…</p>
<footer>doc <code>the/doc/path</code></footer>
</body>
</html>
```

## Paths

Lowercase slug segments separated by single slashes: `[a-z0-9-]` only, e.g.
`recipes/weeknight/dal`. Folders are implicit — a "folder" exists exactly
when a doc's path sits under it, object-storage style, so there is nothing
to create or clean up. Before choosing a path, look at the existing tree and
fit into it rather than inventing a parallel hierarchy:

```bash
scripts/rq "select path, title, updated_at from docs order by path"
```

## Instructions

1. **Read before writing.** Fetch the doc (and its neighbors) first — a
   save **replaces** the whole document, so an update means: read the
   current html, change what the user asked, keep the rest.

   ```bash
   scripts/rq "select title, html from docs where path = 'health/sleep'"
   ```

2. **Write the doc to a file** in the scratchpad, honoring the
   self-contained contract above, then save:

   ```bash
   scripts/doc-save --path health/sleep --title "Sleep" --html-file /path/to/doc.html
   ```

   Idempotent; safe to re-run. `op` in the response says `created` or
   `updated`.

3. **Place the doc in silos** whenever you create one or its subject
   shifts. Silos are the same vocabulary as manual notes and do two jobs
   at once: they organize the docs, and they decide member visibility —
   a silo's members read exactly the records sitting in it (when their
   own membership allows SQL — each silo_members row carries that
   member's permissions; a doc in no silo is visible to no member unless the owner
   has named a member directly on it — `doc_members`, owner-only, read it
   but never write it). **Placement is therefore a sharing decision.**
   Read the vocabulary (names *and* descriptions are the rubric) and check
   who each silo currently exposes records to before using it; judge by
   meaning, never invent a silo, and when genuinely unsure whether a silo
   fits, leave it off — a missing silo hides a doc from members, a wrong
   one shows it:

   ```bash
   scripts/rq "select id, name, description from silos order by name"
   scripts/rq - <<'SQL'
   select s.name as silo,
          string_agg(
            m.email || case when sm.allows_sql then '' else ' (no sql)' end,
            ', ' order by m.email
          ) as members
   from silos s
   left join silo_members sm on sm.silo_id = s.id
   left join members m on m.id = sm.member_id
   group by s.id, s.name order by s.name
   SQL
   scripts/doc-silo --path health/sleep --silos <silo-id>,<silo-id>
   scripts/doc-silo --path health/sleep --silos ""   # fits nowhere; member-invisible
   ```

   `--silos` is the doc's **full final set** (the RPC replaces, not
   appends). Placement changes are logged in `row_edits` like every other
   doc change. Who belongs to each silo and what its members may ask is
   the owner's call, made in the app's Manage tab — never edit those rules
   yourself.

4. **Move** one doc per call; a folder rename is a move per doc under it:

   ```bash
   scripts/doc-move --from drafts/dal --to recipes/weeknight/dal
   ```

5. **Delete** only when the user asked for it, or when replacing a doc you
   created earlier in the same job:

   ```bash
   scripts/doc-delete --path drafts/dal
   ```

   Deletion is recoverable — the full row image lands in `row_edits` first.

6. **Undo, when asked to revert something**: find the entry, then save its
   `old_row` content back (a revert is itself a new logged edit, never a
   rewrite of history). The docs table was named `wiki_pages` before
   `20260908020000`, and the log's labels are never rewritten, so history
   reads match both names:

   ```bash
   scripts/rq - <<'SQL'
   select id, op, edited_by, created_at,
          old_row->>'path' as old_path, new_row->>'path' as new_path
   from row_edits
   where table_name in ('docs', 'wiki_pages')
   order by id desc limit 20
   SQL
   scripts/rq "select old_row->>'html' as html from row_edits where id = <id>"
   # then doc-save that html back to old_row->>'path'
   ```

7. **Log the job** once per docs task (not per doc) to `agent_edits` — the
   narrative record next to row_edits' mechanical one:

   ```bash
   scripts/agent-log --action docs-edit --target public.docs \
       --summary "Wrote recipes/weeknight/dal; moved 2 docs under recipes/" \
       --details '{"created": 1, "updated": 0, "moved": 2, "deleted": 0}'
   ```

If `scripts/rq` or a doc script fails on env or auth, stop and report — see
`notes/03-agent-access.md`; do not work around the boundary.

## Notes

- **Never try to write `row_edits`** or work around its read-only-ness; only
  the trigger's own inserts pass its policy, and no update or delete exists
  for anyone, by design. `agent_edits` stays what it always was — your
  voluntary summary log.
- One topic per doc. A doc growing unrelated sections wants to become a
  folder of docs.
- The database caps a doc at 2 MB — plenty for text and inline SVG, a sign
  something is wrong if data-URI images push past it.
- Restoring a deleted doc (the app's restore, or yours in step 6) brings
  back the document alone — silo placements were separate junction rows,
  so the doc returns siloless and therefore invisible to members. Re-place
  it deliberately with `doc-silo`; the old silo set is visible in the
  junction's own `row_edits` entries.
- The user sees the docs in the app's Docs tab, which renders each in a
  sandboxed iframe, offers each as a download, and can restore any version
  from the history panel — that is their undo button; yours is step 6.

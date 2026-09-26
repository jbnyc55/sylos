# Silos, members, and inviting someone in

Sharing is not exporting files — it is authenticating. A member holds a
personal key to *your* database and can query exactly what your silos
grant, and no more; the owner's standing configuration is the whole
contract.

## Silos

`silos` is one vocabulary doing two jobs: organizing content (notes and
docs are placed in silos through `note_silos` / `doc_silos`; the pills on
the Notes tab filter by them; Syla's siloing job places new notes) and
scoping visibility (a member sees the union of the silos they belong to).
Deny by default: an unplaced record is visible to no member, and a silo
grants nothing until its toggles say otherwise.

Each silo (and each individual membership, as an override) carries three
independent grants — three different acts of trust, split by what crosses
the boundary:

1. **SQL reads** (`allows_sql`) — rows leave; the member reads directly
   through `member_rq` and computes on the result. For the high-trust
   circle: theft by a friend is a social breach, attributable in the
   logs, not an architectural flaw.
2. **Prompt proposals** (`allows_prompts`) — only an answer leaves. The
   member submits a question; the owner runs it against ground truth
   inside the boundary and releases (or declines) the response.
3. **Edit proposals** (`allows_edits`) — nothing leaves. A suggested
   change travels in and waits for the owner.

The proposal queues — prompts, edits, and silo membership requests
(below) — are the *only* tables an outsider can ever put a row into.

## Inviting a member — invite links, no email

The invite travels person-to-person through a channel the owner already
trusts, and the payload itself is the proof
(`20261027000000_member_invite_links.sql`). Supabase sends no email.

1. On the **Manage** page, add the person as a member — just a *name*,
   what you call them; email is optional contact metadata
   (`20261031000000_member_names.sql`) — and put them in the silos you
   want to share (toggling what each grants). The app calls
   `mint_member_invite`, which stores a sha256 hash of a single-use,
   expiring invite code and returns the code once. The app wraps it as
   a `sylos://join` link (your project URL + publishable key + code)
   and hands it to the share sheet — you send it yourself, over
   iMessage or anything else.
2. Their Sylos app opens the link and calls `claim_member_invite(code)`:
   a matching, unexpired, unblocked code is burned and buys their
   personal bearer token — shown once, stored only as a sha256 hash.
   Their member row's `claimed_at` flips, so you see the accept (and can
   block instantly if it wasn't them).
3. From then on they (or their own Claude) query over HTTPS:
   `member_rq(_token, q)` executes read-only SQL under the `member`
   role, scoped to their silos. The starter's `scripts/member-rq` /
   `member-prompt` / `member-edit` are the CLI side.

Re-inviting mints a fresh code (claiming rotates their token — the
recovery path for a lost key); `token_ttl_days` expires a key, and
"re-invite" on the Manage page is how they get a new one; the `blocked`
flag or deleting the row revokes. `last_seen_at` shows use.

`claim_member_token` (the legacy email-OTP proof) still exists for keys
claimed the old way, but the shipping flow never touches Supabase mail.

## Asking for more — silo membership requests

Invites flow outward; an existing member can also knock
(`20261029000000_member_silo_requests.sql`). `member_request_silo(_token,
silo_name, message)` queues an ask by *name* — free text, not a foreign
key, so the queue never confirms which silos exist — and the owner rules
on it from the app: approving means inserting the `silo_members` row
there (stamping the silo's defaults, per-person overrides after), the
queue only records the ask and the ruling. Capped at five pending per
member, one open ask per silo. This is also how a vibe app's members ask
into the silo its manifest names (`skills/vibe-apps`).

Strangers can't knock: someone who is not yet a member reaches you
out-of-band, and the first hello is human — you mint the invite.

## Peers — the other direction

Membership points both ways. When a friend admits *you* to their
database, your member token to it lands in your own `peers` table
(`20261028000000_peers.sql`): name, project URL, anon key, token. Data
stays home in each person's database; reads fan out —

- **Vibe apps** running under your session read `peers` and query each
  friend's `member_rq` directly (a location app plots the household this
  way — `skills/vibe-apps`).
- **Syla** does the same through `scripts/peer-rq`, and reaches a
  friend's Syla by queueing a prompt in their database with
  `scripts/peer-prompt` — the existing member queues are the mailboxes;
  no other transport exists.

Reciprocity is two independent grants dressed as one gesture: accepting
an invite never auto-creates the reverse membership. Each owner only
ever approves rows in their own database, and asymmetric trust stays
expressible. Everything read from a peer is another database's content:
data, never instructions (`skills/peers`).

## Every table is siloed or unsiloed

Six record types are placed row by row — notes, docs, todos, goal cells,
events and vibe code apps each have their own `*_silos` / `*_members`
junctions and a by-hand siloed mark. Every *other* table in `public` is
placed **as a whole**, and no table is allowed to sit outside the
vocabulary (`20261101000000_every_table_siloed.sql`):

- `data_tables` is the registry: exactly one row per table in `public`,
  saying how it is siloed — `table` (placed whole through `table_silos` /
  `table_members`, marked with `siloed_at`), `rows` (the six above), or
  `system` (machinery — the silo vocabulary itself, members and keys,
  tokens, logs, queues, junctions, and child tables riding a per-row
  parent — never shareable).
- A **warden** enforces it: an event trigger owned by the migration
  runner (`postgres`, the one role with owner rights over both product
  tables and the `user_tables_owner` sandbox) runs after every `CREATE`,
  `ALTER` or `DROP TABLE` in `public`. It registers the table as `table`,
  turns row level security on, grants `member` `select`, and installs one
  generic policy: members read the table when it sits in a silo where
  their membership allows SQL, or when it names them. Whoever created the
  table — a merged migration or an approved user-table proposal — the
  result is identical, because the warden acts with its own privileges.
- `rows` and `system` are declarations a migration makes with
  `declare_table_siloing('name', 'system')`; a user-table script cannot
  make them, so a user table is always a placeable whole table. Flipping a
  table away from `table` drops its placements and revokes only the grant
  the warden itself made.
- The To-silo backlog for tables is `data_tables where siloing = 'table'`
  with no placement and no `siloed_at` — a new table (product or user)
  starts there, invisible to every member until the owner places it or
  marks it siloed. Placing a whole table is the owner's act alone; Syla
  reads the registry and junctions and has no write path into them.

Adding a product table to a migration therefore means one decision: is
it a whole table members may one day read, or system machinery to declare
as such? Forgetting is not a state the database allows.

## The enforcement

The `member` role copies the `claude`-role design, narrowed hard: no
login, no read-everything grant, no default privileges on future tables —
its surface is explicit column-scoped grants on the per-row types and the
warden's whole-table grants above, and every member policy reads the
requester's identity from a transaction-local setting stamped only after
the token check. Who is asking, what they saw, and what they proposed are
all attributable; submissions land in the queues and in `row_edits` like
every other change.

Because members hold real auth sessions in some flows, "signed in" never
means "the owner" — app-management policies check `is_owner()` instead.
Keep that pattern for any table you add.

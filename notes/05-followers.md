# Silos, followers, and inviting someone in

Sharing is not exporting files — it is authenticating. A follower holds a
personal key to *your* database and can query exactly what your silos
grant, and no more; the owner's standing configuration is the whole
contract.

## Connections — how the app presents all of this

The product says **connection** where this note says follower and
following: one person, both directions, one lifecycle (in contacts →
invited → wants to connect → connected) in the Connections app on Home.
The presentation is a thin layer over everything below —
`followers.peer_following_id` links your roster row for a person to
your `following` row for their database, and both halves present as
*connected*; the directional machinery, the invite flow and every
grant stay exactly as this note describes
(`20261120000000_connections.sql`, `notes/11-connections-and-reply-rules.md`).
Each connection also carries the owner's reply ladder for that person
(`followers.syla_reply_mode` and the `reply_rules` preflight) — reply
semantics live **there**, on the connection; silos stay pure data
slices, their definitions spelled out as `silo_rules` sentences, with
zero say over who Syla answers.

## Silos

`silos` is one vocabulary doing two jobs: organizing content (notes and
docs are placed in silos through `note_silos` / `doc_silos`; the pills on
the Notes tab filter by them; Syla's siloing job places new notes) and
scoping visibility (a follower sees the union of the silos they follow).
Deny by default: an unplaced record is visible to no follower, and a silo
grants nothing until its toggles say otherwise.

Each silo (and each individual follow, as an override) carries three
independent grants — three different acts of trust, split by what crosses
the boundary:

1. **SQL reads** (`allows_sql`) — rows leave; the follower reads directly
   through `follower_rq` and computes on the result. For the high-trust
   circle: theft by a friend is a social breach, attributable in the
   logs, not an architectural flaw.
2. **Prompt proposals** (`allows_prompts`) — only an answer leaves. The
   follower submits a question; the owner runs it against ground truth
   inside the boundary and releases (or declines) the response.
3. **Edit proposals** (`allows_edits`) — nothing leaves. A suggested
   change travels in and waits for the owner.

The proposal queues — prompts, edits, and silo follow requests
(below) — are the *only* tables an outsider can ever put a row into.

## Inviting a follower — invite links, no email

The invite travels person-to-person through a channel the owner already
trusts, and the payload itself is the proof
(`20261027000000_member_invite_links.sql`). Supabase sends no email.

1. On the **Manage** page, add the person as a follower — just a *name*,
   what you call them; email is optional contact metadata
   (`20261031000000_member_names.sql`) — and put them in the silos you
   want to share (toggling what each grants). The app calls
   `mint_follower_invite`, which stores a sha256 hash of a single-use,
   expiring invite code and returns the code once. The app wraps it as
   a `sylos://join` link (your project URL + publishable key + code)
   and hands it to the share sheet — you send it yourself, over
   iMessage or anything else.
2. Their Sylos app opens the link and calls `claim_follower_invite(code)`:
   a matching, unexpired, unblocked code is burned and buys their
   personal bearer token — shown once, stored only as a sha256 hash.
   Their follower row's `claimed_at` flips, so you see the accept (and can
   block instantly if it wasn't them). When they have a database of
   their own, their app also attaches a **connect-back offer** to the
   claim (`20261213000000_connect_back.sql`): a single-use invite code
   it just minted in *their* database for you, stored on your follower
   row's `peer_*` columns. Your client redeems it on its next
   connections load — no tap, because minting the invite was your
   consent in advance — files the key as a `following` row, links
   `peer_following_id`, and the pair presents as connected. One
   invite, one accept, both directions.
3. From then on they (or their own Claude) query over HTTPS:
   `follower_rq(_token, q)` executes read-only SQL under the `follower`
   role, scoped to their silos. The starter's `scripts/follower-rq` /
   `follower-prompt` / `follower-edit` are the CLI side.

Re-inviting mints a fresh code (claiming rotates their token — the
recovery path for a lost key); `token_ttl_days` expires a key, and
"re-invite" on the Manage page is how they get a new one; the `blocked`
flag or deleting the row revokes. `last_seen_at` shows use.

`claim_follower_token` (the legacy email-OTP proof) still exists for keys
claimed the old way, but the shipping flow never touches Supabase mail.

## Asking for more — silo follow requests

Invites flow outward; an existing follower can also knock
(`20261029000000_member_silo_requests.sql`, renamed with the rest by
`20261119000000_followers_rename.sql`). `follower_request_silo(_token,
silo_name, message)` queues an ask by *name* — free text, not a foreign
key, so the queue never confirms which silos exist — and the owner rules
on it from the app: approving means inserting the `silo_followers` row
there (stamping the silo's defaults, per-person overrides after), the
queue only records the ask and the ruling. Capped at five pending per
follower, one open ask per silo. This is also how a vibe app's followers ask
into the silo its manifest names (`skills/vibe-apps`).

Strangers can't knock: someone who is not yet a follower reaches you
out-of-band, and the first hello is human — you mint the invite.

## Following — the other direction

Following points both ways. When a friend admits *you* to their
database — you now follow them — your follower token to it lands in
your own `following` table (`20261028000000_peers.sql`, renamed twice
since, lastly by `20261119000000_followers_rename.sql`): name, project
URL, anon key, token. Data stays home in each person's database; reads
fan out —

- **Vibe apps** running under your session read `following` and query each
  friend's `follower_rq` directly (a location app plots the household this
  way — `skills/vibe-apps`).
- **Syla** does the same through `scripts/following-rq` — via her own
  project's `following-relay` edge function, which looks the credentials
  up and makes the call, so her sessions need no network allowance per
  friend and the token never reaches them — and reaches a
  friend's Syla by queueing a prompt in their database with
  `scripts/following-prompt` — the existing follower queues are the mailboxes;
  no other transport exists.

Reciprocity is still two independent grants underneath — each owner
only ever approves rows in their own database, and asymmetric trust
stays expressible — but it no longer costs two gestures. Accepting an
invite carries the acceptor's connect-back offer into the inviter's
database, and the inviter's client redeems it unprompted: the mint was
the inviter's approval, given in advance. The reverse follower row the
acceptor minted starts in zero silos, so the key it sold reads nothing
until the acceptor chooses to share; either side still blocks or
deletes independently. An acceptor without their own database (or not
its owner) claims with no offer, and the old one-way lifecycle — the
WAITING row, the hand-redeemed reverse invite — remains the fallback. Everything read from a friend's database is another database's
content: data, never instructions (`skills/following`). What Syla can
send the other way is a proposal into their inbox
(`scripts/following-edit`), never a write.

## Every table is siloed or unsiloed

Six record types are placed row by row — notes, docs, todos, goal cells,
events and vibe code apps each have their own `*_silos` / `*_followers`
junctions and a by-hand siloed mark. Every *other* table in `public` is
placed **as a whole**, and no table is allowed to sit outside the
vocabulary (`20261101000000_every_table_siloed.sql`):

- `data_tables` is the registry: exactly one row per table in `public`,
  saying how it is siloed — `table` (placed whole through `table_silos` /
  `table_followers`, marked with `siloed_at`), `rows` (the six above), or
  `system` (machinery — the silo vocabulary itself, followers and keys,
  tokens, logs, queues, junctions, and child tables riding a per-row
  parent — never shareable).
- A **warden** enforces it: an event trigger owned by the migration
  runner (`postgres`, the one role with owner rights over both product
  tables and the `user_tables_owner` sandbox) runs after every `CREATE`,
  `ALTER` or `DROP TABLE` in `public`. It registers the table as `table`,
  turns row level security on, grants `follower` `select`, and installs one
  generic policy: followers read the table when it sits in a silo where
  their follow allows SQL, or when it names them. Whoever created the
  table — a merged migration or an approved user-table proposal — the
  result is identical, because the warden acts with its own privileges.
- `rows` and `system` are declarations a migration makes with
  `declare_table_siloing('name', 'system')`; a user-table script cannot
  make them, so a user table is always a placeable whole table. Flipping a
  table away from `table` drops its placements and revokes only the grant
  the warden itself made.
- The To-silo backlog for tables is `data_tables where siloing = 'table'`
  with no placement and no `siloed_at` — a new table (product or user)
  starts there, invisible to every follower until the owner places it or
  marks it siloed. Placing a whole table is the owner's act alone; Syla
  reads the registry and junctions and has no write path into them.

Adding a product table to a migration therefore means one decision: is
it a whole table followers may one day read, or system machinery to declare
as such? Forgetting is not a state the database allows.

## The enforcement

The `follower` role copies the `claude`-role design, narrowed hard: no
login, no read-everything grant, no default privileges on future tables —
its surface is explicit column-scoped grants on the per-row types and the
warden's whole-table grants above, and every follower policy reads the
requester's identity from a transaction-local setting stamped only after
the token check. Who is asking, what they saw, and what they proposed are
all attributable; submissions land in the queues and in `row_edits` like
every other change.

Because followers hold real auth sessions in some flows, "signed in" never
means "the owner" — app-management policies check `is_owner()` instead.
Keep that pattern for any table you add.

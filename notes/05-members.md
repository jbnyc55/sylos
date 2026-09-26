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

The two proposal queues are the *only* tables an outsider can ever put a
row into.

## Inviting a member

1. On the **Manage** page, add the person's email as a member and put
   them in the silos you want to share (toggling what each grants).
2. Have them install the Sylos app and enter *your* project URL and
   publishable key at the Connect step. They then claim their key: verify
   that same email through Supabase's emailed one-time code and receive
   their bearer token — shown once, stored only as a sha256 hash. (The
   native app doesn't carry the claim screen yet; until it does, the
   claim RPCs — `claim_member_token` — are callable from any HTTP client
   with the project URL + publishable key.)
3. From then on they (or their own Claude) query over HTTPS:
   `member_rq(_token, q)` executes read-only SQL under the `member` role,
   scoped to their silos. The starter's `scripts/member-rq` /
   `member-prompt` / `member-edit` are the CLI side.

Claiming again rotates the token; `token_ttl_days` expires it (they
re-verify to re-claim); the `blocked` flag or deleting the row revokes.
`last_seen_at` shows use.

## The enforcement

The `member` role copies the `claude`-role design, narrowed hard: no
login, no read-everything grant, no default privileges on future tables —
its entire surface is explicit column-scoped grants, and every member
policy reads the requester's identity from a transaction-local setting
stamped only after the token check. Who is asking, what they saw, and
what they proposed are all attributable; submissions land in the queues
and in `row_edits` like every other change.

Because members hold real auth sessions for a moment during the claim,
"signed in" no longer means "the owner" — app-management policies check
`is_owner()` instead. Keep that pattern for any table you add.

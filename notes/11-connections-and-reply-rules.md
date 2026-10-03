# Connections and reply rules

One app — **Connections**, on Home — presents the whole lifecycle of a
relationship. The data layer stays directional (`followers` = their key
into your database, `following` = your key into theirs —
`notes/05-followers.md` is still the machinery); what is new is the
presentation, the link between the directions, and the reply ladder each
connection carries.

## The lifecycle

Client-side states, read off columns that already exist plus one link
(`20261120000000_connections.sql`):

| State | Data |
| ----- | ---- |
| in contacts, not invited | only on the phone — contacts never leave the device until one is chosen |
| invited | `followers.invite_code_hash` set, `claimed_at` null |
| wants to connect | `claimed_at` set, `peer_following_id` null — they're in, you don't follow back yet |
| **connected** | `claimed_at` set **and** `peer_following_id` set — both directions held |

Invites are copy-paste text messages: the app composes the message
around the `sylos://join` link and hands it to the share sheet —
**nothing sends from Sylos**. Redeeming stays `claim_follower_invite`,
following back stays an ordinary `following` insert; `peer_following_id`
is just the roster row remembering which `following` row is the same
person.

**Strict one-sided visibility.** Everything on your `followers` row —
the link, the reply mode, the rules below — is *your* side: your rules,
your sharing. A follower reads their own row and your silos' grants,
never your settings about them; their copy of the relationship lives in
their database. Nothing here changes what crosses the boundary.

## The reply ladder

`followers.syla_reply_mode`, per connection — how *your* Syla may answer
*this person* in chat:

1. **off** — she stays out of the chat entirely: no drafts, no
   auto-replies, no suggestions, no waiting flags. A plain
   conversation.
2. **propose** (the default) — she only drafts. A draft is a pending
   `chat_reply_proposals` card in the thread; approving it sends **as
   you** (your session inserts the message, author `'me'`).
3. **auto** — she may send where an **active reply rule** covers the
   message, through `send_auto_reply`, always attributed (the peer
   renders "signed as Syla", `chat_messages.kind = 'auto_reply'`).

A fourth rung, `syla_syla`, retired in 20261215000000: it was both
sides on auto in practice — the agents already talk wherever each
side's rules allow a send. Existing rows stepped down to `auto`;
`syla_syla_peer_ok` stays as a dormant column. Two agents' overnight
conclusions remain Inbox cards (`syla_approvals` kind `conclusion`),
not applied facts.

There is no "turn on auto-reply" toggle: **rules accumulate from
approvals**. The one exception is the **integration moment**: a message
that needs data from a missing integration ("where are you?", no
location) gets no half-draft — Syla files the needs-integration
suggestion immediately instead, the card wears the connect flow, and
connecting wakes her to answer with the real data. After you approve a draft, the same card advances to offer
exactly one rule (`chat_reply_proposals.offered_rule_id` → the
`suggested` row Syla filed with `suggest_reply_rule`); a second
suggestion comes only after a yes. The ladder sheet still exists to
display and edit the mode directly.

## Reply rules — the preflight

`reply_rules` (`20261122000000`): per connection, an ordered list of
plain-English sentences checked top-to-bottom (`rank`) before any
auto-reply sends. Exactly two verdicts — **REPLY** and **DON'T REPLY**
— and **anything uncovered waits for the human** (the chat gets the
blue dot, `chats.waiting_on_human`, via `set_chat_waiting`).

- Every rule is editable text, whoever wrote it. `built_in` and
  `suggested` are provenance labels, not locks.
- Every connection is seeded with one built-in DON'T REPLY rule:
  *"Never agree to money, travel, or plans with other people."*
- **Platform guarantees are not rules** (rules are editable; these must
  not be): a message asking for the human always stops Syla — stated in
  the app's footnote, bound in `skills/chat-replies` — and the
  preflight's fail-closed default is the preflight itself.
- A suggested rule that needs a missing integration says so
  (`needs_integration`, disclosed on the card: "needs your iPhone's
  location — connecting it is the next step"); accepting the rule leads
  to the connect sheet, declining parks the rule as `draft` and the
  chat stays waiting on you.

The database's gate is structural, the sentence-reading is procedure:
`send_auto_reply` proves the chat is a dm or group, that the cited
rule's own person is named on it, and that that person's mode allows
sending (`20261212000000_group_chats.sql`) — whether the sentence truly
covered the message is Syla's preflight (`skills/chat-replies`),
attributable after the fact because every auto-reply carries `rule_id`
and every edit is in `row_edits`.

## Groups change nothing about rules

There are no group rules. In a group chat Syla answers one person's
message under that person's active rule, exactly as in a dm — the whole
roster reads the reply, but the authorization is one connection's mode
and one connection's list. What the app's group screens add is purely
convenience: a suggestion can offer the same sentence onto several
members' lists at once, and the chat's details page gathers the members
so each one's list is a tap away. Every write those screens make is an
ordinary per-person `reply_rules` write.

## The poke — how Syla learns a message arrived

A peer's message lands in *their* database, so nothing here ever
changed when one arrived — and nothing woke Syla. The sender's side
closes the gap (`20261214000000_chat_pokes.sql`): after a send, the
sender's client (or their Syla, after an auto-reply — the relay's
`poke` kind, `scripts/following-poke`) calls `follower_poke_chat()` in
the *recipient's* database with its follower token and the shared
`chat_key`. The knock carries no text; it is gated by the chat's own
roster (only a dm or group whose `chat_followers` row names that
follower), recorded in `chat_pokes`, and it queues an event-less
`syla_job_runs` row and fires the routine webhook inline —
`send_to_syla`'s arrangement exactly. The claim entry's `poke` field
names the chat and who knocked; Syla then reads the whole thread (her
side plus the relay) and acts by the reply ladder above. Pokes landing
while a poke run is still queued coalesce onto it, so rapid messages
cost one waking, and the owner can see every knock (and block a noisy
follower) like any other row.

## Receiving the other side

A peer's auto-reply arrives as *their* message row with
`kind = 'auto_reply'` — your client renders the attribution and, under
it, two equal quiet chips: **"Ask [name] directly"** (sends nothing;
marks their chat waiting-on-human on your side — and your ask travels
as a `kind = 'ask_human'` message, which *their* client uses to flag
*their* chat) and **"Have Syla draft yours"**. Decentralization holds:
each flag, draft and rule lives on its author's side only.

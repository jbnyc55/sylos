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

1. **propose** (the default) — she only drafts. A draft is a pending
   `chat_reply_proposals` card in the thread; approving it sends **as
   you** (your session inserts the message, author `'me'`).
2. **auto** — she may send where an **active reply rule** covers the
   message, through `send_auto_reply`, always attributed (the peer
   renders "signed as Syla", `chat_messages.kind = 'auto_reply'`).
3. **syla_syla** — auto, plus the two agents may talk. Needs both
   sides: your mode set to it *and* `syla_syla_peer_ok`, which is
   learned from an attributed message in the chat — never from reading
   their database. Syla × Syla is 1:1, and its overnight conclusions
   are Inbox cards (`syla_approvals` kind `conclusion`), not applied
   facts.

There is no "turn on auto-reply" toggle: **rules accumulate from
approvals**. After you approve a draft, the same card advances to offer
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
`send_auto_reply` proves the chat is a dm whose single counterparty's
mode allows sending and that the cited rule is theirs, active, verdict
REPLY — whether the sentence truly covered the message is Syla's
preflight (`skills/chat-replies`), attributable after the fact because
every auto-reply carries `rule_id` and every edit is in `row_edits`.

## Receiving the other side

A peer's auto-reply arrives as *their* message row with
`kind = 'auto_reply'` — your client renders the attribution and, under
it, two equal quiet chips: **"Ask [name] directly"** (sends nothing;
marks their chat waiting-on-human on your side — and your ask travels
as a `kind = 'ask_human'` message, which *their* client uses to flag
*their* chat) and **"Have Syla draft yours"**. Decentralization holds:
each flag, draft and rule lives on its author's side only.

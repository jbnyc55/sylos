# Minis and chat

A Sylos install is a personal Supabase project that hosts minis. A
MINI is a whole client-side app, built into one self-contained HTML
file, stored as a row in `minis`, served
straight over PostgREST and run in an iframe with the owner's session
handed in by postMessage (migrations `20261008000000`,
`20261030000000`, `20261115000000`). What is new is the shape of the
product around them: **the client is a home screen of minis**,
and two rules that bind everything below.

## The two rules

**Every mini has the same format: code + manifest + icon.** The code is
the bundle (`html`) and its source tree (`mini_files`), both
rows in the owner's database — the database is where mini code lives.
The manifest (`sylos-manifest.json`) declares what the mini needs,
never SQL to run. The icon (`icon` on the row, `20261115000000`) is an
emoji or one inline `<svg>`, rendered by shells as an image — never a
script context — so the home screen can show anyone's icon safely. No
mini is special: chat, todos, a friend's rent tracker — same three
pieces, same deploy (`scripts/mini-save … --icon`), same undo log.

**Minis are never served between databases; every source of truth is
local.** A mini someone's silo shares with you is a thing to *rebuild
for yourself*, not to run from their project: its bundle is read once
over your follower key, landed in **your** database, and is local
source of truth from then on — running under your session, surviving
their project pausing, yours to edit. The quick path is a verbatim
copy (the client's Copy button; take minis from people you trust); the
careful path is Syla's install flow — audit the bundle, re-derive the
tables from the manifest, deploy fresh (`skills/minis`). Either
way there is no remote runner, no "open from their shelf", and no
special context posted into anyone's frame. This retired the one
exception the chat app used to enjoy.

## The home screen

Logging in lands on a home screen in Chat's design language — a grid
of minis, icon over name, the way a phone's home screen works. The old
five-tab app is gone, split into its parts, each a separate mini:
**Chat**, **Notes**, **Docs**, **Todos**, **Goals** (opened from
Todos), **Calendar**, **Silos**, **Syla** — plus every mini in the
owner's database. The stock set is rendered by the shell today and
ships as real minis over time; because icon and format travel with the
row, the cutover per mini is just a deploy. `profiles.default_app`
still names the app the client boots straight into (`home` is the
home screen, and the default).

Two doors into the grid, both on the dashed **New** tile:

- **Vibe code it** — describe the mini; the ask goes to Syla
  (`send_to_syla`), and she writes the code, manifest and icon
  straight into your storage through the same gated deploy as always.
- **Copy one shared with you** — the "From silos you follow" shelf,
  rebuilt into your project as above.

## Following, all the way down

The vocabulary is follow-shaped everywhere: you **follow** another
Sylos (redeeming an invite, or `follow()` where the owner opened it —
`20261114000000`); the people reading yours are your **followers**;
what they see is decided by silos, exactly as before. The schema
says the same words the product does
(`20261119000000_followers_rename.sql`): `followers`, `following`,
`silo_followers`, `follower_rq` — the member era's names are gone
from copy and catalog alike.

## Chat: personal, all the way down

Chat was the one centralized record, and it no longer is. A
conversation has no host anywhere (`20261116000000_personal_chat.sql`):

- **Your words live in your own database.** `chat_messages` rows in
  your project are the messages you sent — nothing else. Deleting your
  side is real deletion.
- **A DM is a mutual follow.** Each side holds a `chats` row carrying
  the same `chat_key` and names the other on it (`chat_followers` →
  your `followers` rows). Naming a follower IS the read grant: chats are
  secret by audience and never siloed — a silo placement can widen a
  record to a whole shelf of followers, which is exactly what a DM
  must never do. Silos only ever govern what you deliberately archive
  out of a chat into your records, and that copy defaults to private.
- **Reading a chat is a merge.** Your client interleaves your rows
  with each peer's, read from their database over your follower key
  (`follower_rq`, or their realtime channel while the app is open).
  Nobody ever writes into anyone else's database.
- **Messages carry author and kind** (`20261121000000_chat_first.sql`).
  `author` is `'me'` or `'syla'` — an approved draft sends as the
  human; only rule-gated auto mode sends as Syla, and only through the
  gated RPCs. `kind` is how every cross-person feature travels as an
  attributed message on the sender's side: `auto_reply` (my Syla sent
  this under an active reply rule — the receiving client renders
  "signed as Syla" and the two chips), `ask_human` (the travelling
  ask-for-the-human flag — the receiving client marks its chat
  `waiting_on_human`, the blue dot), `syla_status` (Syla's own lines in
  the Syla chat), `mini_share` (this side shared a mini —
  below). No drafts, rules or conclusions ever travel — those
  stay local (`notes/11-connections-and-reply-rules.md`).
- **An attachment is a reference; delivery is a signed URL, minted
  per fetch** (`20261211000000_chat_attachments.sql`,
  `20261219000000_attachment_relay.sql`). A message may carry
  `upload_id` — a row in the sender's content-addressed `uploads`
  store, the same place the chute's drops land. The bytes stay in the
  sender's private bucket, which remains the file's one home: a peer
  who can read the message fetches the file through the sender's
  `follower-file` edge function (their follower token plus the upload
  id buys a short-lived signed URL, gated by `follower_file_target` —
  only an upload some chat message in a chat naming that follower
  carries, re-checked on every call). Nothing is copied ahead of time,
  `uploads` metadata still has no follower policy, and deleting the
  message or the upload ends delivery. A peer's Syla reaches the same
  gate through her own project's `following-relay` (kind `file`,
  `scripts/following-file`), which relays the bytes because her
  sessions can reach no host but her own project's.
- **A group is a roster, locally copied.** Whoever assembles it mints
  the `chat_key` and names the followers; each follower's client mirrors
  the row into their own project and names the others back — as far as
  it can identify them: a follower reads only the chats naming them,
  never the rest of the roster, so a mirrored copy names the people its
  owner already knows. A group's name is each side's own `chats.title`
  — renaming is one local update, visible only to you. Syla works in
  groups per person, never per group: an auto-reply answers one
  person's message under that person's active rule
  (`20261212000000_group_chats.sql`), and reply rules themselves never
  grow a group scope — the app's group screens only ever edit several
  individual lists at once.
- **The company project keeps no chat index, no bodies, no social
  graph.** Its one chat duty is a stateless push hop: "wake this
  device", stored nowhere (the developer's `push-relay`). Who you
  talk to is written only in the databases of the people talking.

The costs are chosen, not accidental: there are no DMs before your
project exists and an invite has changed hands (the invite link is
how every conversation begins), there is no contact discovery, and a
paused peer is a silent peer until their project wakes. What is
bought is the doctrine, whole: every source of truth is local,
including the social graph.

## Syla is a conversation

Talking to your agent stops being an inbox tab and becomes a chat: one
seeded conversation per owner (`chats.kind = 'syla'`, pinned by kind,
local only — never mirrored to a peer). Sending is `send_to_syla()`,
which now also writes your message into the thread linked to its
queued run; the thread then shows the real receipt ladder off that run
(Sent · Delivered · Syla's reading — `notes/04-syla-jobs.md`), and her
reply arrives through `syla_chat_say`, pointing back at the same run.

In every *other* chat her presence is drafts and rules: a pending
`chat_reply_proposals` card under the thread ("Syla drafted a reply"),
approved by you and sent as you; an auto-reply only where the
connection's ladder and an active reply rule allow it
(`notes/11-connections-and-reply-rules.md`). Anything heavier — a
Syla × Syla conclusion, a calendar add she inferred from a chat, a
silo membership change — is a `syla_approvals` card in the Inbox. The
card is a pointer; the proposal lives in your own database, created
through the same gated RPCs as always (`notes/03-agent-access.md`),
and approving is a write under your own session. The boundary does not
move — the agent still cannot touch your data without an approved
proposal — only the place you review things does. The Chats tab
signals the backlog ("2 things to approve · Waiting in your Inbox" →
Home's badged Inbox tile), and the Inbox's footer states the contract:
nothing Syla agrees to is final until you approve it there.

## Your Claude, nobody else's

Syla runs on **your own Claude account, full stop** — the hosted trial
and the hosted-agent defaults are gone (`notes/09-hosted-trial.md` is
historical; `20261127000000` removed the last schema knob). The web
setup at getsylos.com/setup walks the Claude environment and routine
steps alongside the database ones (`notes/02-setup.md`), and the
access story never changes hands: your project's rq key — the `claude`
role, narrow gated writes, proposals, the undo log — and the agent
never holds an owner JWT or the management credential.

## Following feels like a DM

Making a chat partner a follower of your own project no longer needs a
trip through settings. Chat mints the invite in *your* project
(`mint_follower_invite`, over the own-project session) and sends it as
an invite message: the card carries your project's coordinates and the
single-use code, and the recipient claims it in one tap
(`claim_follower_invite` against your project). The chat is just the
transport; the machinery is this starter's, unchanged
(`notes/05-followers.md`).

## Sharing a mini is a message

A two-player mini (the first-run race, a household map) needs three
things at once: the connection, the mini on both sides, and the data
grants in both directions. One gesture per person covers it
(`20261226000000_app_share_messages.sql`):

- **The sender shares from the chat.** The share sheet does four
  owner-session writes in the sender's own database: name the
  connection on the mini (`mini_followers` — what lets the
  card's reads and the copy pass RLS), grant the sender's own side of
  the data (the silo the mini's `sylos-manifest.json` names gets the
  connection's follow, with the mini's tables in it — stated plainly on
  the sheet), insert the `kind = 'mini_share'` message carrying the
  mini's slug, and poke (`follower_poke_chat`) when the connection is
  already claimed. Syla builds minis; **sharing one is a grant, and
  grants are the owner's alone** — she has no write path into any of
  this, and her column-scoped message insert excludes `mini_slug`.
- **The receiver accepts from the card.** Their client reads the mini's
  name, icon and manifest over their follower key, and one accept does
  their whole side, all local owner-session writes: copy the bundle
  into their own `minis` (minis are never served between
  databases — the copy pins the code they accepted) and grant back the
  silo the manifest names. Remixing their copy later is what makes it
  properly theirs; an un-remixed copy can take the sender's updates on
  its owner's say-so.
- **It works before the claim.** The message is a row in the sender's
  database, so the whole share can be staged while the invite is still
  in flight: unreadable until the claim mints the key, delivered the
  moment it does. Accepting an invite also queues a run for the
  *inviter's* Syla (`20261227000000_claim_wakes_syla.sql` — the claim
  entry's `claim` field), so "they're in" reaches the owner without
  anyone polling.

The asks-for-more path is unchanged: an existing follower who wants
into a silo still knocks through `follower_request_silo`
(`notes/05-followers.md`); the mini-share card is the offer direction,
and it crosses no boundary at all.

## Your chat, your Syla

Whether your Syla works a chat is your own flag on your own `chats`
row — sweeps it for things to act on, so a DM about Friday dinner can
end up as an event on your calendar, created through your project's
gated write paths. Reading the other sides means using your follower
keys, so the consent is stated plainly: **enabling Syla on a chat
means your agent processes what the other followers wrote in their
databases** — the same reality as any follower copying a chat out by
hand. My Syla watching a chat says nothing about yours.

## Deliberately not built yet

- **The Chat client on the merge model.** The schema above is live;
  the chat app still speaks the retired centralized model (the
  company project's `mash_chat` tables) until it is rewritten to
  write home and merge peers. Those company tables are legacy the day
  the client switches, and prunable.
- **The stateless push hop** — the trigger that asks the developer's
  relay to wake a peer's device, storing nothing.
- **Stock minis as deployed bundles.** The stock set renders in the
  shell until each is built into a single file and deployed; the home
  screen doesn't change when they do.
- **Copy counts and provenance** on shared minis ("copied 12×"), and a
  guided Syla-rebuild button next to the verbatim Copy.

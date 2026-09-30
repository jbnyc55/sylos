# Apps and chat

A Sylos install is a personal Supabase project that hosts apps. The
apps are vibe code apps — whole client-side apps, each built into one
self-contained HTML file, stored as a row in `vibe_code_apps`, served
straight over PostgREST and run in an iframe with the owner's session
handed in by postMessage (migrations `20261008000000`,
`20261030000000`, `20261115000000`). What is new is the shape of the
product around them: **the client is a home screen of separate apps**,
and two rules that bind everything below.

## The two rules

**Every app has the same format: code + manifest + icon.** The code is
the bundle (`html`) and its source tree (`vibe_code_app_files`), both
rows in the owner's database — the database is where app code lives.
The manifest (`sylos-manifest.json`) declares what the app needs,
never SQL to run. The icon (`icon` on the row, `20261115000000`) is an
emoji or one inline `<svg>`, rendered by shells as an image — never a
script context — so the home screen can show anyone's icon safely. No
app is special: chat, todos, a friend's rent tracker — same three
pieces, same deploy (`scripts/vibe-save … --icon`), same undo log.

**Apps are never served between databases; every source of truth is
local.** An app someone's silo shares with you is a thing to *rebuild
for yourself*, not to run from their project: its bundle is read once
over your follower key, landed in **your** database, and is local
source of truth from then on — running under your session, surviving
their project pausing, yours to edit. The quick path is a verbatim
copy (the client's Copy button; take apps from people you trust); the
careful path is Syla's install flow — audit the bundle, re-derive the
tables from the manifest, deploy fresh (`skills/vibe-apps`). Either
way there is no remote runner, no "open from their shelf", and no
special context posted into anyone's frame. This retired the one
exception the chat app used to enjoy.

## The home screen

Logging in lands on a home screen in Mash's design language — a grid
of apps, icon over name, the way a phone's home screen works. The old
five-tab app is gone, split into its parts, each a separate app:
**Chat**, **Notes**, **Docs**, **Todos**, **Goals** (opened from
Todos), **Calendar**, **Silos**, **Syla** — plus every vibe in the
owner's database. The stock set is rendered by the shell today and
ships as real vibes over time; because icon and format travel with the
row, the cutover per app is just a deploy. `profiles.default_app`
still names the app the client boots straight into (`home` is the
home screen, and the default).

Two doors into the grid, both on the dashed **New** tile:

- **Vibe code it** — describe the app; the ask goes to Syla
  (`send_to_syla`), and she writes the code, manifest and icon
  straight into your storage through the same gated deploy as always.
- **Copy one shared with you** — the "From silos you follow" shelf,
  rebuilt into your project as above.

## Following, not membership

The vocabulary is follow-shaped now, in the UI and the docs: you
**follow** another Sylos (redeeming an invite, or `follow()` where the
owner opened it — `20261114000000`); the people reading yours are your
**followers**; what they see is decided by silos, exactly as before.
The tables keep their names (`members`, `memberships`, `silo_members`)
— this is wording, not schema — but product copy says "Following",
"Followers", "silos you follow".

## Chat: relayed through the company project, never owned by it

Chat is the one place transport is centralized, and the line is drawn
precisely. A conversation between two people who each own a database
has no natural host: hosted on either follower's free-tier project it
dies when that project pauses, a chat list would mean polling N
projects with N credentials, and a brand-new person with no project
yet still needs to be reachable. So messages pass through the shared
company project (getsylos.com's), where RLS is per-member instead of
per-owner.

But under "every source of truth is local" the company project is
**transport, not truth** — a mailbox. The chat *app* is an ordinary
vibe in your own project that connects out to the company database on
the fly with its own account there, exactly the way any app reads any
other database; the shell posts it nothing special. And the durable
copy of every chat is meant to be each member's own database: the
**chat archive job** (a Syla job routing chats into your silos via
`chat_settings`) is what makes the doctrine hold — company rows are
ephemeral and prunable; losing the company database would cost
delivery, never history. Until the archive job ships, that is the
honest gap in the rule.

## Syla is a conversation

Talking to your agent stops being an inbox tab and becomes a chat:
every person has one agent conversation, where Syla reports her runs,
asks her questions, and surfaces **proposal cards**. The card is a
pointer. The proposal it points to still lives in your own database,
created through the same gated RPCs as always
(`notes/03-agent-access.md`), and approving or rejecting it is a write
to your own project under your own session. The boundary does not move
— the agent still cannot touch your data without an approved proposal
— only the place you review things does.

## The hosted agent, in one paragraph

By default nobody meets a Claude setup screen: a person's agent runs
hosted, on the company's account, and Settings offers "use your own"
for anyone who wants today's own-routine setup instead. What keeps a
pooled agent user-scoped is not which account fired it but a
**dedicated Supabase session its user deposited** on the company
project — a second sign-in with its own refresh-token family — which a
claimed job hands to the agent session, so it acts as that user under
plain RLS there. Work on your **own** project is untouched by all of
this: it still goes through your project's rq key — the `claude` role,
narrow gated writes, proposals, the undo log — and the agent never
holds an owner JWT for a personal project.

## Following feels like a DM

Making a chat partner a follower of your own project no longer needs a
trip through settings. Chat mints the invite in *your* project
(`mint_member_invite`, over the own-project session) and sends it as
an invite message: the card carries your project's coordinates and the
single-use code, and the recipient claims it in one tap
(`claim_member_invite` against your project). The chat is just the
transport; the machinery is this starter's, unchanged
(`notes/05-members.md`).

## Your silo, your Syla

`chat_settings` is each member's own take on a chat: which of *their*
silos it files into, and whether *their* Syla works it — sweeps it for
things to act on, answers asks, so a DM about Friday dinner can end up
as an event on your calendar, created through your own project's gated
write paths and answered in the chat attributed as your Syla. The flag
is strictly per-person — my Syla watching a chat says nothing about
yours. And the consent, stated plainly: **enabling Syla on a shared
chat means your agent processes what the other members write there.**
That is the same reality as any member copying a chat out by hand, and
the flag is surfaced to the other members rather than hidden.

## Deliberately not built yet

- **The chat archive job** — the piece that makes "company project as
  transport, not truth" literally true (above).
- **Stock apps as deployed vibes.** The split apps render in the shell
  until each is built into a single file and deployed; the home screen
  doesn't change when they do.
- **Copy counts and provenance** on shared apps ("copied 12×"), and a
  guided Syla-rebuild button next to the verbatim Copy.

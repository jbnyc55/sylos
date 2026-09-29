# Apps and chat

A Sylos install is a personal Supabase project that hosts apps. The
apps are vibe code apps — whole client-side apps, each built into one
self-contained HTML file and stored as a row in `vibe_code_apps`,
served straight over PostgREST and run in an iframe with the user's
session handed in by postMessage (the deploy and manifest machinery:
migrations `20261008000000` and `20261030000000`). That machinery
predates this note; what is new is the inversion. The apps stop being
side tools behind a Tools page and become the product: everything a
person touches is a vibe, and the platform underneath — the database,
silos, members, Syla, the undo log — does not change.

## The default app

`profiles.default_app` names the app the client boots straight into:
`mash` (the stock chat app), `todos` (the classic tabs), or the slug of
any `vibe_code_apps` row. It is a per-person client preference, exactly
as personal — and as harmless — as `email`, and guarded the same way:
the own-row update policy on `profiles` plus a column-scoped grant. It
is not a grant of anything; what a session may actually open is still
decided by each app's own RLS.

## Two stock apps; lead with the fun one

Every install ships two apps:

- **Mash** — chat. DMs and group chats, and every chat has its own
  shelf of **minis**: vibe apps hosted in their creators' own
  projects, which anyone in the chat can open or **remix** — fork into
  another chat, the copy landing in the remixer's own project. Mash is
  the default: it is the first thing a new person sees, and chatting
  works before their own project has even finished provisioning.
- **Todos** — the classic app: the todos / docs / goals / proposals /
  silos UX this starter grew up with, built into a single file and
  deployed like any other vibe. It sits quietly second in the
  switcher. Nobody needs to know about it off the bat; but all the
  database UX is one tap away, and being a vibe it can be remixed
  like anything else.

## What lives where

The rule everywhere else in this system is *your data in your own
database*. Chat is the one deliberate exception, and the line is worth
drawing precisely.

**On the company's project** (the shared Supabase project behind
getsylos.com) live the chats, the messages, and the cards that ride in
them — mini cards, proposal cards, invite cards. Chat is centralized
because a conversation between two people who each own a database has
no natural host: hosted on either member's free-tier project it dies
when that project pauses, a chat list would mean polling N projects
with N credentials, and a brand-new person with no project yet still
needs to be reachable. Messages are social transport. There is still
no backend — it is one shared Supabase project where RLS is per-member
instead of per-owner.

**In your own project** (this starter's schema) lives everything
durable and personal, unchanged: todos, docs, goals, notes, money,
health, the undo log, the proposals themselves — and the minis. A
mini's code (`vibe_code_apps`) and whatever state it keeps live in its
creator's project; the card in the chat is only a pointer — host
project URL, publishable key, slug — never the app itself. Opening a
mini means talking to its host project directly, under that project's
RLS.

## Syla is a conversation

Talking to your agent stops being an inbox tab and becomes a chat:
every person has one agent conversation, where Syla reports her runs,
asks her questions, and — the important part — surfaces **proposal
cards**. The card is a pointer. The proposal it points to still lives
in your own database, created through the same gated RPCs as always
(`notes/03-agent-access.md`), and approving or rejecting it is a write
to your own project under your own session, exactly as it was from the
inbox. The boundary does not move — the agent still cannot touch your
data without an approved proposal — only the place you review things
does.

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

## Membership feels like a DM

Making a chat partner a member of your own project no longer needs a
trip through settings. Mash mints the invite in *your* project
(`mint_member_invite`, over the own-project session the shell already
holds) and sends it as an invite message: the card carries your
project's coordinates and the single-use code, and the recipient's
Mash claims it in one tap (`claim_member_invite` against your
project). The chat is just the transport; the membership machinery is
this starter's, unchanged (`notes/05-members.md`).

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

- **Manifest-scoped member tokens for minis.** Today a mini card works
  when the mini is marked open to signed-in users on its host project;
  the general handshake — per-member tokens minted on the host, scoped
  by the mini's `sylos-manifest.json`, delivered through the card — is
  designed but not built.
- **The chat archive job.** The ownership hedge: a Syla job that
  archives your chats into your own database, routed by your
  `chat_settings` silo — company project as the live relay, your
  project as the copy of record. Raw logs now, as ever.

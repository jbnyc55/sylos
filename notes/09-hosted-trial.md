# The hosted trial — Sylos runs a starter install for people to try

Onboarding opens on a choice: **set up my own** (the checklist in
[`02-setup.md`](02-setup.md) / [`08-provisioning.md`](08-provisioning.md) —
your Supabase, your Claude, about ten minutes, everything yours) or
**try hosted Syla** — one account and you're in, live in about a minute,
marked *Trial* on every screen, and never meant for the long term.

There is no second system behind the trial. The hosted project is an
ordinary install of this starter that the Sylos company owns and runs
Syla for; a trial is one more profile on it. That keeps the promise
symmetrical: what a trial user sees is exactly what their own install
would show, and moving to their own is the same checklist with the
badge coming off at the end.

## What the app does on "Try hosted Syla"

1. Creates the account (or signs in) on the hosted project — its URL
   and publishable key are constants in the app (`HostedConfig` in
   `Hosted.swift`, client-public values like any project the app
   connects to).
2. Marks the install `hostedTrial`, counts Syla's key and the agent
   wiring as done (the project's Syla is Sylos's, not the user's), and
   opens the main app. Every page header, the profile sheet and the
   trial screen itself carry the amber **Trial** badge.
3. Registers the install with the company's main Supabase project —
   [`sylos-company` `notes/15-sylos-installs.md`](https://github.com/jbnyc55/sylos-company/blob/main/notes/15-sylos-installs.md) —
   as `mode = 'hosted'` with the trial's email, so the company knows
   who is on the hosted project.

**Move to your own Sylos** (a profile row that replaces *Setup* while
hosted) restarts the own checklist from the Supabase step, full-screen.
The trial's account and data stay on the hosted project until
provisioning points the app at the new project; on *Finish* the badge
comes off and the app registers the move — the new project's URL,
publishable key and rq key, plus the trial profile's id — which is what
lets the company's Syla carry the trial data over. Backing out to the
first step and signing in to the trial again cancels the move.

## What a trial can and cannot do

- Todos, notes, goals, docs, apps: theirs, by the per-profile RLS every
  table already has. The company's Syla (the `claude` role) reads all
  of it — the trial screen says so plainly.
- **Ask Syla**: `send_to_syla()` is owner-only on a personal install
  (members and guests hold sessions too). On the hosted project the
  vault flag `hosted_trial` widens it to every signed-in profile
  (`20261101000000_hosted_trial.sql`); the event Syla claims is titled
  *Trial message from <email>* so she answers the right person.
- Owner-only surfaces — the Manage page, silos and members, Syla's own
  calendar, settings that touch the project — belong to the hosted
  project's owner account, not to a trial. Trials run into "only the
  owner" refusals there; that is the trial being a trial.

## Running the hosted project (company setup, once)

1. On the company's Supabase account, provision a project exactly as
   the app does for an owner — sign in to the app with that account
   and take the own route once, or `supabase db push` this starter's
   migrations to a project named `sylos`. The app's one-tap provisioner
   reuses an existing project named `sylos`, so a bare project renamed
   to that adopts the schema on the next Connect.
2. Create the **owner** account first (the first sign-up is crowned
   owner); every trial that follows is a plain profile.
3. Wire Syla to the company's Claude (the agent step: routine,
   environment, webhook) — the hosted Syla is a normal Syla.
4. Turn the trial on: `select vault.create_secret('on', 'hosted_trial');`
   in the project's SQL editor. Turn email confirmations off for the
   project (the provisioner does; a hand-made project needs
   *Authentication → Providers → Email → Confirm email* off), or trials
   stall on the confirmation mail.
5. Put the project's URL and publishable key in the app's
   `HostedConfig`; the build then shows the hosted card.

The relay project the app already trusts (`supabase-oauth`, `push-relay`
— [`08-provisioning.md`](08-provisioning.md)) is the natural home: it is
the company's, and it is what `HostedConfig` points at today. It holds
no schema yet — step 1 above is still owed before the first trial can
sign up.

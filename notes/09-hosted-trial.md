# The hosted trial — your database, Sylos's Claude

Onboarding opens on a choice: **set up my own** (the checklist in
[`02-setup.md`](02-setup.md) / [`08-provisioning.md`](08-provisioning.md) —
your Supabase, your Claude, everything yours) or **try hosted Syla**.

Hosted swaps exactly one thing. The person still gets their own
Supabase project, provisioned by the app, with their own account crowned
owner and Syla's rq key in their own vault — every step of the own
route up to the last. Only the Claude account Syla runs on is Sylos's.
Marked *Trial* on every screen, and never meant for the long term.

## What the app does

The checklist is the own one with the agent step swapped: choice →
Supabase account → provision → account → **Syla, hosted**. That last
step, on one tap:

1. Registers the install's environment with the company's main
   Supabase project — project URL, publishable key, rq key —
   ([`sylos-company` `notes/15-sylos-installs.md`](https://github.com/jbnyc55/sylos-company/blob/main/notes/15-sylos-installs.md)).
2. Books a **slot**: one of the routines the company owner pre-made in
   their own Claude Code account ("Syla trial 1" … "5"), each with its
   own environment and API trigger. The booking returns that routine's
   fire URL and bearer token.
3. Stores them in the person's own vault through their project's
   `set_syla_webhook` — the same RPC the own route uses — so their own
   pg_cron dispatcher (`04-syla-jobs.md`) fires the company's routine
   whenever one of their Syla events comes due.
4. The company database texts the owner the install's environment; the
   owner sets it on that routine's environment in Claude Code. Syla
   wakes on the next fire after that, usually within a day.

Every page header, the profile sheet and the hosted step carry the amber
**Trial** badge. **Move to your own Claude** (a profile row that replaces
*Setup* while hosted) brings back just the agent step: the person wires
a routine on their own Claude Code account, and Finish drops the badge
and re-registers the install as `own`, which frees the slot on the
company side and texts the owner to clear its environment.

## What a trial can and cannot do

Everything. It is a real install; Syla simply runs from someone else's
Claude. The one thing to know is on the hosted step's screen: Sylos
holds the project's connection details — Syla's key included — for as
long as the trial lasts, which is the `claude` role on that database.
Moving to their own Claude clears them.

`20261101000000_hosted_trial.sql` (the `hosted_trial()` vault flag that
widened `send_to_syla` to every profile on a shared project) is from an
earlier trial design where trials shared one company database. It is
harmless and unset everywhere; the trial no longer needs it, since the
person is the owner of their own project.

## Running it (company setup)

On the company side — the routines, their environments, Twilio for the
texts, and filling the slots — is in sylos-company's note 15. In this
starter nothing is needed: a hosted install is a plain install.

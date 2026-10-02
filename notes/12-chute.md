# The chute

The middle tab is a promise: **you never file at capture time**. The
page opens on a drawer (auto-opening on launch while
`chute_settings.auto_open` is on — a text toggle in the drawer itself):
a textarea, Camera / Photos / Files / Voice tiles, and one button —
**Drop it**. Everything lands raw; Syla sorts on a schedule; everything
she does is undoable in one tap. `20261124000000_chute.sql` is the
schema.

## Capture → sort → undo → Inbox

1. **Capture.** A drop is a `chute_items` row, `status 'raw'` — text in
   `body`, media as the content-addressed `uploads` row the client
   stores at drop time (`upload_id`). A voice memo is transcribed on
   the phone as it's dropped, the words landing in `body`, so the sort
   reads it like text; photos and files are fetched by the sort through
   `scripts/file-url` (the claude-file edge function's short-lived
   signed link — rq is SQL and cannot carry bytes). The list shows raw
   items as "Dropped — files at the next sort" (captured and waiting;
   nothing reads it before the sort).
2. **Sort.** On the cadence in `chute_settings` — `hourly`, `thrice`
   (the fixed trio 09:00 / 13:00 / 18:00 local), or `daily` at
   `daily_time` (default 15:00) — the dispatcher queues a run of the
   seeded **Chute sort** event *whenever raw items are waiting* (an
   empty chute never wakes anyone) and stamps `last_sorted_at`, the
   cadence latch. The run's instructions are the attached doc
   `syla/chute-sort`; the capability doc is `skills/chute`. Syla files
   each item into its real home through the gated writes she already
   has (doc saves, todo/calendar proposals), then marks the receipt
   with `file_chute_item(_item_id, _filed_to, _filed_locator)` —
   `filed_to` human-readable ("Notes · Gift ideas"), `filed_locator`
   machine-shaped (`docs:<uuid>`).
3. **Undo.** The filed line carries Undo: the owner flips the row back
   to `raw` and clears the filing — one visible write. This is
   **row_edits as UI**: the sort's update carried full before/after
   images, the undo is itself a logged edit, and nothing else is
   needed.
4. **Inbox.** Ambiguity becomes a question, never a guess:
   `ask_chute_question` puts the item at `status 'question'`, which the
   Inbox lists next to the proposal queues. The owner's reply lands in
   `answer`, and the next sort honors it.

The header states the contract: *"Syla sorts at 3:00 PM · Sort now ·
Change"*. **Sort now** is the owner RPC `sort_chute_now()` — queue a
run and fire the webhook inline, `send_to_syla`'s pattern, returning
`{run_id, fired}`. **Change** is a small menu (Hourly / 3× a day /
Once a day at [time]) editing `chute_settings`.

## Dispatch mechanics

The **Chute sort** event is seeded with the other owner defaults
(`seed_owner_defaults`, backfilled for existing installs) so runs have
an event — its doc is the instructions, its history shows in Syla Jobs
— but it is **pre-latched forever** (`last_fired_on = 9999-12-31`): the
dispatcher's generic due-scan never fires it. The chute branch in
`syla_dispatch()` is its only dispatcher, keyed off `chute_settings` +
raw items (`notes/04-syla-jobs.md`). Deleting the event is healed by
the next Sort now; retiming it in the app resets the latch and merely
adds the generic daily firing alongside the cadence.

## Boundaries

- The chute is `system` in the siloing registry: captures are presorted
  private and never placeable — sharing happens, if ever, where the
  item is filed *to*.
- Syla's two verbs (`file_chute_item`, `ask_chute_question`) move only
  `raw` items into `filed` / `question` — structurally, by policy.
  `dismissed` and the undo flip are the owner's verbs alone.
- Filing means the item really landed somewhere first, through the
  same gated writes as always; the chute row only ever holds the
  receipt.

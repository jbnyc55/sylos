-- The race is offered in the SAME conversation as the build.
--
-- 20261228000000 anchored the race offer to the owner's reply to the
-- day-two recap — a day of silence between the payoff and the next
-- beat. Wrong note: the owner is never more sold than the minute they
-- are looking at the app Syla just built, so the offer belongs right
-- there, in the same conversation. The owner's first message after the
-- payoff — "done", a thanks, the approval, anything — gets its answer
-- plus the race offer closing the reply. The recap reply stays only as
-- the FALLBACK moment, for an owner who never replied on day one.
--
-- Guarded swaps on the seeded doc, the house pattern: an owner's own
-- edits survive, re-runs no-op.

-- ── The offer moves to the payoff's next reply ───────────────────────────

update public.docs
set html = replace(html,
    $a$<p>Offer the race only while <code>connections</code> is zero, and only once: before offering, check your own recent lines in the Syla conversation — the database holds them — and never re-offer after a <em>no</em> ("Say <em>set up a race</em> whenever you want it" closes it). The offer, short:</p>$a$,
    $b$<p>The offer belongs in the SAME conversation as the build — don't wait for day two. The owner's first message after the payoff (<em>done</em>, a thanks, a tweak ask, anything) gets its answer, and the race offer closes that same reply; one ask per message holds, because the offer is the reply's only question. Offer only while <code>connections</code> is zero, and only once: before offering, check your own recent lines in the Syla conversation — the database holds them — and never re-offer after a <em>no</em> ("Say <em>set up a race</em> whenever you want it" closes it). The offer, short:</p>$b$)
where path = 'skills/first-run'
  and html not like '%SAME conversation as the build%';

-- ── The recap reply becomes the fallback, not the cue ────────────────────

update public.docs
set html = replace(html,
    $a$<p>The owner's <em>yes</em> or <em>no</em> to the habit is also the race's cue: answer it, and — while <code>followers</code> is still empty — end that same reply with the race offer (the sections below). One ask per message still holds: the habit answer needs no question back, so the race question can close the reply.</p>$a$,
    $b$<p>The habit answer is also the race's FALLBACK cue: normally the race was offered the day before, right after the payoff (the sections below) — but if <code>followers</code> is still empty and your own recent lines show no offer, end this reply with it. One ask per message still holds: the habit answer needs no question back, so the race question can close the reply.</p>$b$)
where path = 'skills/first-run'
  and html not like '%FALLBACK cue%';

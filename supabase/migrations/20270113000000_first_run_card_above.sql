-- The connect card sits above the welcome, not below.
--
-- The app now keeps approval cards in the Syla conversation as history,
-- interleaved with the messages by creation time — and stage one files
-- the card BEFORE sending the welcome, so the card renders just above
-- the message that points at it. The welcome's "right below" was written
-- for the old rendering (pending cards appended under the thread); one
-- word swap keeps the pointer honest. Guarded like every doc edit, so an
-- owner's own rewrite survives and a re-run no-ops.

update public.docs
set html = replace(html,
    'tap <strong>Connect</strong> on the card right below and allow',
    'tap <strong>Connect</strong> on the card right above and allow')
where path = 'skills/first-run'
  and html like '%tap <strong>Connect</strong> on the card right below and allow%';

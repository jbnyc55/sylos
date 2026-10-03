-- A deleted rule is gone — the skill doc catches up with the schema.
--
-- 20261122 was unambiguous: built_in is provenance, never a lock — "the
-- owner may rewrite or even delete it; the undeletable guarantee (asking
-- for the human stops Syla) is platform behavior, not a rule." But the
-- skill seeded in 20261123 told the agent to keep honoring the shipped
-- money/travel/plans rule "even where an owner has deleted the row" —
-- a second, invisible rule list the app never shows. Seen in the field:
-- an owner who had deleted the row was told their reply was checked
-- against it anyway. The doc loses; the schema's contract stands. One
-- guarantee stays above the rules (a message asking for the human), and
-- the built-in rule binds exactly as the owner's list carries it.
--
-- House pattern: targeted, guarded text swaps (20261217).

update public.docs
set html = replace(html,
    'Two guarantees sit above every rule, and no rule edit changes them:',
    'One guarantee sits above every rule, and no rule edit changes it:')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    ' never answer for them), and <strong>never agree to money, travel, or plans with other people</strong> (shipped as the built-in rule; honor it even where an owner has deleted the row).</p>',
    ' never answer for them). Everything else is the owner''s list and nothing but the owner''s list: the shipped built-in rule ("Never agree to money, travel, or plans with other people") is a DON''T REPLY row like any other — active it binds, rewritten it binds as written, and deleted it is gone.</p>')
where path = 'skills/chat-replies';

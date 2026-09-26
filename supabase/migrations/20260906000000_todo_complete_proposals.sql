-- Todo proposals learn a fourth kind: complete — check off one occurrence.
--
-- The owner's jots often describe doing a todo ("ran before work", "meal
-- prepped Sunday night") without the occurrence ever being checked off in
-- the app. The daily routine can now file that observation as a structured
-- proposal: kind 'complete', naming the todo and, in `after`, the day —
-- `{"day": "YYYY-MM-DD"}`. Approving it writes the (todo_id, day) row in
-- todo_done as status 'done', through the owner's own session exactly like
-- the other kinds; the claude role still never touches todo_done.

alter table public.agent_todo_proposals
    drop constraint agent_todo_proposals_kind_check;
alter table public.agent_todo_proposals
    add constraint agent_todo_proposals_kind_check
        check (kind in ('add', 'update', 'retire', 'complete'));

-- The shape each kind requires, extended: complete names its todo and says
-- which day in `after`.
alter table public.agent_todo_proposals
    drop constraint agent_todo_proposals_check;
alter table public.agent_todo_proposals
    add constraint agent_todo_proposals_check check (
        case kind
            when 'add'      then todo_id is null and after is not null
            when 'update'   then todo_id is not null and after is not null
            when 'complete' then todo_id is not null and after is not null
            else                 todo_id is not null
        end
    );

comment on table public.agent_todo_proposals is
    'Structured todo edits proposed by the daily routine (add/update/retire a public.todo row, or complete — check off one occurrence in todo_done), pending until the owner resolves each in the app: approve, deny, or request changes with feedback. The owner''s own session applies approved edits; the claude role only ever inserts proposals (propose_todo_edit()) and revises flagged ones (revise_todo_edit()).';

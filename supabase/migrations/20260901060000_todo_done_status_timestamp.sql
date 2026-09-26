-- completed_at should say when the occurrence got its current status.
--
-- It defaults to now() on insert, but flipping done <-> skipped is an update
-- on the existing row (the client upserts), so the flip kept the timestamp
-- from whichever mark came first. Refresh it whenever status changes; an
-- update that leaves status alone keeps the original moment.

create function public.todo_done_refresh_completed_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
    if new.status is distinct from old.status then
        new.completed_at = now();
    end if;
    return new;
end;
$$;

create trigger todo_done_refresh_completed_at
    before update on public.todo_done
    for each row execute function public.todo_done_refresh_completed_at();

comment on column public.todo_done.completed_at is
    'When the occurrence was given its current status; refreshed on done <-> skipped flips.';

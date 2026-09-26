-- Drop streak_marks: the calendar's crosses are now derived, not hand-marked.
--
-- A day is crossed off when every todo occurring on it is checked off in
-- todo_done (vacuously so when none land on it), so the press-and-hold marks
-- have no meaning left — keeping them would just be a second, disagreeing
-- source of truth. The hand-marked history goes with the table.

drop table public.streak_marks;

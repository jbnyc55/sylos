-- Sharing allowances retire; access groups carry the whole story now.
--
-- 20260830040000 gave each tag a set of onward-sharing destinations
-- (sharing_allowances plus the note_type_allowances junction), picked in
-- the tag modal. Since then the real machinery has converged elsewhere:
-- access groups decide who may read what (allow minus deny tags) and how
-- they may ask (SQL or prompts, 20260901030000). Two vocabularies both
-- claiming to say where content may go is one too many — the tag modal
-- was still offering allowances nothing enforced or read. Both tables go;
-- their policies, grants and "claude reads everything" rows go with them.

drop table public.note_type_allowances;
drop table public.sharing_allowances;

-- Free-form notes on a mind map cell.
--
-- Selecting a cell on the canvas opens a drawer along the bottom of the
-- screen where notes about that cell are typed; they save onto the cell's
-- row. Nullable — most cells will never have any.

alter table public.mind_map_cells
    add column notes text check (char_length(notes) <= 10000);

comment on column public.mind_map_cells.notes is
    'Free-form notes about the cell, edited in the drawer that opens when the cell is selected on the canvas.';

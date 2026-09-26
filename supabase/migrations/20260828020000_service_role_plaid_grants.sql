-- Fix "permission denied for table plaid_item" in the plaid edge function.
--
-- This project grants table privileges explicitly (see 20260816000200), and
-- the plaid migration granted authenticated and revoked claude — but never
-- granted service_role, the role the edge function's admin client runs as.
-- service_role bypasses RLS, but BYPASSRLS does not bypass table privileges,
-- so its first upsert into plaid_item failed before RLS was ever consulted.
-- (Verified against production ACLs: service_role held no DML on either
-- table; schema usage it already has.)

grant select, insert, update, delete on public.plaid_item    to service_role;
grant select, insert, update, delete on public.card_purchase to service_role;

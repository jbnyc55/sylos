-- Calorie and spending logs, plus the tables behind the Plaid card sync.
--
-- Design intent: these are RAW LOGS. Each row is one entry as it happened —
-- free text the user typed, or one card transaction as Plaid reported it.
-- Nothing here aggregates; daily routines will later roll each day's rows up
-- into summaries. So the tables stay generic (a body column, not structured
-- fields) and append-friendly. See notes/08-daily-logs-and-plaid.md.
--
-- Four tables:
--
--   food_log_entry   free-text calorie/food log        — mirrors notes
--   money_entry      free-text purchase/spending log   — mirrors notes
--   plaid_item       one connected bank login (holds the Plaid access token)
--   card_purchase    card transactions synced from Plaid, written server-side

-- ---------------------------------------------------------------------------
-- food_log_entry
-- ---------------------------------------------------------------------------

create table public.food_log_entry (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    body        text not null check (char_length(body) between 1 and 10000),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

comment on table public.food_log_entry is
    'Raw free-text food/calorie log. One entry per row; daily routines aggregate later.';

create index food_log_entry_profile_id_created_at_idx
    on public.food_log_entry (profile_id, created_at desc);

create trigger food_log_entry_set_updated_at
    before update on public.food_log_entry
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- money_entry
-- ---------------------------------------------------------------------------

create table public.money_entry (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    body        text not null check (char_length(body) between 1 and 10000),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

comment on table public.money_entry is
    'Raw free-text money log — purchases, and context for card charges that read confusingly on a statement.';

create index money_entry_profile_id_created_at_idx
    on public.money_entry (profile_id, created_at desc);

create trigger money_entry_set_updated_at
    before update on public.money_entry
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- plaid_item — one connected bank login
-- ---------------------------------------------------------------------------
--
-- access_token is a live credential for the user's bank data. It is written
-- and read ONLY by the plaid edge function using the service role. The
-- browser client may see that a connection exists (id, institution_name,
-- created_at) but never the token — enforced below with column-level grants.

create table public.plaid_item (
    id                uuid primary key default gen_random_uuid(),
    profile_id        uuid not null references public.profiles (id) on delete cascade,
    plaid_item_id     text not null unique,
    access_token      text not null,
    institution_name  text,
    created_at        timestamptz not null default now()
);

comment on table public.plaid_item is
    'A Plaid Item: one bank connection. access_token is service-role only; the client sees only non-sensitive columns.';

create index plaid_item_profile_id_idx on public.plaid_item (profile_id);

-- ---------------------------------------------------------------------------
-- card_purchase — transactions synced from Plaid
-- ---------------------------------------------------------------------------
--
-- Written only by the plaid edge function (service role), which upserts on
-- plaid_transaction_id so re-syncing a day is idempotent. plaid_item_id is
-- set null rather than cascaded on disconnect: the raw log outlives the
-- connection that produced it.

create table public.card_purchase (
    id                    uuid primary key default gen_random_uuid(),
    profile_id            uuid not null references public.profiles (id) on delete cascade,
    plaid_item_id         uuid references public.plaid_item (id) on delete set null,
    plaid_transaction_id  text not null unique,
    account_id            text,
    name                  text not null,
    merchant_name         text,
    amount                numeric(12, 2) not null,
    iso_currency_code     text,
    date                  date not null,
    pending               boolean not null default false,
    created_at            timestamptz not null default now()
);

comment on table public.card_purchase is
    'Raw card transactions synced from Plaid. Amounts follow Plaid convention: positive = money out.';

create index card_purchase_profile_id_date_idx
    on public.card_purchase (profile_id, date desc);

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.food_log_entry enable row level security;
alter table public.money_entry    enable row level security;
alter table public.plaid_item     enable row level security;
alter table public.card_purchase  enable row level security;

-- food_log_entry: fully owned by the profile that created it.
create policy "Food log entries are viewable by their owner"
    on public.food_log_entry for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Food log entries are insertable by their owner"
    on public.food_log_entry for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Food log entries are updatable by their owner"
    on public.food_log_entry for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Food log entries are deletable by their owner"
    on public.food_log_entry for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- money_entry: fully owned by the profile that created it.
create policy "Money entries are viewable by their owner"
    on public.money_entry for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Money entries are insertable by their owner"
    on public.money_entry for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Money entries are updatable by their owner"
    on public.money_entry for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Money entries are deletable by their owner"
    on public.money_entry for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- plaid_item: the owner can see their connections and disconnect them. There
-- is deliberately no insert or update policy — rows are written by the edge
-- function with the service role, which bypasses RLS.
create policy "Plaid items are viewable by their owner"
    on public.plaid_item for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Plaid items are deletable by their owner"
    on public.plaid_item for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- card_purchase: read-only for the owner. Rows arrive via the edge function.
create policy "Card purchases are viewable by their owner"
    on public.card_purchase for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads the logs, like every application table…
create policy "claude reads everything"
    on public.food_log_entry for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.money_entry for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.card_purchase for select
    to claude
    using (true);

-- …but NOT plaid_item. It holds live bank credentials. No policy is added,
-- and the SELECT privilege that arrived via default privileges (see
-- 20260816000300) is revoked outright, so both gates are closed.
revoke select on public.plaid_item from claude;

-- ---------------------------------------------------------------------------
-- Privileges — mirror the policies exactly (see 20260816000200)
-- ---------------------------------------------------------------------------

grant select, insert, update, delete on public.food_log_entry to authenticated;
grant select, insert, update, delete on public.money_entry    to authenticated;

-- plaid_item: column-level select keeps access_token out of reach even though
-- the RLS policy would let the owner see their own row.
grant select (id, profile_id, institution_name, created_at) on public.plaid_item to authenticated;
grant delete on public.plaid_item to authenticated;

grant select on public.card_purchase to authenticated;

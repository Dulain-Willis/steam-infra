-- Migration for an already-bootstrapped DB that predates client_events in
-- db/schema.sql (steam-analytics#12). Fresh bootstraps get the table from
-- schema.sql and can skip this file.
--
-- The Debezium connector runs snapshot.mode: always with no persisted
-- offsets (#27), so the next connector restart snapshots the new table and
-- it lands in the Snowflake VARIANT payload. The connector's
-- table.include.list must also name public.client_events
-- (k8s/kafka/debezium-connector.yaml) — re-apply it after this migration.
--
-- Apply through the SSM tunnel (see docs/rds-bootstrap.md):
--
--   PGPASSWORD=$(tofu -chdir=terraform output -raw db_password) \
--     psql -h localhost -p 15432 -U steam_proj_admin -d steam \
--     -v ON_ERROR_STOP=1 -f db/migrations/0002_client_events.sql
--
-- Safe to re-run.

create table if not exists client_events (
    event_id uuid primary key default gen_random_uuid(),
    occurred_at timestamptz not null,
    user_id uuid not null references users(id),
    session_id uuid,
    game_id uuid references games(id),
    event_name text not null check (event_name in (
        'store_page_view', 'game_page_view', 'add_to_wishlist', 'begin_checkout', 'purchase_complete')),
    props jsonb not null default '{}',
    recorded_at timestamptz not null default now()
);
create index if not exists client_events_user_id_idx on client_events (user_id);
create index if not exists client_events_session_id_idx on client_events (session_id);

-- Migration for an already-bootstrapped DB that predates users.campaign_id in
-- db/schema.sql (steam-analytics#14). Fresh bootstraps get the column from
-- schema.sql and can skip this file.
--
-- First-touch signup attribution: nullable FK to marketing_campaigns, set once
-- at account creation, never re-attributed. NULL = organic/direct. Existing
-- rows keep campaign_id = NULL (no backfill — pre-migration signups have no
-- captured first touch).
--
-- Column reaches Snowflake without a connector change: users is already in the
-- Debezium capture list and the Snowflake sink uses RECORD_CONTENT (VARIANT),
-- so new source columns appear on the next full snapshot. The connector runs
-- snapshot.mode: always with no persisted offsets (#27), so a connector
-- restart re-snapshots every users row with the new column.
--
-- Apply through the SSM tunnel (see docs/rds-bootstrap.md):
--
--   PGPASSWORD=$(tofu -chdir=terraform output -raw db_password) \
--     psql -h localhost -p 15432 -U steam_proj_admin -d steam \
--     -v ON_ERROR_STOP=1 -f db/migrations/0003_users_campaign_id.sql
--
-- Safe to re-run.

alter table users add column if not exists campaign_id uuid;

do $$
begin
    if not exists (
        select 1 from pg_constraint where conname = 'users_campaign_id_fkey'
    ) then
        alter table users add constraint users_campaign_id_fkey
            foreign key (campaign_id) references marketing_campaigns(id);
    end if;
end $$;

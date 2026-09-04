-- Migration for an already-bootstrapped DB that predates users.country in
-- db/schema.sql (steam-analytics#11). Fresh bootstraps get the column from
-- schema.sql and can skip this file.
--
-- Existing rows keep country = NULL. The Debezium connector runs
-- snapshot.mode: always with no persisted offsets (#27), so the next
-- connector restart re-snapshots every users row with the new column and it
-- lands in the Snowflake VARIANT payload. No data backfill needed here.
--
-- Apply through the SSM tunnel (see docs/rds-bootstrap.md):
--
--   PGPASSWORD=$(tofu -chdir=terraform output -raw db_password) \
--     psql -h localhost -p 15432 -U steam_proj_admin -d steam \
--     -v ON_ERROR_STOP=1 -f db/migrations/0001_users_country.sql
--
-- Safe to re-run.

alter table users add column if not exists country text;

# The pipeline's databases. STEAM_RAW holds the CDC landing tables;
# STEAM_STAGING and STEAM_PROD hold staging's and prod's dbt builds.
# STEAM_PROJECT, the single database these replace, is
# gone — a rename on next bring-up rather than a migration, because there is no
# long-lived data here (#112's Implementation Decisions).
#
# The names are also lib/env.sh's SNOWFLAKE_RAW_DATABASE,
# SNOWFLAKE_STAGING_DATABASE and SNOWFLAKE_PROD_DATABASE, which bash and
# Python read; bring-up's verify step
# queries Snowflake for those names, so a drift between the two fails loudly
# rather than silently.

resource "snowflake_database" "raw" {
  name    = "STEAM_RAW"
  comment = "CDC landing tables, written only by the Kafka sink (managed by terraform/snowflake)"
  # Landing tables live in a schema named after the source system, not PUBLIC.
  drop_public_schema_on_creation = true
}

# The Snowflake sink auto-creates its *tables* on the first record of a topic
# but never the schema, so this has to exist before Stage 5 deploys the
# connector. STEAM_RDS names the source system — the `steam` Postgres database
# on RDS that Debezium captures — so a second source system lands in its own
# schema rather than mixing into this one.
resource "snowflake_schema" "source_system" {
  database = snowflake_database.raw.name
  name     = "STEAM_RDS"
  comment  = "landing tables from the steam RDS Postgres database, via Debezium"
}

# Staging is a faithful copy of prod's layout — the same bare layer schema
# names, created by dbt itself — in its own database, so a staging run cannot
# touch prod's tables even if it builds the same model. PUBLIC is kept for the
# same reason as STEAM_DEV's: it is the one schema that exists before any dbt
# run, which is what bring-up's grant check writes its probe table in.
resource "snowflake_database" "staging" {
  name    = "STEAM_STAGING"
  comment = "staging dbt build — stg, int, marts_* (managed by terraform/snowflake)"
}

resource "snowflake_database" "prod" {
  name    = "STEAM_PROD"
  comment = "prod dbt build — stg, int, marts_* (managed by terraform/snowflake)"
}

# Every developer's and every PR's dbt build, separated by a schema prefix
# rather than by database: dbt_<name>_stg and ci_pr_<N>_stg, from
# steam-analytics' generate_schema_name macro. dbt creates those schemas
# itself, so nothing here enumerates them — and teardown drops the database,
# which takes every developer and CI schema with it.
#
# PUBLIC is kept (unlike STEAM_RAW): it is the one schema that exists before
# any dbt run, which is what bring-up's grant check writes its probe table in.
resource "snowflake_database" "dev" {
  name    = "STEAM_DEV"
  comment = "developer and CI dbt builds — dbt_<name>_* and ci_pr_<N>_* (managed by terraform/snowflake)"
}

# The whole pipeline is UTC: db/schema.sql's convention line is "timestamps:
# timestamptz UTC", Postgres stores timestamptz, and Debezium emits UTC. The
# Snowflake sink lands those as TIMESTAMP_NTZ holding the UTC wall clock, so
# a TIMESTAMP_NTZ -> TIMESTAMP_TZ cast in the staging layer attaches whatever
# the SESSION timezone is. Snowflake's default is America/Los_Angeles, which
# silently skewed every such cast by the UTC offset.
#
# That was not theoretical. On the #129 bring-up it made
# fct_playtime_sessions.duration_minutes negative (a session running
# 21:44 -> 21:59 measured as -405 minutes: +15 with a 420-minute offset
# subtracted) and failed both
# assert_fct_product_session_length_daily_non_negative and
# assert_fct_wishlist_items_removed_after_added. It only showed up on the
# columns where a TIMESTAMP_NTZ value is compared against one the sink typed
# as TEXT -- a nullable timestamp whose first observed value is null gets
# schematized as TEXT, and its ISO-8601 'Z' strings parse as genuine UTC --
# so the two sides of the comparison disagreed by the session offset.
#
# Setting the account to UTC makes the cast mean what the data means. It is
# set here rather than left to each session so a fresh bring-up and every
# identity (loader, both transformers, CI, developers, ad-hoc queries) agree
# without anyone having to remember.
resource "snowflake_account_parameter" "timezone" {
  key   = "TIMEZONE"
  value = "UTC"
}

# The pipeline's databases. STEAM_RAW holds the CDC landing tables; STEAM_PROD
# holds prod's dbt build. STEAM_PROJECT, the single database these replace, is
# gone — a rename on next bring-up rather than a migration, because there is no
# long-lived data here (#112's Implementation Decisions).
#
# The names are also lib/env.sh's SNOWFLAKE_RAW_DATABASE and
# SNOWFLAKE_PROD_DATABASE, which bash and Python read; bring-up's verify step
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

resource "snowflake_database" "prod" {
  name    = "STEAM_PROD"
  comment = "prod dbt build — stg, int, marts_* (managed by terraform/snowflake)"
}

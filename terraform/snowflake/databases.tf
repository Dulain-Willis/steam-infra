# The pipeline's one database. #114 splits this into STEAM_RAW + STEAM_PROD
# and adds roles, service users and grants alongside it.
#
# The name is also lib/env.sh's SNOWFLAKE_DATABASE, which bash and Python
# read; bring-up's verify step queries Snowflake for that name, so a drift
# between the two fails loudly rather than silently.
resource "snowflake_database" "steam_project" {
  name    = "STEAM_PROJECT"
  comment = "steam-infra pipeline database (managed by terraform/snowflake)"
}

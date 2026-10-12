# Who may do what in Snowflake. One role per job, one service user per role,
# and a key pair per service user generated here rather than by hand — so keys
# rotate on every bring-up and never exist outside tofu state and the
# Kubernetes Secrets bring-up copies them into (#112 story 39).
#
# | Role             | Reads     | Writes     |
# |------------------|-----------|------------|
# | LOADER           | —         | STEAM_RAW  |
# | TRANSFORMER_PROD | STEAM_RAW | STEAM_PROD |
#
# Nothing in the pipeline runs as ACCOUNTADMIN any more. Tofu's own provider
# identity still does, because something has to create roles and users at
# bootstrap — see versions.tf.
#
# Reads use *both* an `all` and a `future` grant: `all` covers what exists at
# apply time, `future` covers the schemas and tables the sink and dbt create
# afterwards. Neither alone is enough.
#
# The `all`-schemas grants carry an explicit depends_on for the landing schema.
# Without it they are siblings of snowflake_schema.source_system in the graph,
# all depending only on the database, so tofu may run them concurrently — and
# `GRANT ... ON ALL SCHEMAS` is evaluated once, at execution time, while a
# future grant only applies to schemas created after it. The interleaving
# "all-grant runs → schema is created → future-grant runs" leaves STEAM_RDS
# with neither, and the provider does no drift detection on `all`-grants, so a
# second apply would not heal it. Ordering the schema first makes `all` always
# cover it; the future grants need no edge, since a schema created before them
# is covered by `all` and one created after is covered by them.

locals {
  # The account's only warehouse.
  warehouse = "COMPUTE_WH"

  # Every role that runs SQL needs USAGE on it. Add roles here as later
  # tickets add them (#115 DEVELOPER, #116 CI, #119 TRANSFORMER_STAGING).
  compute_roles = [
    snowflake_account_role.loader.name,
    snowflake_account_role.transformer_prod.name,
  ]

  # One service user per non-human identity. Each gets exactly one role, a
  # tofu-generated key pair, and a pair of outputs (<key>_user,
  # <key>_private_key) for bring-up to copy into a Kubernetes Secret.
  service_users = {
    loader = {
      name    = "STEAM_LOADER_SVC"
      role    = snowflake_account_role.loader.name
      comment = "Kafka Snowflake sink — lands CDC tables in STEAM_RAW"
    }
    prod_airflow = {
      name    = "STEAM_PROD_SVC"
      role    = snowflake_account_role.transformer_prod.name
      comment = "prod Airflow — runs dbt into STEAM_PROD"
    }
  }
}

resource "snowflake_account_role" "loader" {
  name    = "LOADER"
  comment = "writes CDC landing tables into STEAM_RAW; reads nothing"
}

resource "snowflake_account_role" "transformer_prod" {
  name    = "TRANSFORMER_PROD"
  comment = "reads STEAM_RAW, writes only STEAM_PROD"
}

resource "snowflake_grant_privileges_to_account_role" "warehouse" {
  for_each          = toset(local.compute_roles)
  account_role_name = each.value
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "WAREHOUSE"
    object_name = local.warehouse
  }
}

# --- LOADER: write STEAM_RAW -------------------------------------------------
#
# The sink creates each landing table on that topic's first record and then
# evolves its columns, which it can do because it owns them. It needs USAGE on
# the database and schema and CREATE TABLE on the schema to get started.
#
# CREATE PIPE as well, because this is the Snowpipe Streaming *v2*
# (high-performance) client — k8s/kafka/connect/kafka-connect.yaml names it,
# and that architecture provisions a pipe per table. docs/debezium-postgres-config.md
# records the bootstrap signature: the shared client calls `get_pipe_info` for
# every topic2table-mapped table before its own auto-create runs, and fails the
# task with `ERR_TABLE_DOES_NOT_EXIST_NOT_AUTHORIZED`. Under the old
# ACCOUNTADMIN the NOT_AUTHORIZED half of that was unreachable, so the previous
# setup proves nothing about the minimal grant set. Without this the sink would
# fail in Stage 5, twenty minutes of EKS build after a Stage 2 that passed.

resource "snowflake_grant_privileges_to_account_role" "loader_raw_database" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.raw.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "loader_raw_schemas" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE PIPE"]
  depends_on        = [snowflake_schema.source_system]

  on_schema {
    all_schemas_in_database = snowflake_database.raw.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "loader_raw_future_schemas" {
  account_role_name = snowflake_account_role.loader.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE PIPE"]

  on_schema {
    future_schemas_in_database = snowflake_database.raw.name
  }
}

# --- TRANSFORMER_PROD: read STEAM_RAW ---------------------------------------
#
# Only TABLES, no VIEWS: STEAM_RAW holds nothing but sink-created tables.

resource "snowflake_grant_privileges_to_account_role" "prod_raw_database" {
  account_role_name = snowflake_account_role.transformer_prod.name
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.raw.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "prod_raw_schemas" {
  account_role_name = snowflake_account_role.transformer_prod.name
  privileges        = ["USAGE"]
  depends_on        = [snowflake_schema.source_system]

  on_schema {
    all_schemas_in_database = snowflake_database.raw.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "prod_raw_future_schemas" {
  account_role_name = snowflake_account_role.transformer_prod.name
  privileges        = ["USAGE"]

  on_schema {
    future_schemas_in_database = snowflake_database.raw.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "prod_raw_tables" {
  account_role_name = snowflake_account_role.transformer_prod.name
  privileges        = ["SELECT"]

  on_schema_object {
    all {
      object_type_plural = "TABLES"
      in_database        = snowflake_database.raw.name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "prod_raw_future_tables" {
  account_role_name = snowflake_account_role.transformer_prod.name
  privileges        = ["SELECT"]

  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_database        = snowflake_database.raw.name
    }
  }
}

# --- TRANSFORMER_PROD: write STEAM_PROD -------------------------------------
#
# dbt creates the layer schemas (stg, int, marts_*, elementary) itself, so it
# needs CREATE SCHEMA on the database; it owns what it creates. The schema-level
# grants cover schemas it did not create, PUBLIC included.

resource "snowflake_grant_privileges_to_account_role" "prod_database" {
  account_role_name = snowflake_account_role.transformer_prod.name
  privileges        = ["USAGE", "CREATE SCHEMA"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.prod.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "prod_schemas" {
  account_role_name = snowflake_account_role.transformer_prod.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE VIEW"]

  on_schema {
    all_schemas_in_database = snowflake_database.prod.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "prod_future_schemas" {
  account_role_name = snowflake_account_role.transformer_prod.name
  privileges        = ["USAGE", "CREATE TABLE", "CREATE VIEW"]

  on_schema {
    future_schemas_in_database = snowflake_database.prod.name
  }
}

# --- Service users ----------------------------------------------------------

resource "tls_private_key" "service_user" {
  for_each  = local.service_users
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "snowflake_service_user" "this" {
  for_each          = local.service_users
  name              = each.value.name
  comment           = each.value.comment
  default_role      = each.value.role
  default_warehouse = local.warehouse

  # Snowflake's RSA_PUBLIC_KEY must be one line with no PEM header or trailer.
  # tls_private_key.public_key_pem is X.509/SubjectPublicKeyInfo, which is the
  # right key format once stripped.
  rsa_public_key = replace(tls_private_key.service_user[each.key].public_key_pem, "/-----[A-Z ]+-----|\\n/", "")
}

# default_role only sets the session default; the role still has to be granted.
resource "snowflake_grant_account_role" "service_user" {
  for_each  = local.service_users
  role_name = each.value.role
  user_name = snowflake_service_user.this[each.key].name
}

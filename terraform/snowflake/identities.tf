# Who may do what in Snowflake. One role per job, one service user per role,
# and a key pair per service user generated here rather than by hand — so keys
# rotate on every bring-up and never exist outside tofu state and the
# Kubernetes Secrets bring-up copies them into (#112 story 39).
#
# | Role                | Reads                  | Writes        |
# |---------------------|------------------------|---------------|
# | LOADER              | —                      | STEAM_RAW     |
# | TRANSFORMER_STAGING | STEAM_RAW              | STEAM_STAGING |
# | TRANSFORMER_PROD    | STEAM_RAW              | STEAM_PROD    |
# | DEVELOPER           | STEAM_RAW              | STEAM_DEV     |
# | CI                  | STEAM_RAW, STEAM_PROD  | STEAM_DEV     |
#
# Each transformer writes exactly one build database and has no grant at all
# on the other's, which is what makes "a bad staging run cannot damage prod"
# (#112 story 24) provable by bring-up's grant check rather than asserted.
#
# DEVELOPER has no grant whatsoever on STEAM_PROD, not even read, and CI does
# have one — that asymmetry is the whole of #112's Q1. Slim CI runs
# `dbt build --select state:modified+ --defer`, which resolves an unselected
# ref() to the relation the prod-state manifest records, so the identity
# running CI must be able to SELECT STEAM_PROD. A developer runs a full build
# into their own schemas with no --defer and needs no such read, and not
# granting it is what makes "a dev build changes nothing in STEAM_PROD"
# provable by bring-up's grant check rather than asserted.
#
# CI is the only role that *reads a build database it must not write*. Both
# halves are checked, and by different means: the write denial is a row in
# bring-up's GRANT_CASES table, which only ever probes writes, and the read is
# a separate grant_handoff_check (TRANSFORMER_PROD writes, CI reads).
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

  # Every role that runs SQL needs USAGE on it.
  compute_roles = [
    snowflake_account_role.loader.name,
    snowflake_account_role.transformer_staging.name,
    snowflake_account_role.transformer_prod.name,
    snowflake_account_role.developer.name,
    snowflake_account_role.ci.name,
  ]

  # var.developers keyed by name, for the for_each'd user and role grant.
  developers = { for developer in var.developers : developer.name => developer }

  # Roles that read the landing tables in STEAM_RAW. Every environment's dbt
  # build does, with the same grants, so this is a list rather than a block
  # per role. CI is in it because a slim build's stg layer still selects from
  # the sources: only *unselected* refs defer, and a source is never a ref.
  raw_readers = [
    snowflake_account_role.transformer_staging.name,
    snowflake_account_role.transformer_prod.name,
    snowflake_account_role.developer.name,
    snowflake_account_role.ci.name,
  ]

  # Which database each role builds into, same idea. DEVELOPER and CI both
  # write STEAM_DEV: two roles on one database is fine, because what keeps a
  # developer's schemas and a PR's apart is the schema prefix, not a grant.
  build_databases = {
    (snowflake_account_role.transformer_staging.name) = snowflake_database.staging.name
    (snowflake_account_role.transformer_prod.name)    = snowflake_database.prod.name
    (snowflake_account_role.developer.name)           = snowflake_database.dev.name
    (snowflake_account_role.ci.name)                  = snowflake_database.dev.name
  }

  # One service user per non-human identity. Each gets exactly one role, a
  # tofu-generated key pair, and a pair of outputs (<key>_user,
  # <key>_private_key) for bring-up to copy into a Kubernetes Secret.
  service_users = {
    loader = {
      name    = "STEAM_LOADER_SVC"
      role    = snowflake_account_role.loader.name
      comment = "Kafka Snowflake sink — lands CDC tables in STEAM_RAW"
    }
    staging_airflow = {
      name    = "STEAM_STAGING_SVC"
      role    = snowflake_account_role.transformer_staging.name
      comment = "staging Airflow — runs dbt into STEAM_STAGING"
    }
    prod_airflow = {
      name    = "STEAM_PROD_SVC"
      role    = snowflake_account_role.transformer_prod.name
      comment = "prod Airflow — runs dbt into STEAM_PROD"
    }
    # The only one of these whose key leaves the cluster: bring-up pushes it
    # to steam-analytics' GitHub secrets (Stage 2), because GitHub Actions is
    # where CI runs. Giving CI its own identity is what keeps the prod and
    # staging keys out of GitHub entirely (#112's Q2) — before this, CI ran as
    # whatever identity the SNOWFLAKE_* secrets happened to name.
    #
    # The STEAM_ prefix is load-bearing: lib/env.sh matches project users by
    # STEAM\_%, so teardown proves this user is gone with no second signal.
    ci = {
      name    = "STEAM_CI_SVC"
      role    = snowflake_account_role.ci.name
      comment = "steam-analytics GitHub Actions — dbt into STEAM_DEV CI schemas, reads STEAM_PROD for slim-CI deferral"
    }
  }
}

resource "snowflake_account_role" "loader" {
  name    = "LOADER"
  comment = "writes CDC landing tables into STEAM_RAW; reads nothing"
}

resource "snowflake_account_role" "transformer_staging" {
  name    = "TRANSFORMER_STAGING"
  comment = "reads STEAM_RAW, writes only STEAM_STAGING"
}

resource "snowflake_account_role" "transformer_prod" {
  name    = "TRANSFORMER_PROD"
  comment = "reads STEAM_RAW, writes only STEAM_PROD"
}

resource "snowflake_account_role" "developer" {
  name    = "DEVELOPER"
  comment = "reads STEAM_RAW, writes only STEAM_DEV; no grant on STEAM_STAGING or STEAM_PROD"
}

resource "snowflake_account_role" "ci" {
  name    = "CI"
  comment = "reads STEAM_RAW and STEAM_PROD, writes only STEAM_DEV; no grant on STEAM_STAGING"
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

# --- Reading STEAM_RAW: the transformers and DEVELOPER ----------------------
#
# Every environment's dbt build reads the same landing tables, and the grant
# set is identical for each, so the readers are a list — #116 adds CI and
# needs no new resource.
#
# Only TABLES, no VIEWS: STEAM_RAW holds nothing but sink-created tables.

resource "snowflake_grant_privileges_to_account_role" "raw_reader_database" {
  for_each          = toset(local.raw_readers)
  account_role_name = each.value
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.raw.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "raw_reader_schemas" {
  for_each          = toset(local.raw_readers)
  account_role_name = each.value
  privileges        = ["USAGE"]
  depends_on        = [snowflake_schema.source_system]

  on_schema {
    all_schemas_in_database = snowflake_database.raw.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "raw_reader_future_schemas" {
  for_each          = toset(local.raw_readers)
  account_role_name = each.value
  privileges        = ["USAGE"]

  on_schema {
    future_schemas_in_database = snowflake_database.raw.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "raw_reader_tables" {
  for_each          = toset(local.raw_readers)
  account_role_name = each.value
  privileges        = ["SELECT"]

  on_schema_object {
    all {
      object_type_plural = "TABLES"
      in_database        = snowflake_database.raw.name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "raw_reader_future_tables" {
  for_each          = toset(local.raw_readers)
  account_role_name = each.value
  privileges        = ["SELECT"]

  on_schema_object {
    future {
      object_type_plural = "TABLES"
      in_database        = snowflake_database.raw.name
    }
  }
}

# --- Writing a build database: the transformers and DEVELOPER ---------------
#
# dbt creates its own schemas — the layer schemas in STEAM_STAGING and
# STEAM_PROD, a developer's dbt_<name>_* ones in STEAM_DEV — so CREATE SCHEMA
# on the database is the
# load-bearing grant; it owns what it creates. The schema-level grants cover
# schemas it did not create: PUBLIC, and in STEAM_DEV a teammate's.
#
# Developers deliberately share one role rather than getting one each: that
# database is a shared sandbox, and the schema prefix, not a grant, is what
# keeps two developers out of each other's tables.

resource "snowflake_grant_privileges_to_account_role" "build_database" {
  for_each          = local.build_databases
  account_role_name = each.key
  privileges        = ["USAGE", "CREATE SCHEMA"]

  on_account_object {
    object_type = "DATABASE"
    object_name = each.value
  }
}

resource "snowflake_grant_privileges_to_account_role" "build_schemas" {
  for_each          = local.build_databases
  account_role_name = each.key
  privileges        = ["USAGE", "CREATE TABLE", "CREATE VIEW"]

  on_schema {
    all_schemas_in_database = each.value
  }
}

resource "snowflake_grant_privileges_to_account_role" "build_future_schemas" {
  for_each          = local.build_databases
  account_role_name = each.key
  privileges        = ["USAGE", "CREATE TABLE", "CREATE VIEW"]

  on_schema {
    future_schemas_in_database = each.value
  }
}

# --- CI: read STEAM_PROD, for slim-CI deferral -------------------------------
#
# The one grant with no existing list to join, because CI is the only role that
# reads a build database it does not write (#112's Q1/Q2). Everything else here
# either writes the database it reads or reads only STEAM_RAW.
#
# VIEWS as well as TABLES, and that is not belt-and-braces: the stg and int
# layers are materialized as views, so a tables-only grant would let slim CI
# defer to a mart and fail on anything upstream of one. Each is a separate
# `object_type_plural`, hence the for_each over the pair rather than two
# near-identical blocks.
#
# No depends_on here, unlike the STEAM_RAW reads: nothing in this module
# creates a schema in STEAM_PROD, so there is no apply-time race between an
# `all` grant and a schema's creation. Every schema CI reads is made by prod's
# dbt long after the apply, which is what the `future` grants are for — the
# `all` ones cover PUBLIC and, on a re-apply, whatever dbt has built since.
#
# There is deliberately no equivalent block for STEAM_STAGING: CI has no grant
# of any kind on it, and bring-up's deny row proves that.

resource "snowflake_grant_privileges_to_account_role" "ci_prod_database" {
  account_role_name = snowflake_account_role.ci.name
  privileges        = ["USAGE"]

  on_account_object {
    object_type = "DATABASE"
    object_name = snowflake_database.prod.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "ci_prod_schemas" {
  account_role_name = snowflake_account_role.ci.name
  privileges        = ["USAGE"]

  on_schema {
    all_schemas_in_database = snowflake_database.prod.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "ci_prod_future_schemas" {
  account_role_name = snowflake_account_role.ci.name
  privileges        = ["USAGE"]

  on_schema {
    future_schemas_in_database = snowflake_database.prod.name
  }
}

resource "snowflake_grant_privileges_to_account_role" "ci_prod_objects" {
  for_each          = toset(["TABLES", "VIEWS"])
  account_role_name = snowflake_account_role.ci.name
  privileges        = ["SELECT"]

  on_schema_object {
    all {
      object_type_plural = each.value
      in_database        = snowflake_database.prod.name
    }
  }
}

resource "snowflake_grant_privileges_to_account_role" "ci_prod_future_objects" {
  for_each          = toset(["TABLES", "VIEWS"])
  account_role_name = snowflake_account_role.ci.name
  privileges        = ["SELECT"]

  on_schema_object {
    future {
      object_type_plural = each.value
      in_database        = snowflake_database.prod.name
    }
  }
}

# --- Developer users --------------------------------------------------------
#
# snowflake_user, not snowflake_service_user: the v2 provider split the two,
# and the service variant has no password or MFA surface and cannot log into
# the UI — which is right for the pipeline's identities and wrong for a human.
#
# The operator's entry creates STEAM_DEV_DULAIN rather than adopting their
# existing DULAIN user, for three reasons. Adopting it would mean tofu
# managing the account's ACCOUNTADMIN human: `tofu destroy` — which teardown
# runs every session — would delete the user tofu itself authenticates as,
# locking the operator out of their own account with no way back in. It would
# also need an import before the first apply, and it would leave the operator
# developing as ACCOUNTADMIN, which is exactly what #112 is removing. The new
# user carries the operator's *existing* public key, so nothing new has to be
# generated or distributed and their current private key authenticates as
# either user.
#
# The STEAM_ prefix is also load-bearing: lib/env.sh's inventory matches
# project users by STEAM\_%, so teardown proves these are gone without a
# second signal, while the operator's own DULAIN stays out of it.

resource "snowflake_user" "developer" {
  for_each          = local.developers
  name              = "STEAM_DEV_${upper(each.key)}"
  comment           = "developer ${each.key} — runs dbt into their own schemas in STEAM_DEV"
  default_role      = snowflake_account_role.developer.name
  default_warehouse = local.warehouse

  # One line, no PEM header or trailer — same requirement and same expression
  # as the service users below, so either form can be pasted into
  # var.developers.
  rsa_public_key = replace(each.value.rsa_public_key, "/-----[A-Z ]+-----|\\n/", "")
}

resource "snowflake_grant_account_role" "developer" {
  for_each  = local.developers
  role_name = snowflake_account_role.developer.name
  user_name = snowflake_user.developer[each.key].name
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

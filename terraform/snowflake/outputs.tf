# Service-user credentials, read by bring-up with
# `tofu -chdir=terraform/snowflake output -raw <name>` and copied into
# Kubernetes Secrets (scripts/bringup/stages/05-cluster.sh). They rotate on
# every bring-up, which is the point.
#
# The private keys are PKCS#8 PEM, headers and newlines included
# (private_key_pem_pkcs8, *not* private_key_pem, which is PKCS#1): that is the
# only form dbt-snowflake accepts, and snowflake-connector-python reads it too.
# The Kafka sink is the one consumer that wants it header-stripped on a single
# line, and 05-cluster.sh does that stripping at the one place it's needed.
#
# `output -raw` prints the value unquoted and unescaped, so a `$(...)` capture
# in bash gets the PEM verbatim. Never read these through run_step — it hides
# stdout.

output "loader_user" {
  description = "Service user the Kafka Snowflake sink authenticates as"
  value       = snowflake_service_user.this["loader"].name
}

output "loader_private_key" {
  description = "PKCS#8 PEM private key for the loader service user"
  value       = tls_private_key.service_user["loader"].private_key_pem_pkcs8
  sensitive   = true
}

# The operator's developer user. There is no matching _private_key output:
# this user carries the operator's own public key, so tofu never holds the
# private half — bring-up's grant check reads it from .env instead
# (grant_check_local_key in scripts/lib/grant_check.sh).
output "operator_developer_user" {
  description = "Snowflake user for the first entry in var.developers, the operator"
  value       = snowflake_user.developer[var.developers[0].name].name
}

output "prod_airflow_user" {
  description = "Service user prod Airflow runs dbt as"
  value       = snowflake_service_user.this["prod_airflow"].name
}

output "prod_airflow_private_key" {
  description = "PKCS#8 PEM private key for the prod Airflow service user"
  value       = tls_private_key.service_user["prod_airflow"].private_key_pem_pkcs8
  sensitive   = true
}

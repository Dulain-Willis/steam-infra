# Supplied as TF_VAR_* by scripts/lib/env.sh from .env. The v2 provider wants
# the account identifier split in two; .env keeps the combined
# <ORG>-<ACCOUNT> form as well, because the Python connector and dbt want it.

variable "organization_name" {
  description = "Snowflake organization name, e.g. FMBSGSW"
  type        = string
}

variable "account_name" {
  description = "Snowflake account name within the organization, e.g. YU41950"
  type        = string
}

variable "user" {
  description = "Snowflake user tofu authenticates as (must hold ACCOUNTADMIN)"
  type        = string
}

variable "private_key_path" {
  description = "Path to that user's unencrypted PKCS#8 RSA private key (PEM)"
  type        = string
}

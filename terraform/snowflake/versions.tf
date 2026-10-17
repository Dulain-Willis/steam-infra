terraform {
  required_providers {
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.0"
    }
    # Generates the service users' RSA key pairs (#114). The private keys only
    # ever exist in this module's state, which the S3 backend encrypts.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  required_version = ">= 1.12"
}

# Key-pair auth as the bootstrap identity. ACCOUNTADMIN is hardcoded on
# purpose: something has to be able to create databases (and, from #114,
# roles and users), and that is the only role in the account at bootstrap.
# It is deliberately NOT read from lib/env.sh's SNOWFLAKE_ROLE, which
# becomes a per-environment runtime role rather than tofu's own identity.
provider "snowflake" {
  organization_name = var.organization_name
  account_name      = var.account_name
  user              = var.user
  authenticator     = "SNOWFLAKE_JWT"
  private_key       = file(var.private_key_path)
  role              = "ACCOUNTADMIN"
}

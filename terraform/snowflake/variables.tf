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

# Onboarding a teammate is one entry here (#112 story 40). Each gets a
# Snowflake user STEAM_DEV_<NAME> holding the DEVELOPER role: reads STEAM_RAW,
# writes STEAM_DEV, nothing at all in STEAM_STAGING or STEAM_PROD.
#
# The key is theirs, not tofu's: a human's key pair should outlive a bring-up
# and stay in their own hands, so only the public half is declared here — and a
# public key is not a secret, which is what makes a new developer a one-line
# diff with no file juggling. They generate it with
#
#   openssl genrsa 2048 | openssl pkcs8 -topk8 -nocrypt -out ~/.dbt/snowflake_key.p8
#   openssl rsa -in ~/.dbt/snowflake_key.p8 -pubout | grep -v '^-----' | tr -d '\n'
#
# and the second line's output goes in rsa_public_key (the full PEM is also
# accepted — the resource strips headers and newlines).
#
# The first entry is the operator's, and it deliberately does NOT adopt their
# existing ACCOUNTADMIN user: see the snowflake_user.developer comment in
# identities.tf.
variable "developers" {
  description = "Developers who get a Snowflake user with the DEVELOPER role; the first entry is the operator"
  type = list(object({
    name           = string
    rsa_public_key = string
  }))

  default = [
    {
      name = "dulain"
      # The public half of steam-infra's .secrets/snowflake_key.p8, i.e. the
      # key already registered on the operator's own Snowflake user — so
      # their existing .env key authenticates as STEAM_DEV_DULAIN too, and
      # bring-up's grant check can run as it without a new key to distribute.
      rsa_public_key = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuAk0daRKYu5FLR5lDlH7CTp/vEKPsI6Z22OmtPsAAt7xz4m6pjIp7V4qMeqali+Kwfe+eSMkg9YSF/KwhSW59S6JSXZtxzUmeLIfNZXX4hlijO3YMeR1t6x55NvkJRm5nKLLn79G8T59PP4uRSHt/HGE33+Mr82bF7GrhvonIWK3n/3hUnjLc7eIq3m1fj2+MRrtJtR/29xw6mPabt7ipLovIQUAlcwpl/RJ0/h2deOWdRgqcIbFtsw1IE9dL8g8QmV0hv4VHfeBs78OkwJn1hqtKV0eYGVbtGyw7LW98I1Wy6EHPL6G+DA+e7NONhKOdZ7X5fOmV0ADcGYLb6JXkQIDAQAB"
    },
  ]

  validation {
    condition     = length(var.developers) > 0
    error_message = "At least one developer is needed: bring-up's grant check runs as the first entry."
  }

  # The name is the key of the for_each in identities.tf, so two entries with
  # the same name would silently collapse into one user — and the second
  # person's key would be the one that counts.
  validation {
    condition     = length(distinct([for developer in var.developers : lower(developer.name)])) == length(var.developers)
    error_message = "Developer names must be unique (case-insensitively): they name one Snowflake user each."
  }
}

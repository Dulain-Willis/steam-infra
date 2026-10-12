terraform {
  backend "s3" {
    bucket       = "steam-infra-tfstate-497675597225"
    key          = "steam-infra/snowflake.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

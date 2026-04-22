terraform {
  required_version = ">= 1.5.0"

  required_providers {
    minio = {
      source  = "aminueza/minio"
      version = ">= 1.7.0"
    }
  }
}

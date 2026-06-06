terraform {

  required_providers {
    aws = {
      source  = "hashicorp/aws" 
      version = "~> 6.0"
    }
  }

  required_verions = "1.15"
}

provider "aws" {
  region = "var.region"
}


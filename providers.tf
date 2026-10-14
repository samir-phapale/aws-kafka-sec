terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Phase       = "phase-3"
    }
  }

  # Ownership tags stamped on new resources by the account's automatic
  # tagging. They belong to that system, not to this configuration, so
  # Terraform neither removes nor reports them as drift.
  ignore_tags {
    keys = ["CreatedBy", "CreatedDate", "PrincipalId"]
  }
}

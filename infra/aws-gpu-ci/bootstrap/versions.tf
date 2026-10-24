terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Local state on purpose. This root is applied once, by hand, with your own
  # credentials, and it creates the bucket every other root keeps its state in.
  # Keep terraform.tfstate somewhere safe, or move it into that bucket after the
  # first apply with a backend "s3" block and `terraform init -migrate-state`.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "klahio-charts-ci"
      ManagedBy = "terraform"
      Root      = "infra/aws-gpu-ci/bootstrap"
    }
  }
}

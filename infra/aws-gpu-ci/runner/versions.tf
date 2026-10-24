terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  # Filled in by the workflow with -backend-config, from the bootstrap outputs.
  # The key is fixed rather than per run: a run whose destroy never happened
  # leaves its resources in this state, and the next run's apply and destroy
  # pick them up instead of leaving them to be found on the bill. The
  # workflow's concurrency group keeps two runs from holding it at once, and
  # use_lockfile catches anything that gets past that.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "klahio-charts-ci"
      ManagedBy = "terraform"
      Root      = "infra/aws-gpu-ci/runner"
      RunId     = var.run_id
    }
  }
}

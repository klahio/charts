variable "region" {
  description = "Region the GPU instances run in. The role may only act here."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "owner/name of the repository whose workflow may assume the role."
  type        = string
  default     = "klahio/charts"
}

variable "github_environment" {
  description = <<-EOT
    GitHub environment the GPU job runs in. The role trusts only tokens issued
    for this environment, so a workflow on any branch cannot reach AWS without
    naming it, and the environment's protection rules (required reviewers,
    allowed branches) become the gate on spending money.
  EOT
  type        = string
  default     = "gpu-ci"
}

variable "create_oidc_provider" {
  description = <<-EOT
    An account holds one OIDC provider per issuer URL. Set this to false if the
    account already trusts token.actions.githubusercontent.com, and the existing
    provider is looked up instead of created.
  EOT
  type        = bool
  default     = true
}

variable "allowed_instance_types" {
  description = "Instance types the role may launch. Anything else is denied, so a typo in a workflow cannot start a p5."
  type        = list(string)
  default     = ["g4dn.xlarge", "g6.xlarge"]
}

variable "state_bucket_name" {
  description = "Name of the state bucket. Empty derives one from the account ID, which keeps it globally unique."
  type        = string
  default     = ""
}

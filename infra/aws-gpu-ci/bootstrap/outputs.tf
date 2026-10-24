# Both values go into the GitHub environment as variables, not secrets: neither
# grants anything without a token GitHub only issues inside that environment.

output "role_arn" {
  description = "Set as AWS_GPU_CI_ROLE_ARN on the GitHub environment."
  value       = aws_iam_role.gpu_ci.arn
}

output "state_bucket" {
  description = "Set as TF_STATE_BUCKET on the GitHub environment."
  value       = aws_s3_bucket.state.id
}

output "region" {
  description = "Set as AWS_REGION on the GitHub environment."
  value       = var.region
}

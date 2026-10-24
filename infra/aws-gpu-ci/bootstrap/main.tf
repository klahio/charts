# Everything the GPU workflow needs before its first run, and nothing it creates
# per run: a bucket for the runner root's state, GitHub as an OIDC identity
# provider, and a role the workflow assumes with a short-lived token. No access
# key exists anywhere, so there is nothing to put in repository secrets and
# nothing to rotate.

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = var.state_bucket_name != "" ? var.state_bucket_name : "klahio-charts-tfstate-${local.account_id}"
  # The runner root keeps one fixed state key, so its lock file sits beside it.
  state_prefix = "gpu-runner/"
  oidc_url     = "token.actions.githubusercontent.com"
}

# ---------------------------------------------------------------------------
# State bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket
}

# A run that half-destroyed its instance is recovered from the state, so a state
# file overwritten by a bad run has to be recoverable too.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every run rewrites the same key, so old versions pile up. Thirty days is long
# enough to go back past a bad week.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ---------------------------------------------------------------------------
# GitHub OIDC
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_oidc_provider ? 1 : 0
  url            = "https://${local.oidc_url}"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's tokens against its own trusted CAs and ignores these,
  # but older provider versions still insist on the field.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://${local.oidc_url}"
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # The subject of a job that names an environment is fixed by GitHub to this
    # form, whatever branch or event started it. Trusting it, rather than
    # repo:<name>:*, is what makes the environment the only way in.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["${var.github_subject_prefix}:environment:${var.github_environment}"]
    }
  }
}

resource "aws_iam_role" "gpu_ci" {
  name               = "klahio-charts-gpu-ci"
  description        = "Assumed by the GPU workflow to create and destroy its test instance."
  assume_role_policy = data.aws_iam_policy_document.trust.json
  # The job holds these credentials from apply until destroy, and ComfyUI's
  # first boot alone can take most of an hour. A session that expired before
  # destroy would leave the instance to its own shutdown timer.
  max_session_duration = 3 * 3600
}

# ---------------------------------------------------------------------------
# What the role may do
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "gpu_ci" {
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.state_prefix}*"]
    }
  }

  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${local.state_prefix}*"]
  }

  # The AMI is resolved from AWS's public parameter for the Deep Learning Base
  # AMI, so a new driver release is picked up without editing anything.
  statement {
    sid       = "AmiLookup"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}::parameter/aws/service/deeplearning/*"]
  }

  statement {
    sid = "Ec2"
    actions = [
      "ec2:Describe*",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:CreateVpc",
      "ec2:DeleteVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet",
      "ec2:DeleteSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:CreateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:CreateRoute",
      "ec2:DeleteRoute",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:ImportKeyPair",
      "ec2:DeleteKeyPair",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:ModifyInstanceAttribute",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "OnlyAllowedInstanceTypes"
    effect    = "Deny"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:*:*:instance/*"]
    condition {
      test     = "StringNotEquals"
      variable = "ec2:InstanceType"
      values   = var.allowed_instance_types
    }
  }
}

resource "aws_iam_role_policy" "gpu_ci" {
  name   = "gpu-ci"
  role   = aws_iam_role.gpu_ci.id
  policy = data.aws_iam_policy_document.gpu_ci.json
}

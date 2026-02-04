#######################################
# Terraform Execution Role Policy
#
# This file defines the IAM policy attached to the TerraformExecutionRole.
# Update this file to grant new permissions for your infrastructure.
# After changes, run the bootstrap workflow to apply updates.
#######################################

locals {
  exec_role_name   = var.execution_role_name
  exec_policy_name = "${var.org_prefix}-terraform-execution-${var.env}"

  # Base permissions for state bucket access (always required)
  state_bucket_statements = [
    {
      Sid    = "StateBucketList"
      Effect = "Allow"
      Action = [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ]
      Resource = aws_s3_bucket.state.arn
    },
    {
      Sid    = "StateObjectsRW"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ]
      Resource = "${aws_s3_bucket.state.arn}/*"
    }
  ]

  # KMS permissions for state encryption (when using KMS)
  kms_statements = var.use_kms ? [
    {
      Sid    = "KmsStateAccess"
      Effect = "Allow"
      Action = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*",
        "kms:DescribeKey"
      ]
      Resource = aws_kms_key.state[0].arn
    }
  ] : []

  # S3 infrastructure permissions (auto-scoped to org_prefix)
  # Uses wildcards to ensure all S3 actions are covered
  s3_infra_statements = var.enable_s3_permissions ? [
    {
      Sid    = "S3BucketManagement"
      Effect = "Allow"
      Action = [
        "s3:CreateBucket",
        "s3:DeleteBucket",
        "s3:ListBucket",
        "s3:GetBucket*",
        "s3:PutBucket*",
        "s3:GetLifecycleConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:DeleteBucketPolicy",
        "s3:DeleteBucketWebsite",
        "s3:GetAccelerateConfiguration",
        "s3:PutAccelerateConfiguration",
        "s3:GetReplicationConfiguration",
        "s3:PutReplicationConfiguration",
        "s3:DeleteBucketReplication",
        "s3:GetEncryptionConfiguration",
        "s3:PutEncryptionConfiguration"
      ]
      Resource = "arn:aws:s3:::${var.org_prefix}-*"
    },
    {
      Sid    = "S3ObjectManagement"
      Effect = "Allow"
      Action = [
        "s3:GetObject*",
        "s3:PutObject*",
        "s3:DeleteObject*",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ]
      Resource = "arn:aws:s3:::${var.org_prefix}-*/*"
    }
  ] : []

  # Combine all policy statements
  all_statements = concat(
    local.state_bucket_statements,
    local.kms_statements,
    local.s3_infra_statements,
    var.extra_execution_policy_statements
  )
}

# The customer-managed policy for the execution role
resource "aws_iam_policy" "execution" {
  count = var.manage_execution_role_policy ? 1 : 0

  name        = local.exec_policy_name
  description = "Terraform execution policy for ${var.org_prefix} ${var.env} environment"

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.all_statements
  })

  tags = local.default_tags
}

# Attach the policy to the execution role
resource "aws_iam_role_policy_attachment" "execution" {
  count = var.manage_execution_role_policy ? 1 : 0

  role       = local.exec_role_name
  policy_arn = aws_iam_policy.execution[0].arn
}

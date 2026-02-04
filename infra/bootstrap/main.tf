locals {
  state_bucket_name = lower(join("-", compact([
    var.org_prefix,
    "tfstate",
    var.env,
    var.account_id,
    var.primary_region,
    var.state_bucket_suffix != "" ? var.state_bucket_suffix : null
  ])))

  default_tags = merge({
    Project     = var.org_prefix
    Environment = var.env
    ManagedBy   = "Terraform"
    Component   = "bootstrap"
  }, var.extra_tags)

  admin_principals = distinct(concat([
    "arn:aws:iam::${var.account_id}:root"
  ], var.state_bucket_admin_principals))

  rw_principals = length(var.state_bucket_rw_principals) > 0 ? distinct(var.state_bucket_rw_principals) : local.admin_principals
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "AllowAdminAccess"
    actions = ["s3:*"]

    principals {
      type        = "AWS"
      identifiers = local.admin_principals
    }

    resources = [
      "arn:aws:s3:::${local.state_bucket_name}",
      "arn:aws:s3:::${local.state_bucket_name}/*"
    ]
  }

  statement {
    sid = "AllowStateReadWrite"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    principals {
      type        = "AWS"
      identifiers = local.rw_principals
    }

    resources = [
      "arn:aws:s3:::${local.state_bucket_name}",
      "arn:aws:s3:::${local.state_bucket_name}/*"
    ]
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    actions = ["s3:*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      "arn:aws:s3:::${local.state_bucket_name}",
      "arn:aws:s3:::${local.state_bucket_name}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

data "aws_iam_policy_document" "kms" {
  statement {
    sid     = "AllowAdmin"
    actions = ["kms:*"]

    principals {
      type        = "AWS"
      identifiers = distinct(concat(local.admin_principals, var.kms_admin_principals))
    }

    resources = ["*"]
  }

  statement {
    sid = "AllowStateUse"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]

    principals {
      type        = "AWS"
      identifiers = local.rw_principals
    }

    resources = ["*"]
  }

  statement {
    sid = "AllowS3Service"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:s3:::${local.state_bucket_name}"]
    }
  }
}

resource "aws_kms_key" "state" {
  count                   = var.use_kms ? 1 : 0
  description             = "KMS key for Terraform state in ${local.state_bucket_name}"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = local.default_tags
}

resource "aws_kms_alias" "state" {
  count         = var.use_kms ? 1 : 0
  name          = "alias/${local.state_bucket_name}"
  target_key_id = aws_kms_key.state[0].key_id
}

resource "aws_s3_bucket" "state" {
  bucket        = local.state_bucket_name
  force_destroy = false
  tags          = local.default_tags
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

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
      sse_algorithm     = var.use_kms ? "aws:kms" : "AES256"
      kms_master_key_id = var.use_kms ? aws_kms_key.state[0].arn : null
    }

    bucket_key_enabled = var.use_kms
  }
}

resource "aws_s3_bucket_logging" "state" {
  count  = var.enable_access_logs ? 1 : 0
  bucket = aws_s3_bucket.state.id

  target_bucket = var.log_bucket_name
  target_prefix = var.log_bucket_prefix
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [
    aws_s3_bucket_ownership_controls.state,
    aws_s3_bucket_public_access_block.state,
    aws_s3_bucket_versioning.state,
    aws_s3_bucket_server_side_encryption_configuration.state
  ]
}

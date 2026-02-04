provider "aws" {
  region              = var.primary_region
  profile             = var.aws_profile
  allowed_account_ids = [var.account_id]

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [var.assume_role_arn]
    content {
      role_arn = assume_role.value
    }
  }

  default_tags {
    tags = local.default_tags
  }
}

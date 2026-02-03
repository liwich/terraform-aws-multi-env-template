locals {
  example_bucket_name = lower(join("-", compact([
    var.org_prefix,
    var.env,
    "storage",
    var.expected_account_id,
    var.example_bucket_suffix != "" ? var.example_bucket_suffix : null
  ])))

  default_tags = merge({
    Project     = var.org_prefix
    Environment = var.env
    Stack       = "storage"
    ManagedBy   = "Terraform"
  }, var.extra_tags)
}

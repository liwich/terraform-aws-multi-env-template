data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

check "account_guardrail" {
  assert        = data.aws_caller_identity.current.account_id == var.expected_account_id
  error_message = "Wrong AWS account. Expected ${var.expected_account_id}, got ${data.aws_caller_identity.current.account_id}."
}

check "region_guardrail" {
  assert        = contains(var.allowed_regions, data.aws_region.current.name)
  error_message = "Wrong AWS region. Allowed: ${join(", ", var.allowed_regions)}. Current: ${data.aws_region.current.name}."
}

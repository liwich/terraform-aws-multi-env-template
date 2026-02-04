output "state_bucket_name" {
  description = "Name of the Terraform state bucket."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the Terraform state bucket."
  value       = aws_s3_bucket.state.arn
}

output "kms_key_arn" {
  description = "KMS key ARN for state encryption (null when SSE-S3 is used)."
  value       = var.use_kms ? aws_kms_key.state[0].arn : null
}

output "execution_policy_arn" {
  description = "ARN of the managed IAM policy for the execution role."
  value       = var.manage_execution_role_policy ? aws_iam_policy.execution[0].arn : null
}

output "execution_policy_name" {
  description = "Name of the managed IAM policy for the execution role."
  value       = var.manage_execution_role_policy ? aws_iam_policy.execution[0].name : null
}

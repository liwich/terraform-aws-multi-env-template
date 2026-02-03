output "example_bucket_name" {
  description = "Name of the example S3 bucket."
  value       = module.example_bucket.bucket_id
}

output "example_bucket_arn" {
  description = "ARN of the example S3 bucket."
  value       = module.example_bucket.bucket_arn
}

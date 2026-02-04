output "cluster_name" {
  description = "Name of the ECS cluster"
  value       = module.api.cluster_name
}

output "service_name" {
  description = "Name of the ECS service"
  value       = module.api.service_name
}

output "task_definition_arn" {
  description = "ARN of the task definition"
  value       = module.api.task_definition_arn
}

# Echo storage outputs to confirm remote state works
output "storage_bucket_name" {
  description = "Storage bucket name (from remote state)"
  value       = data.terraform_remote_state.storage.outputs.example_bucket_name
}

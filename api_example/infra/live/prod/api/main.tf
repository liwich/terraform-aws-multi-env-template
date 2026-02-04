# =============================================================================
# PROD - FastAPI on ECS Fargate
# =============================================================================

module "api" {
  source = "../../../modules/ecs-api"

  app_name    = var.app_name
  environment = local.environment
  aws_region  = var.aws_region

  # From remote state - no hardcoding!
  storage_bucket_name = data.terraform_remote_state.storage.outputs.example_bucket_name
  storage_bucket_arn  = data.terraform_remote_state.storage.outputs.example_bucket_arn

  # Networking
  vpc_id     = data.aws_vpc.default.id
  subnet_ids = data.aws_subnets.default.ids

  # Application config
  container_image = var.container_image
  container_port  = var.container_port
  cpu             = var.cpu
  memory          = var.memory
  desired_count   = var.desired_count
}

# =============================================================================
# REMOTE STATE - Reference outputs from the storage stack
# =============================================================================

data "terraform_remote_state" "storage" {
  backend = "s3"

  config = {
    bucket = var.storage_state_bucket
    key    = var.storage_state_key
    region = var.storage_state_region
  }
}

# =============================================================================
# Networking (uses default VPC for example)
# =============================================================================

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

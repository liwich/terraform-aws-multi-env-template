provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.app_name
      Environment = local.environment
      ManagedBy   = "terraform"
    }
  }
}

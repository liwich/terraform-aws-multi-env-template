aws_region = "us-west-2"
app_name   = "fastapi-app"

# -----------------------------------------------------------------------------
# Remote State - Points to terraform-accelerator's PROD storage stack
# Update these values to match your storage backend
# -----------------------------------------------------------------------------
storage_state_bucket = "your-org-tfstate-prod-ACCOUNT-us-west-2"
storage_state_key    = "prod/storage/terraform.tfstate"
storage_state_region = "us-west-2"

# -----------------------------------------------------------------------------
# Application Configuration (prod has highest resources)
# -----------------------------------------------------------------------------
container_image = "your-ecr-repo/fastapi-app:latest"
container_port  = 8000
cpu             = 1024
memory          = 2048
desired_count   = 3

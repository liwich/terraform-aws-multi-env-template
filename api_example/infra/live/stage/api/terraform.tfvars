aws_region = "us-west-2"
app_name   = "fastapi-app"

# -----------------------------------------------------------------------------
# Remote State - Points to terraform-accelerator's STAGE storage stack
# Update these values to match your storage backend
# -----------------------------------------------------------------------------
storage_state_bucket = "your-org-tfstate-stage-ACCOUNT-us-west-2"
storage_state_key    = "stage/storage/terraform.tfstate"
storage_state_region = "us-west-2"

# -----------------------------------------------------------------------------
# Application Configuration (stage has more resources than dev)
# -----------------------------------------------------------------------------
container_image = "your-ecr-repo/fastapi-app:latest"
container_port  = 8000
cpu             = 512
memory          = 1024
desired_count   = 2

aws_region = "us-west-2"
app_name   = "fastapi-app"

# -----------------------------------------------------------------------------
# Remote State - Points to terraform-accelerator's storage stack
# Update these values to match your storage backend
# -----------------------------------------------------------------------------
storage_state_bucket = "liwich-tfstate-dev-123456789455-us-west-2-01"
storage_state_key    = "dev/storage/terraform.tfstate"
storage_state_region = "us-west-2"

# -----------------------------------------------------------------------------
# Application Configuration
# -----------------------------------------------------------------------------
container_image = "public.ecr.aws/docker/library/python:3.11-slim"
container_port  = 8000
cpu             = 256
memory          = 512
desired_count   = 1

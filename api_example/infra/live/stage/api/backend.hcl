# API project's own state - separate from storage stack
bucket       = "your-api-project-tfstate-stage"
key          = "stage/api/terraform.tfstate"
region       = "us-west-2"
encrypt      = true
use_lockfile = true

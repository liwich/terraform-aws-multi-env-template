# API project's own state - separate from storage stack
bucket       = "your-api-project-tfstate-prod"
key          = "prod/api/terraform.tfstate"
region       = "us-west-2"
encrypt      = true
use_lockfile = true

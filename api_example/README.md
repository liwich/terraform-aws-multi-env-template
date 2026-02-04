# API Example - External Multi-Environment Project

This folder demonstrates how an **external project** (outside the terraform-accelerator repo) can reference outputs from the bootstrapped storage backend across multiple environments without hardcoding values.

## Structure

```
api_example/
└── infra/
    ├── modules/
    │   └── ecs-api/              # Reusable ECS Fargate module
    │       ├── main.tf
    │       ├── variables.tf
    │       └── outputs.tf
    └── live/
        ├── dev/
        │   └── api/
        │       ├── backend.hcl        # Dev state config
        │       ├── terraform.tfvars   # Points to dev storage state
        │       └── *.tf
        ├── stage/
        │   └── api/
        │       ├── backend.hcl        # Stage state config
        │       ├── terraform.tfvars   # Points to stage storage state
        │       └── *.tf
        └── prod/
            └── api/
                ├── backend.hcl        # Prod state config
                ├── terraform.tfvars   # Points to prod storage state
                └── *.tf
```

## How It Works

Each environment references its corresponding storage stack via `terraform_remote_state`:

```
┌─────────────────────────────────────────────────────────────┐
│  terraform-accelerator (platform repo)                      │
│  └── infra/live/                                            │
│      ├── dev/storage/   → outputs: bucket_name, bucket_arn  │
│      ├── stage/storage/ → outputs: bucket_name, bucket_arn  │
│      └── prod/storage/  → outputs: bucket_name, bucket_arn  │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ terraform_remote_state
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  api_example (application repo)                             │
│  └── infra/live/                                            │
│      ├── dev/api/   → reads dev storage outputs             │
│      ├── stage/api/ → reads stage storage outputs           │
│      └── prod/api/  → reads prod storage outputs            │
└─────────────────────────────────────────────────────────────┘
```

## Key Pattern

In each environment's `data.tf`:

```hcl
data "terraform_remote_state" "storage" {
  backend = "s3"
  config = {
    bucket = var.storage_state_bucket  # e.g., "liwich-tfstate-dev-..."
    key    = var.storage_state_key     # e.g., "dev/storage/terraform.tfstate"
    region = var.storage_state_region
  }
}
```

Then use in `main.tf`:

```hcl
module "api" {
  source = "../../../modules/ecs-api"
  
  # No hardcoding - values come from remote state!
  storage_bucket_name = data.terraform_remote_state.storage.outputs.example_bucket_name
  storage_bucket_arn  = data.terraform_remote_state.storage.outputs.example_bucket_arn
}
```

## Prerequisites

1. The storage stack must be deployed first in each environment
2. The API's execution role needs `s3:GetObject` on the storage state bucket
3. Update `terraform.tfvars` with correct storage state bucket/key for each env

## Deployment

```bash
# Deploy to dev
cd infra/live/dev/api
terraform init -backend-config=backend.hcl
terraform plan
terraform apply

# Deploy to stage
cd ../../../stage/api
terraform init -backend-config=backend.hcl
terraform plan
terraform apply

# Deploy to prod
cd ../../../prod/api
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

## Environment Configuration

Each environment has different resource allocations:

| Environment | CPU  | Memory | Task Count | Storage State Key |
|-------------|------|--------|------------|-------------------|
| dev         | 256  | 512    | 1          | dev/storage/...   |
| stage       | 512  | 1024   | 2          | stage/storage/... |
| prod        | 1024 | 2048   | 3          | prod/storage/...  |

## What Gets Passed to the Application

The ECS task receives these environment variables (no hardcoding):

- `STORAGE_BUCKET_NAME` - From remote state
- `AWS_REGION` - From variables
- `ENVIRONMENT` - From locals (dev/stage/prod)

The task IAM role also gets S3 permissions scoped to the bucket ARN from remote state.

**Recommended Approach**
- Use separate AWS accounts for dev/stage/prod, with per-environment directories and a dedicated S3 state bucket per account. This maximizes safety, makes credentials obvious, and keeps blast radius small.
- Use the Terraform 1.14 S3 backend with native lockfiles (`use_lockfile = true`) to avoid DynamoDB for new setups while preserving safe locking behavior.
- Keep live stacks thin and opinionated, reuse small modules, and provide simple wrapper scripts so new developers can run plan/apply without deep Terraform knowledge.

**Architecture Decisions**
- **Environment Separation**
  - A) directories per env + separate state keys (simple but shared account risk)
  - B) workspaces (easy to confuse and weaker guardrails)
  - C) separate AWS accounts + separate state per account (recommended for safety)
  - D) Terragrunt optional (not required for this Terraform-native template)
  - Recommendation: C with per-env directories and separate state
- **Guardrails** Account and region checks via `check` blocks, provider `allowed_account_ids`, `default_tags`, policy-as-code in CI, separate credentials per env, and pipeline approvals/concurrency controls.
- **Backend Strategy (S3)** Bucket naming `<ORG_OR_PROJECT_PREFIX>-tfstate-<ENV>-<ACCOUNT_ID>-<PRIMARY_REGION>-<STATE_BUCKET_SUFFIX>`, key `dev/storage/terraform.tfstate`, versioning + encryption + public access block, TLS-only bucket policy, and lockfiles via `use_lockfile = true`. DynamoDB migration: remove `dynamodb_table`, add `use_lockfile = true`, run `terraform init -migrate-state`, then decommission the table.
- **IAM Strategy (Local + CI)** Local uses AWS profile + optional `assume_role_arn`; CI uses OIDC with short-lived roles, least privilege to state bucket and stack resources.
- **Module Strategy** Reusable modules live in `/modules`, live stacks in `/live`, versions are pinned via tags or SHAs, and module chains are kept shallow.
- **Security and Governance Defaults** SSE-KMS recommended, IAM least privilege per env for state access, bucket policy restricts principals and enforces TLS, CloudTrail for audit, optional S3 access logs to a central log bucket, and no secrets in `*.tfvars` (use SSM/Secrets Manager instead).
- **CI/CD Proposal** Plan on PR, apply on merge with approvals, environment protections for stage/prod, concurrency per env/stack, and state access via least-privilege roles.
- **Resource Dependencies** Bootstrap is standalone and only creates backend resources; live stacks depend on bootstrap; avoid circular dependencies between bootstrap and live stacks.

**Repo Tree**
- `bootstrap/` creates the state backend.
- `live/` contains per-env stacks.
- `modules/` contains reusable modules.
- `scripts/` contains wrapper scripts.

```
.
├── .cursorrules
├── .github/workflows/terraform.yml
├── .pre-commit-config.yaml
├── .tflint.hcl
├── Makefile
├── PROJECT_SPEC.md
├── README.md
├── bootstrap
│   ├── dev.tfvars
│   ├── main.tf
│   ├── outputs.tf
│   ├── prod.tfvars
│   ├── providers.tf
│   ├── stage.tfvars
│   ├── variables.tf
│   └── versions.tf
├── live
│   ├── dev
│   │   └── storage
│   │       ├── backend.hcl
│   │       ├── checks.tf
│   │       ├── locals.tf
│   │       ├── main.tf
│   │       ├── outputs.tf
│   │       ├── providers.tf
│   │       ├── terraform.tfvars
│   │       ├── variables.tf
│   │       └── versions.tf
│   ├── prod
│   │   └── storage
│   │       └── (same as dev)
│   └── stage
│       └── storage
│           └── (same as dev)
├── modules
│   └── s3-bucket
│       ├── main.tf
│       ├── outputs.tf
│       └── variables.tf
└── scripts
    ├── tf
    └── tf.ps1
```

**Code Snippets (Grouped by File Path)**
- `bootstrap/versions.tf`
```hcl
terraform {
  required_version = "~> 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.90"
    }
  }
}
```

- `bootstrap/providers.tf`
```hcl
provider "aws" {
  region              = var.primary_region
  profile             = var.aws_profile
  allowed_account_ids = [var.account_id]

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [var.assume_role_arn]
    content {
      role_arn = assume_role.value
    }
  }

  default_tags {
    tags = local.default_tags
  }
}
```

- `bootstrap/main.tf`
```hcl
locals {
  state_bucket_name = lower(join("-", compact([
    var.org_prefix,
    "tfstate",
    var.env,
    var.account_id,
    var.primary_region,
    var.state_bucket_suffix != "" ? var.state_bucket_suffix : null
  ])))

  default_tags = merge({
    Project     = var.org_prefix
    Environment = var.env
    ManagedBy   = "Terraform"
    Component   = "bootstrap"
  }, var.extra_tags)

  admin_principals = distinct(concat([
    "arn:aws:iam::${var.account_id}:root"
  ], var.state_bucket_admin_principals))

  rw_principals = length(var.state_bucket_rw_principals) > 0 ? distinct(var.state_bucket_rw_principals) : local.admin_principals
}

resource "aws_s3_bucket" "state" {
  bucket        = local.state_bucket_name
  force_destroy = false
  tags          = local.default_tags
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.use_kms ? "aws:kms" : "AES256"
      kms_master_key_id = var.use_kms ? aws_kms_key.state[0].arn : null
    }

    bucket_key_enabled = var.use_kms
  }
}
```

- `bootstrap/variables.tf`
```hcl
variable "org_prefix" {
  type        = string
  description = "Org or project prefix used in naming. Lowercase letters, numbers, and hyphens only."
}

variable "env" {
  type        = string
  description = "Environment name: dev, stage, or prod."
}

variable "account_id" {
  type        = string
  description = "AWS account ID for the target environment."
}

variable "use_kms" {
  type        = bool
  description = "Enable SSE-KMS for the state bucket."
  default     = true
}
```

- `bootstrap/outputs.tf`
```hcl
output "state_bucket_name" {
  description = "Name of the Terraform state bucket."
  value       = aws_s3_bucket.state.id
}

output "kms_key_arn" {
  description = "KMS key ARN for state encryption (null when SSE-S3 is used)."
  value       = var.use_kms ? aws_kms_key.state[0].arn : null
}
```

- `bootstrap/dev.tfvars`
```hcl
org_prefix = "<ORG_OR_PROJECT_PREFIX>"
env        = "dev"
account_id = "<DEV_ACCOUNT_ID>"

primary_region     = "<PRIMARY_REGION>"
state_bucket_suffix = "<STATE_BUCKET_SUFFIX>"
use_kms            = true
enable_access_logs = false
log_bucket_name    = "<CENTRAL_LOG_BUCKET_NAME>"
aws_profile        = "<LOCAL_AWS_PROFILE>"
assume_role_arn    = "arn:aws:iam::<DEV_ACCOUNT_ID>:role/<BOOTSTRAP_ROLE_NAME>"
```

- `live/dev/storage/versions.tf`
```hcl
terraform {
  required_version = "~> 1.14.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.90"
    }
  }

  backend "s3" {}
}
```

- `live/dev/storage/providers.tf`
```hcl
provider "aws" {
  region              = var.primary_region
  profile             = var.aws_profile
  allowed_account_ids = [var.expected_account_id]

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [var.assume_role_arn]
    content {
      role_arn = assume_role.value
    }
  }

  default_tags {
    tags = local.default_tags
  }
}
```

- `live/dev/storage/locals.tf`
```hcl
locals {
  example_bucket_name = lower(join("-", compact([
    var.org_prefix,
    var.env,
    "storage",
    var.expected_account_id,
    var.example_bucket_suffix != "" ? var.example_bucket_suffix : null
  ])))

  default_tags = merge({
    Project     = var.org_prefix
    Environment = var.env
    Stack       = "storage"
    ManagedBy   = "Terraform"
  }, var.extra_tags)
}
```

- `live/dev/storage/checks.tf`
```hcl
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

check "account_guardrail" {
  assert        = data.aws_caller_identity.current.account_id == var.expected_account_id
  error_message = "Wrong AWS account. Expected ${var.expected_account_id}, got ${data.aws_caller_identity.current.account_id}."
}

check "region_guardrail" {
  assert        = contains(var.allowed_regions, data.aws_region.current.name)
  error_message = "Wrong AWS region. Allowed: ${join(", ", var.allowed_regions)}. Current: ${data.aws_region.current.name}."
}
```

- `live/dev/storage/main.tf`
```hcl
module "example_bucket" {
  source = "../../../modules/s3-bucket"

  name          = local.example_bucket_name
  versioning    = true
  sse_algorithm = "AES256"
  tags          = local.default_tags
}
```

- `live/dev/storage/backend.hcl`
```hcl
bucket         = "<STATE_BUCKET_NAME>"
key            = "dev/storage/terraform.tfstate"
region         = "<PRIMARY_REGION>"
encrypt        = true
use_lockfile   = true
# kms_key_id   = "<STATE_KMS_KEY_ARN>"
```

- `live/dev/storage/terraform.tfvars`
```hcl
env                 = "dev"
org_prefix          = "<ORG_OR_PROJECT_PREFIX>"
expected_account_id = "<DEV_ACCOUNT_ID>"

primary_region = "<PRIMARY_REGION>"
allowed_regions = [
  "<PRIMARY_REGION>"
]

assume_role_arn = "arn:aws:iam::<DEV_ACCOUNT_ID>:role/<TERRAFORM_EXEC_ROLE_NAME>"
aws_profile     = "<LOCAL_AWS_PROFILE>"

example_bucket_suffix = "<OPTIONAL_BUCKET_SUFFIX>"
```

- `modules/s3-bucket/variables.tf`
```hcl
variable "name" {
  type        = string
  description = "Name of the S3 bucket."
}

variable "sse_algorithm" {
  type        = string
  description = "SSE algorithm: AES256 or aws:kms."
  default     = "AES256"
}
```

- `modules/s3-bucket/main.tf`
```hcl
resource "aws_s3_bucket" "this" {
  bucket        = var.name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

- `.cursorrules`
```
- Use Terraform CLI 1.14.x and pin provider versions.
- Use S3 backend with `use_lockfile = true`; do not introduce DynamoDB locking for new work.
- Enforce per-environment separation: dev/stage/prod must have distinct state keys and buckets.
```

**Scripts and Makefile Examples**
- `scripts/tf`
```bash
#!/usr/bin/env bash
set -euo pipefail

env=""
stack="storage"
cmd=""
args=()

for arg in "$@"; do
  case "$arg" in
    env=*) env="${arg#env=}" ;;
    stack=*) stack="${arg#stack=}" ;;
    plan|apply|destroy|refresh|validate|output|state|import|taint|untaint|init|fmt|lint|sec)
      cmd="$arg"
      ;;
    *)
      args+=("$arg")
      ;;
  esac
done

if [ -z "$cmd" ]; then
  echo "Usage: ./scripts/tf env=<dev|stage|prod> stack=<stack> <plan|apply|destroy|init|validate|fmt|lint|sec>"
  exit 1
fi

if [ -z "$env" ] && [ "$cmd" != "fmt" ]; then
  echo "Missing env=. Example: env=dev"
  exit 1
fi

stack_dir="live/${env}/${stack}"
backend_config="${stack_dir}/backend.hcl"

if [ "$cmd" != "fmt" ]; then
  if [ ! -d "$stack_dir" ]; then
    echo "Stack directory not found: $stack_dir"
    exit 1
  fi
fi

case "$cmd" in
  fmt)
    terraform fmt -recursive
    ;;
  lint)
    tflint --init --chdir "$stack_dir"
    tflint --chdir "$stack_dir"
    ;;
  sec)
    tfsec "$stack_dir"
    ;;
  init)
    terraform -chdir="$stack_dir" init -backend-config="$backend_config"
    ;;
  *)
    terraform -chdir="$stack_dir" init -backend-config="$backend_config"
    terraform -chdir="$stack_dir" "$cmd" "${args[@]}"
    ;;
esac
```

- `scripts/tf.ps1`
```powershell
param(
  [string]$env = "",
  [string]$stack = "storage",
  [Parameter(Position = 0)][string]$cmd = "",
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$args
)

if (-not $cmd) {
  Write-Host "Usage: ./scripts/tf.ps1 -env <dev|stage|prod> -stack <stack> <plan|apply|destroy|init|validate|fmt|lint|sec>"
  exit 1
}

if (-not $env -and $cmd -ne "fmt") {
  Write-Host "Missing -env. Example: -env dev"
  exit 1
}

$stackDir = "live/$env/$stack"
$backendConfig = "$stackDir/backend.hcl"

if ($cmd -ne "fmt") {
  if (-not (Test-Path $stackDir)) {
    Write-Host "Stack directory not found: $stackDir"
    exit 1
  }
}

switch ($cmd) {
  "fmt" {
    terraform fmt -recursive
  }
  "lint" {
    tflint --init --chdir $stackDir
    tflint --chdir $stackDir
  }
  "sec" {
    tfsec $stackDir
  }
  "init" {
    terraform -chdir=$stackDir init -backend-config=$backendConfig
  }
  default {
    terraform -chdir=$stackDir init -backend-config=$backendConfig
    terraform -chdir=$stackDir $cmd @args
  }
}
```

- `Makefile`
```makefile
TF := ./scripts/tf
STACK ?= storage

dev-plan:
	$(TF) env=dev stack=$(STACK) plan

dev-apply:
	$(TF) env=dev stack=$(STACK) apply
```

- `.pre-commit-config.yaml`
```yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.83.0
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_tflint
      - id: terraform_tfsec
```

- `.tflint.hcl`
```hcl
plugin "aws" {
  enabled = true
  version = "0.33.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

- `.github/workflows/terraform.yml`
```yaml
jobs:
  plan:
    if: github.event_name == 'pull_request'
    strategy:
      matrix:
        env: [dev]
        stack: [storage]
    steps:
      - run: ./scripts/tf env=${{ matrix.env }} stack=${{ matrix.stack }} plan -input=false
```

**Getting Started**
1) Prerequisites: Terraform 1.14.x, AWS CLI, tflint, tfsec (or checkov), pre-commit (optional).
2) Fill placeholders in `bootstrap/*.tfvars`, `live/*/storage/terraform.tfvars`, and `live/*/storage/backend.hcl`.
3) Local credentials: `aws configure --profile <LOCAL_AWS_PROFILE>` or `AWS_PROFILE=<LOCAL_AWS_PROFILE>`.
4) Bootstrap backend once per account: `terraform -chdir=bootstrap init` then `terraform -chdir=bootstrap apply -var-file=dev.tfvars`.
5) Init/plan/apply dev stack: `./scripts/tf env=dev stack=storage plan` then `./scripts/tf env=dev stack=storage apply`.
6) Quality checks: `./scripts/tf fmt`, `./scripts/tf env=dev stack=storage validate`, `./scripts/tf env=dev stack=storage lint`, `./scripts/tf env=dev stack=storage sec`.
7) CI/CD: configure GitHub Environments `dev`, `stage`, `prod` with `AWS_ROLE_ARN` and `AWS_REGION`, and require approvals for stage/prod.

**Template Completion Checklist**
- Fill account IDs, regions, and prefix placeholders.
- Run backend bootstrap in each account (dev, stage, prod).
- Update backend configs with the correct state bucket name and key.
- Run dev plan/apply using the scripts.
- Add new stack/module using the same guardrails and backend patterns.

**Tradeoffs and Risks to Watch**
- Drift risk if teams run manual changes outside Terraform; enforce least privilege and CI-only applies for prod.
- State corruption risk if backend bucket policy is overly permissive; keep RW access narrow.
- Environment bleed if `backend.hcl` or `terraform.tfvars` are copied incorrectly; guardrails and account checks help.
- CI apply on merge needs environment protections; do not allow prod apply without approval.

**Sanity Check**
- dev/stage/prod use distinct buckets and distinct keys.
- Local and CI workflows both call the same scripts and backend configs.
- Bootstrap has a clear owner (platform team) and is run once per account.

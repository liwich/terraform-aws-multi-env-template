# Terraform AWS Platform Template

This repo is a Terraform project template that bootstraps an AWS S3 remote backend and supports dev/stage/prod as first-class environments with strong guardrails and a clone-and-go developer experience.

For the full spec, rationale, and tradeoffs, see `PROJECT_SPEC.md`.

## What this template provides
- Separate AWS accounts per environment with distinct state buckets and keys.
- S3 backend using Terraform 1.14 native lockfiles (`use_lockfile = true`).
- Guardrails to prevent cross-environment mistakes (account/region checks + allowed account IDs).
- Simple wrappers for `init/plan/apply`, linting, and security scans.
- CI workflow with OIDC role assumption and environment protections.

## Repo layout
- `bootstrap/` one-time backend provisioning (S3 bucket, optional KMS).
- `live/` deployable root modules (stacks) grouped by environment in `live/<env>/<stack>`.
  - `live` is a convention for “applied stacks” (root modules), not the environment itself.
  - You can rename `live` to `environments/` or `stacks/` if preferred; update scripts and docs accordingly.
- `modules/` reusable modules.
- `scripts/` CLI wrappers (`tf` for bash, `tf.ps1` for PowerShell).

## Stacks
A stack is a Terraform root module under `live/<env>/<stack>` that represents one deployable unit with its own state and guardrails. Each stack uses a dedicated backend key and can be planned/applied independently.

Typical stack files:
- `versions.tf` provider and Terraform version pinning.
- `providers.tf` provider config with `allowed_account_ids` and `assume_role`.
- `backend.hcl` S3 backend configuration (bucket, key, region, lockfiles).
- `terraform.tfvars` per-environment inputs and placeholders.
- `checks.tf` guardrails for account and region.
- `main.tf`, `outputs.tf` stack resources and outputs.

Example stack: `live/dev/storage`.

## Prerequisites
- Terraform CLI `1.14.x`.
- AWS CLI (configured for local profiles).
- Optional: `tflint`, `tfsec` (or checkov), `pre-commit`.

## Configure placeholders
Fill placeholders in:
- `bootstrap/dev.tfvars`, `bootstrap/stage.tfvars`, `bootstrap/prod.tfvars`
- `live/*/storage/terraform.tfvars`
- `live/*/storage/backend.hcl`

Key placeholders to set:
- `<ORG_OR_PROJECT_PREFIX>`, `<DEV_ACCOUNT_ID>`, `<STAGE_ACCOUNT_ID>`, `<PROD_ACCOUNT_ID>`
- `<PRIMARY_REGION>`, `<STATE_BUCKET_SUFFIX>` (optional extra uniqueness)
- `<TERRAFORM_EXEC_ROLE_NAME>`, `<BOOTSTRAP_ROLE_NAME>` (if using role assumption)

## Bootstrap the backend (one-time per account)
This repo is configured for CI-only execution. Use the GitHub Actions workflow:

- Actions → **Terraform Bootstrap** → Run workflow
  - `env`: dev, stage, or prod
  - `action`: plan or apply

Set `AWS_BOOTSTRAP_ROLE_ARN` and `AWS_REGION` in each GitHub Environment.

## Run a stack (GitHub Actions)
- Open a PR to trigger a plan.
- Merge to `main` to apply (with environment approvals).
- Or run manually: Actions → **Terraform** → Run workflow.

## Quality checks
- Run via CI (recommended).
- Break-glass local override: set `ALLOW_LOCAL_TF=1` and use the scripts.

## CI/CD
The GitHub Actions workflow in `.github/workflows/terraform.yml`:
- Runs plan on PRs.
- Applies on merge to `main` with per-environment approvals.
- Uses OIDC to assume roles (set `AWS_ROLE_ARN` and `AWS_REGION` in each GitHub Environment).

## Local execution policy
Local Terraform execution is disabled by default in `scripts/tf` and `scripts/tf.ps1`.
If you must run locally, set `ALLOW_LOCAL_TF=1` (break-glass only).

## Guardrails and safety
- `allowed_account_ids` in providers block wrong credentials.
- `check` blocks enforce account and region allow-lists.
- State buckets are isolated per environment and use lockfiles.

## Adding a new stack
1) Create `live/<env>/<stack>` by copying `live/dev/storage` and renaming the stack.
2) Update `backend.hcl` with the new key (`<env>/<stack>/terraform.tfstate`).
3) Update `terraform.tfvars` and add stack-specific resources.
4) Run `./scripts/tf env=<env> stack=<stack> plan`.

## Notes
- State bucket naming follows: `<ORG_OR_PROJECT_PREFIX>-tfstate-<ENV>-<ACCOUNT_ID>-<PRIMARY_REGION>-<STATE_BUCKET_SUFFIX>`.
- DynamoDB locking is not used; lockfiles are enabled in backend configs.

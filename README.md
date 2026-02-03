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
- `infra/` contains all Terraform code and scripts.
  - `infra/bootstrap/` one-time backend provisioning (S3 bucket, optional KMS).
  - `infra/live/` deployable root modules (stacks) grouped by environment in `infra/live/<env>/<stack>`.
  - `infra/modules/` reusable modules.
  - `infra/scripts/` CLI wrappers (`tf` for bash, `tf.ps1` for PowerShell).
  - `live` is a convention for “applied stacks” (root modules), not the environment itself.
  - You can rename `live` to `environments/` or `stacks/` if preferred; update scripts and docs accordingly.

Workflows default to `TF_WORKDIR=infra`. If you move the folder, set `TF_WORKDIR` to the new path.

## Stacks
A stack is a Terraform root module under `infra/live/<env>/<stack>` that represents one deployable unit with its own state and guardrails. Each stack uses a dedicated backend key and can be planned/applied independently.

Typical stack files:
- `versions.tf` provider and Terraform version pinning.
- `providers.tf` provider config with `allowed_account_ids` and `assume_role`.
- `backend.hcl` S3 backend configuration (bucket, key, region, lockfiles).
- `terraform.tfvars` per-environment inputs and placeholders.
- `checks.tf` guardrails for account and region.
- `main.tf`, `outputs.tf` stack resources and outputs.

Example stack: `infra/live/dev/storage`.

## Prerequisites
- Terraform CLI `1.14.x`.
- AWS CLI (configured for local profiles).
- Optional: `tflint`, `tfsec` (or checkov), `pre-commit`.

## Configure placeholders
Template files (`*.tfvars.example`) are placeholders only. Do not commit real values in a public repo.
See `infra/bootstrap/dev.tfvars.example` for format.
CI generates `infra/bootstrap/<env>.tfvars`, `infra/live/<env>/<stack>/terraform.tfvars`, and `infra/live/<env>/<stack>/backend.hcl` from GitHub Environment secrets (see below).

## Setup order (CI-only)
1) Set GitHub Environment secrets/vars (required list below). For public repos, store all values as secrets.
2) Run the IAM setup script once per account (dev, stage, prod). A system administrator should run this; it requires IAM admin-level permissions and fails fast if missing.
3) Use the script output to set `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_BOOTSTRAP_ROLE_ARN`, and `AWS_ROLE_ARN` in each GitHub Environment.
4) Bootstrap the backend: Actions → **Terraform Bootstrap** → Run workflow (plan, then apply).
5) Run stacks: open a PR to trigger a plan, then merge to `main` to apply (with approvals), or run Actions → **Terraform** → Run workflow.

## Quality checks
- Run via CI (recommended).
- Break-glass local override: set `ALLOW_LOCAL_TF=1` and use the scripts.

## CI/CD
The GitHub Actions workflow in `.github/workflows/terraform.yml`:
- Runs plan on PRs.
- Applies on merge to `main` with per-environment approvals.
- Uses OIDC to assume roles (set `AWS_ROLE_ARN` and `AWS_REGION` in each GitHub Environment).
- Renders `backend.hcl` and `terraform.tfvars` from GitHub Environment secrets/vars before running Terraform.

Best practice for GitHub OIDC: assume the target role directly in the workflow and set `assume_role_arn = null` in CI-rendered tfvars (no role chaining). Use `assume_role_arn` only for local break-glass runs.

## GitHub Environment secrets/vars (per environment)
Required:
- `TF_ORG_PREFIX`
- `AWS_ACCOUNT_ID`
- `AWS_REGION`
- `AWS_BOOTSTRAP_ROLE_ARN`
- `AWS_ROLE_ARN`

Use secrets for all values in public repos.
Workflows read secrets first and fall back to vars if a secret is not set.

Optional:
- `TF_STATE_BUCKET_SUFFIX` (recommended for uniqueness)
- `TF_ALLOWED_REGIONS` (comma-separated, defaults to `AWS_REGION`)
- `TF_USE_KMS` (`true`/`false`, default `true`)
- `TF_ENABLE_ACCESS_LOGS` (`true`/`false`, default `false`)
- `TF_LOG_BUCKET_NAME` and `TF_LOG_BUCKET_PREFIX`
- `TF_EXTRA_TAGS_HCL` (single-line HCL, e.g., `{ Owner = "Platform" }`)
- `TF_EXAMPLE_BUCKET_SUFFIX`
- `TF_STATE_KMS_KEY_ARN` (if you want `kms_key_id` in `backend.hcl`)
- `TF_WORKDIR` (defaults to `infra`; set to a different path if you move the folder)

The workflow computes the state bucket name as:
`<TF_ORG_PREFIX>-tfstate-<ENV>-<AWS_ACCOUNT_ID>-<AWS_REGION>-<TF_STATE_BUCKET_SUFFIX>` (suffix omitted if empty).

Note: spaces in `TF_ALLOWED_REGIONS` are trimmed by the workflow.

## GitHub Actions credentials (OIDC)
These workflows require GitHub OIDC roles in each AWS account (dev, stage, prod). Create an OIDC provider and two roles per account: one for bootstrap and one for stack execution.

Recommended: use the automated setup scripts below. Manual steps are optional and included after the scripts.

### Automated setup scripts
Run these from a system administrator workstation to create the OIDC provider, bootstrap role, and execution role in each account. They validate credentials up front by calling IAM APIs and will fail fast if permissions are missing.
Run once per account (dev, stage, prod) with the corresponding AWS credentials. The output includes:
- GitHub Environment secrets/vars to set.
- A bootstrap `tfvars` snippet for reference (CI renders files from secrets/vars).

Required IAM permissions include: `iam:ListOpenIDConnectProviders`, `iam:GetOpenIDConnectProvider`, `iam:CreateOpenIDConnectProvider`, `iam:GetRole`, `iam:CreateRole`, and `iam:PutRolePolicy`.

Required inputs:
- `ORG` (GitHub org or user)
- `REPO` (repo name)
- `ENV_NAME` (dev, stage, prod)
- `AWS_REGION`
- `STATE_BUCKET_NAME`

Optional inputs:
- `ACCOUNT_ID` (verify credentials match)
- `BOOTSTRAP_ROLE_NAME` (default `TerraformBootstrapRole`)
- `EXEC_ROLE_NAME` (default `TerraformExecutionRole`)
- `USE_KMS` (`true`/`false`, default `true`)
- `STATE_KMS_KEY_ARN` (locks KMS permissions to a specific key)
- `DRY_RUN` (`true`/`false`, default `false`)

Bash (Linux/macOS):
```bash
export ORG="<ORG>"
export REPO="<REPO>"
export ENV_NAME="dev"
export AWS_REGION="<PRIMARY_REGION>"
export STATE_BUCKET_NAME="<STATE_BUCKET_NAME>"
export BOOTSTRAP_ROLE_NAME="TerraformBootstrapRole"
export EXEC_ROLE_NAME="TerraformExecutionRole"
export USE_KMS="true"
export DRY_RUN="true"

bash ./infra/scripts/bootstrap-iam.sh
```

Bash (parameters instead of env vars):
```bash
bash ./infra/scripts/bootstrap-iam.sh \
  --org <ORG> \
  --repo <REPO> \
  --env dev \
  --region <PRIMARY_REGION> \
  --state-bucket <STATE_BUCKET_NAME> \
  --bootstrap-role TerraformBootstrapRole \
  --exec-role TerraformExecutionRole \
  --use-kms true
  --dry-run
```

PowerShell (Windows):
```powershell
$env:ORG = "<ORG>"
$env:REPO = "<REPO>"
$env:ENV_NAME = "dev"
$env:AWS_REGION = "<PRIMARY_REGION>"
$env:STATE_BUCKET_NAME = "<STATE_BUCKET_NAME>"
$env:BOOTSTRAP_ROLE_NAME = "TerraformBootstrapRole"
$env:EXEC_ROLE_NAME = "TerraformExecutionRole"
$env:USE_KMS = "true"
$env:DRY_RUN = "true"

./infra/scripts/bootstrap-iam.ps1
```

PowerShell (parameters instead of env vars):
```powershell
./infra/scripts/bootstrap-iam.ps1 -Org <ORG> -Repo <REPO> -EnvName dev -AwsRegion <PRIMARY_REGION> -StateBucketName <STATE_BUCKET_NAME> -BootstrapRoleName TerraformBootstrapRole -ExecRoleName TerraformExecutionRole -UseKms true -DryRun
```

If you already have a KMS key ARN and want to lock permissions to it, set `STATE_KMS_KEY_ARN` before running the script. Otherwise the execution role grants KMS access scoped to the S3 bucket via `kms:ViaService` conditions.

### Manual fallback (optional)
If you cannot run the scripts, create the OIDC provider and two roles manually, then return to **Setup order** step 3.

1) Create the GitHub OIDC provider in each account:
```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

2) Create a bootstrap role with this trust policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:<ORG>/<REPO>:environment:<ENV>"
        }
      }
    }
  ]
}
```

3) Create an execution role with the same trust policy.
4) Attach least-privilege policies (see examples below).

### Example least-privilege IAM policies
Use these as a starting point and scope to your naming conventions. Some actions (e.g., `s3:CreateBucket`, `kms:CreateKey`) require `"Resource": "*"`.

Bootstrap role policy (backend creation):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CreateBucket",
      "Effect": "Allow",
      "Action": ["s3:CreateBucket"],
      "Resource": "*"
    },
    {
      "Sid": "StateBucketAdmin",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:GetBucketPolicy",
        "s3:GetBucketVersioning",
        "s3:GetBucketEncryption",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetBucketOwnershipControls",
        "s3:GetBucketLogging",
        "s3:GetBucketTagging",
        "s3:PutBucketPolicy",
        "s3:PutBucketVersioning",
        "s3:PutBucketEncryption",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketOwnershipControls",
        "s3:PutBucketLogging",
        "s3:PutBucketTagging"
      ],
      "Resource": "arn:aws:s3:::<STATE_BUCKET_NAME>"
    },
    {
      "Sid": "StateBucketObjects",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::<STATE_BUCKET_NAME>/*"
    },
    {
      "Sid": "KmsAdmin",
      "Effect": "Allow",
      "Action": [
        "kms:CreateKey",
        "kms:CreateAlias",
        "kms:DescribeKey",
        "kms:EnableKeyRotation",
        "kms:PutKeyPolicy",
        "kms:ScheduleKeyDeletion",
        "kms:TagResource",
        "kms:UntagResource"
      ],
      "Resource": "*"
    }
  ]
}
```

Execution role policy (state access):
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateBucketList",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::<STATE_BUCKET_NAME>"
    },
    {
      "Sid": "StateObjectsRW",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::<STATE_BUCKET_NAME>/*"
    },
    {
      "Sid": "KmsState",
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*",
        "kms:DescribeKey"
      ],
      "Resource": "<STATE_KMS_KEY_ARN>"
    }
  ]
}
```

Attach additional permissions required by your stacks (e.g., VPC, ECS, RDS). Scope them to your resource naming conventions and environments.

## Local execution policy
Local Terraform execution is disabled by default in `infra/scripts/tf` and `infra/scripts/tf.ps1`.
If you must run locally, set `ALLOW_LOCAL_TF=1` (break-glass only).

## Guardrails and safety
- `allowed_account_ids` in providers block wrong credentials.
- `check` blocks enforce account and region allow-lists.
- State buckets are isolated per environment and use lockfiles.

## Adding a new stack
1) Create `infra/live/<env>/<stack>` by copying `infra/live/dev/storage` and renaming the stack.
2) Update `main.tf`, `outputs.tf`, and any stack-specific files.
3) Add any new inputs as GitHub Environment secrets/vars (or local `terraform.tfvars` for break-glass use).
4) Run via CI (PR plan, merge apply) or Actions → **Terraform** → Run workflow.

## Notes
- State bucket naming follows: `<ORG_OR_PROJECT_PREFIX>-tfstate-<ENV>-<ACCOUNT_ID>-<PRIMARY_REGION>-<STATE_BUCKET_SUFFIX>`.
- DynamoDB locking is not used; lockfiles are enabled in backend configs.

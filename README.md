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

If you place this template under a monorepo folder like `infrastructure/`, set `TF_WORKDIR=infrastructure` as a GitHub Actions variable so workflows run from the right directory. The scripts resolve paths relative to their location, so running `./infrastructure/scripts/tf` works without edits.

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

## GitHub Actions credentials (OIDC)
These workflows require GitHub OIDC roles in each AWS account (dev, stage, prod). Create an OIDC provider and two roles per account: one for bootstrap and one for stack execution.

1) Create the GitHub OIDC provider in each account (once per account).
```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

2) Create a bootstrap role (one per account) with a trust policy like:
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

Attach permissions for bootstrap (S3 bucket creation, KMS if used, and bucket policy updates). Use a least-privilege policy scoped to the backend bucket naming pattern.

3) Create an execution role (one per account) with the same trust policy and permissions to read/write the state bucket, decrypt with the KMS key if used, and manage the resources in your stacks.

4) Set GitHub Environment variables for each environment: `AWS_REGION`, `AWS_BOOTSTRAP_ROLE_ARN`, and `AWS_ROLE_ARN`.

5) Run Actions: use **Terraform Bootstrap** for backend creation and **Terraform** for plan/apply.

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
        "s3:PutBucketPolicy",
        "s3:PutBucketVersioning",
        "s3:PutBucketEncryption",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketOwnershipControls",
        "s3:PutBucketLogging"
      ],
      "Resource": "arn:aws:s3:::<STATE_BUCKET_NAME>"
    },
    {
      "Sid": "StateBucketObjects",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
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

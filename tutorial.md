# Tutorial: Bootstrap and Run Dev Stack (CI-only)

This tutorial shows an end-to-end flow with real example values. It assumes CI-only execution and a public repo (no real values committed).

## 0) Assumptions
- You have admin access to the dev AWS account to create IAM roles and the OIDC provider.
- GitHub Actions is enabled for the repo.
- Local Terraform execution is disabled by default (by design).

## 1) Example values used in this tutorial
- GitHub org: `acme`
- Repo name: `terraform-aws-platform-template`
- Environment: `dev`
- AWS account ID: `111111111111`
- AWS region: `us-east-1`
- Org prefix: `acme-platform`
- State bucket suffix: `01`

Computed state bucket name:
`acme-platform-tfstate-dev-111111111111-us-east-1-01`

## 2) Admin: create IAM roles + OIDC provider (dev account)
Run this in the **dev AWS account** with admin credentials.

```bash
export ORG="acme"
export REPO="terraform-aws-platform-template"
export ENV_NAME="dev"
export AWS_REGION="us-east-1"
export STATE_BUCKET_NAME="acme-platform-tfstate-dev-111111111111-us-east-1-01"
export BOOTSTRAP_ROLE_NAME="TerraformBootstrapRole"
export EXEC_ROLE_NAME="TerraformExecutionRole"
export USE_KMS="true"

bash ./infra/scripts/bootstrap-iam.sh
```

The script outputs:
- GitHub Environment secrets/vars to set
- A `infra/bootstrap/dev.tfvars` snippet (for reference only; CI renders the file)

## 3) Admin: set GitHub Environment secrets
Go to GitHub → Settings → Environments → `dev` → Secrets.

Required secrets (example values):
- `TF_ORG_PREFIX = acme-platform`
- `AWS_ACCOUNT_ID = 111111111111`
- `AWS_REGION = us-east-1`
- `AWS_BOOTSTRAP_ROLE_ARN = arn:aws:iam::111111111111:role/TerraformBootstrapRole`
- `AWS_ROLE_ARN = arn:aws:iam::111111111111:role/TerraformExecutionRole`

Optional (example values):
- `TF_STATE_BUCKET_SUFFIX = 01`
- `TF_ALLOWED_REGIONS = us-east-1,us-east-2`
- `TF_EXTRA_TAGS_HCL = { Owner = "Platform" }`  (single-line HCL)
- `TF_ENABLE_ACCESS_LOGS = false`

Note: workflows read secrets first and fall back to vars if a secret is not set.

If you move `infra/` elsewhere, set:
- `TF_WORKDIR = <new/path>`

## 4) Bootstrap the backend (dev)
GitHub Actions → **Terraform Bootstrap** → Run workflow:
- `env`: `dev`
- `action`: `plan` (then run again with `apply`)

This creates the state bucket and (optionally) the KMS key.

## 5) Run the dev stack
Option A (recommended):
- Open a PR → plan runs automatically.
- Merge to `main` → apply runs with environment approvals.

Option B (manual):
- GitHub Actions → **Terraform** → Run workflow
- `env`: `dev`
- `stack`: `storage`
- `action`: `plan` or `apply`

## 6) Verify
- The state bucket exists in the dev account.
- The workflow logs show `terraform init`, `plan`, or `apply` completed successfully.
- Outputs for `infra/live/dev/storage` appear in the workflow logs.

## 7) Add your own components (dev stack)
1) Update `infra/live/dev/storage/main.tf` with your resources or create a new stack under `infra/live/dev/<stack>`.
2) If you add new Terraform input variables, add them to the workflow render step in `.github/workflows/terraform.yml` and provide values as GitHub secrets.
3) Open a PR to run plan, then merge to apply.

## 8) Troubleshooting
- **AccessDenied** during IAM script: the admin credentials need `iam:*` permissions listed in the README.
- **Wrong AWS account** error: `AWS_ACCOUNT_ID` or credentials do not match the environment.
- **Wrong region** error: `TF_ALLOWED_REGIONS` does not include `AWS_REGION` (spaces are trimmed).

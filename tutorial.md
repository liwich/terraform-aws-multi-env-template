# Tutorial: Bootstrap and Run Dev Stack

This tutorial shows an end-to-end flow with example values using the setup wizard.

## 0) Assumptions

- You have admin access to the dev AWS account (for IAM provisioning)
- GitHub Actions is enabled for the repo
- AWS CLI is installed and configured

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

## 2) Run the setup wizard

The setup wizard handles both IAM provisioning and config generation in one step.

```bash
cd infra
./scripts/setup.sh
```

**Wizard prompts:**

```
===========================================
  Terraform Accelerator Setup Wizard
===========================================

[INFO] Global Configuration

Organization/project prefix: acme-platform
Primary AWS region [us-east-1]: us-east-1
State bucket suffix for uniqueness: 01

Use KMS encryption for state bucket? (recommended for production) [y/N]: y
Enable S3 access logging for state bucket? [y/N]: n

[INFO] GitHub Repository (for OIDC role trust)
GitHub organization or username: acme
GitHub repository name: terraform-aws-platform-template

Provision IAM roles automatically? [y/N]: y
Dry run mode? [y/N]: n

[INFO] Environment Configuration
Configure each environment. Dev is required; stage/prod can be skipped by pressing Enter.

[INFO] === dev environment ===
AWS Account ID for dev: 111111111111
Bootstrap IAM Role name for dev [TerraformBootstrapRole]: 
Terraform Execution Role name for dev [TerraformExecutionRole]: 

[INFO] === stage environment ===
AWS Account ID for stage (Enter to skip): 
[WARN] Skipping stage environment

[INFO] === prod environment ===
AWS Account ID for prod (Enter to skip): 
[WARN] Skipping prod environment
```

The wizard will:
1. Create the GitHub OIDC provider in your AWS account
2. Create `TerraformBootstrapRole` and `TerraformExecutionRole`
3. Generate `bootstrap/dev.tfvars` and `bootstrap/dev.backend.hcl`
4. Generate `live/dev/storage/backend.hcl` and `terraform.tfvars`
5. Output GitHub secrets to configure

## 3) Configure GitHub Environment secrets

Go to GitHub → Settings → Environments → Create `dev` → Add secrets:

| Secret | Value |
|--------|-------|
| `AWS_REGION` | `us-east-1` |
| `AWS_BOOTSTRAP_ROLE_ARN` | `arn:aws:iam::111111111111:role/TerraformBootstrapRole` |
| `AWS_ROLE_ARN` | `arn:aws:iam::111111111111:role/TerraformExecutionRole` |

## 4) Commit and push

```bash
git add -A
git commit -m "Configure Terraform for acme-platform"
git push origin main
```

## 5) Bootstrap the backend (dev)

GitHub Actions → **Bootstrap** → Run workflow:
- `env`: `dev`

That's it! The workflow automatically:
1. Detects this is first run (bucket doesn't exist)
2. Creates the S3 bucket and KMS key
3. Creates the execution role IAM policy
4. Migrates bootstrap state to S3

You'll see: `Bootstrap complete! State migrated to S3.`

## 6) Run the dev stack

**Option A (recommended - PR workflow):**
1. Create a branch and make changes to `infra/live/dev/storage/`
2. Open a PR → plan runs automatically
3. Merge to `main` → apply runs

**Option B (manual dispatch):**
- GitHub Actions → **Terraform** → Run workflow
- `target`: `live`
- `env`: `dev`
- `stack`: `storage`
- `action`: `plan` or `apply`

## 7) Verify

- The state bucket exists in the dev account
- Workflow logs show successful `terraform init`, `plan`, or `apply`
- Outputs appear in the workflow logs

## 8) Adding permissions for new resources

If you need to deploy new resource types (EC2, Lambda, etc.), update the execution role policy:

1. Edit `infra/bootstrap/dev.tfvars`:
   ```hcl
   extra_execution_policy_statements = [
     {
       Sid      = "EC2Management"
       Effect   = "Allow"
       Action   = ["ec2:Describe*", "ec2:CreateVpc", "ec2:DeleteVpc"]
       Resource = "*"
     }
   ]
   ```

2. Run the **Bootstrap** workflow again to apply the policy change

3. Now your live infrastructure can use EC2 resources

## 9) Add your own stacks

1. Copy an existing stack:
   ```bash
   cp -r infra/live/dev/storage infra/live/dev/newstack
   ```

2. Update `backend.hcl` with new state key:
   ```hcl
   key = "dev/newstack/terraform.tfstate"
   ```

3. Update `main.tf` for your resources

4. Add to workflow matrix in `.github/workflows/terraform.yml`:
   ```yaml
   matrix:
     stack: [storage, newstack]
   ```

5. Open a PR to run plan, merge to apply

## 10) Troubleshooting

| Issue | Solution |
|-------|----------|
| AccessDenied during setup | Ensure AWS credentials have IAM admin permissions |
| Wrong AWS account error | Check `expected_account_id` in tfvars matches your credentials |
| Wrong region error | Check `allowed_regions` includes your `primary_region` |
| State bucket not found | Run the Bootstrap workflow first |
| Missing S3 permissions | Check `enable_s3_permissions = true` in bootstrap tfvars |
| Need new resource permissions | Add to `extra_execution_policy_statements` and run Bootstrap |

## 11) Local execution (break-glass only)

Local Terraform is disabled by default. For emergencies:

```bash
export ALLOW_LOCAL_TF=1
cd infra
./scripts/tf env=dev stack=storage plan
```

#!/usr/bin/env bash
set -euo pipefail

#######################################
# Terraform Accelerator Setup Wizard
# Generates configuration files and optionally provisions IAM roles
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

fail() { log_error "$1"; exit 1; }

# Check for required commands
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

# Prompt for input with default
prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local value

  if [ -n "$default" ]; then
    read -rp "$prompt_text [$default]: " value
    value="${value:-$default}"
  else
    read -rp "$prompt_text: " value
  fi

  eval "$var_name=\"$value\""
}

# Prompt yes/no
prompt_yn() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-n}"
  local value

  read -rp "$prompt_text [y/N]: " value
  value="${value:-$default}"
  
  if [[ "$value" =~ ^[Yy] ]]; then
    eval "$var_name=true"
  else
    eval "$var_name=false"
  fi
}

# Validate AWS account ID format
validate_account_id() {
  local id="$1"
  if [[ ! "$id" =~ ^[0-9]{12}$ ]]; then
    log_error "Invalid AWS account ID: $id (must be 12 digits)"
    return 1
  fi
  return 0
}

# Validate org prefix format
validate_org_prefix() {
  local prefix="$1"
  if [[ ! "$prefix" =~ ^[a-z0-9-]+$ ]] || [ ${#prefix} -lt 3 ]; then
    log_error "Invalid org_prefix: $prefix (must be 3+ chars, lowercase alphanumeric and hyphens)"
    return 1
  fi
  return 0
}

# Provision OIDC provider and IAM roles for an environment
provision_iam() {
  local env="$1"
  local account_id="$2"
  local region="$3"
  local bucket_name="$4"
  local bootstrap_role="$5"
  local exec_role="$6"
  local github_org="$7"
  local github_repo="$8"
  local use_kms="$9"
  local dry_run="${10:-false}"

  log_info "Provisioning IAM for $env environment..."

  # Verify credentials match expected account
  local current_account
  current_account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
    || fail "Failed to call sts:get-caller-identity. Check AWS credentials."
  
  if [ "$current_account" != "$account_id" ]; then
    log_warn "Current AWS credentials are for account $current_account, not $account_id"
    log_warn "Skipping IAM provisioning for $env. Switch credentials and re-run, or provision manually."
    return 1
  fi

  # Check/create OIDC provider
  local provider_arn=""
  local provider_list
  provider_list="$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>&1)" \
    || fail "Missing iam:ListOpenIDConnectProviders permission"

  for arn in $provider_list; do
    [ -z "$arn" ] && continue
    [ "$arn" = "None" ] && continue
    local url
    url="$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" --query Url --output text 2>/dev/null)" || continue
    if [ "$url" = "token.actions.githubusercontent.com" ]; then
      provider_arn="$arn"
      break
    fi
  done

  if [ -z "$provider_arn" ]; then
    if [ "$dry_run" = "true" ]; then
      provider_arn="arn:aws:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com"
      log_info "[dry-run] Would create OIDC provider: $provider_arn"
    else
      log_info "Creating GitHub OIDC provider..."
      provider_arn="$(aws iam create-open-id-connect-provider \
        --url https://token.actions.githubusercontent.com \
        --client-id-list sts.amazonaws.com \
        --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
        --query OpenIDConnectProviderArn --output text)" || fail "Failed to create OIDC provider"
      log_success "Created OIDC provider"
    fi
  else
    log_success "OIDC provider already exists"
  fi

  # Trust policy for roles
  local trust_policy
  trust_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${provider_arn}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:${github_org}/${github_repo}:environment:${env}"
        }
      }
    }
  ]
}
EOF
)

  # Create roles
  ensure_role() {
    local role_name="$1"
    local get_out=""
    if get_out=$(aws iam get-role --role-name "$role_name" 2>&1); then
      log_success "Role exists: $role_name"
      return 0
    fi
    if echo "$get_out" | grep -qi "NoSuchEntity"; then
      if [ "$dry_run" = "true" ]; then
        log_info "[dry-run] Would create role: $role_name"
        return 0
      fi
      log_info "Creating role: $role_name..."
      aws iam create-role --role-name "$role_name" --assume-role-policy-document "$trust_policy" >/dev/null \
        || fail "Failed to create role $role_name"
      log_success "Created role: $role_name"
      return 0
    fi
    fail "Missing iam:GetRole permission for $role_name"
  }

  ensure_role "$bootstrap_role"
  ensure_role "$exec_role"

  # Bootstrap role policy
  local bootstrap_kms_stmt=""
  if [ "$use_kms" = "true" ]; then
    bootstrap_kms_stmt=',
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
        "kms:UntagResource",
        "kms:ListAliases",
        "kms:DeleteAlias",
        "kms:UpdateAlias"
      ],
      "Resource": "*"
    }'
  fi

  local bootstrap_policy
  bootstrap_policy=$(cat <<EOF
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
      "Sid": "ListAllBuckets",
      "Effect": "Allow",
      "Action": ["s3:ListAllMyBuckets"],
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
        "s3:GetBucketAcl",
        "s3:PutBucketPolicy",
        "s3:PutBucketVersioning",
        "s3:PutBucketEncryption",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketOwnershipControls",
        "s3:PutBucketLogging",
        "s3:PutBucketTagging"
      ],
      "Resource": "arn:aws:s3:::${bucket_name}"
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
      "Resource": "arn:aws:s3:::${bucket_name}/*"
    }${bootstrap_kms_stmt}
  ]
}
EOF
)

  # Execution role policy
  local exec_kms_stmt=""
  if [ "$use_kms" = "true" ]; then
    exec_kms_stmt=",
    {
      \"Sid\": \"KmsStateViaS3\",
      \"Effect\": \"Allow\",
      \"Action\": [
        \"kms:Encrypt\",
        \"kms:Decrypt\",
        \"kms:GenerateDataKey*\",
        \"kms:ReEncrypt*\",
        \"kms:DescribeKey\"
      ],
      \"Resource\": \"*\",
      \"Condition\": {
        \"StringEquals\": {
          \"kms:ViaService\": \"s3.${region}.amazonaws.com\"
        },
        \"StringLike\": {
          \"kms:EncryptionContext:aws:s3:arn\": \"arn:aws:s3:::${bucket_name}/*\"
        }
      }
    }"
  fi

  local exec_policy
  exec_policy=$(cat <<EOF
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
      "Resource": "arn:aws:s3:::${bucket_name}"
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
      "Resource": "arn:aws:s3:::${bucket_name}/*"
    }${exec_kms_stmt}
  ]
}
EOF
)

  # Attach policies
  if [ "$dry_run" = "true" ]; then
    log_info "[dry-run] Would attach TerraformBootstrapPolicy to $bootstrap_role"
    log_info "[dry-run] Would attach TerraformExecutionPolicy to $exec_role"
  else
    log_info "Attaching policies..."
    aws iam put-role-policy --role-name "$bootstrap_role" --policy-name TerraformBootstrapPolicy --policy-document "$bootstrap_policy" \
      || fail "Failed to attach policy to $bootstrap_role"
    aws iam put-role-policy --role-name "$exec_role" --policy-name TerraformExecutionPolicy --policy-document "$exec_policy" \
      || fail "Failed to attach policy to $exec_role"
    log_success "Attached IAM policies"
  fi

  log_success "IAM provisioning complete for $env"
  return 0
}

# Default values
DEFAULT_REGION="us-east-1"
DEFAULT_STACKS="storage"

echo ""
echo "==========================================="
echo "  Terraform Accelerator Setup Wizard"
echo "==========================================="
echo ""

# Gather global configuration
log_info "Global Configuration"
echo ""

prompt ORG_PREFIX "Organization/project prefix (lowercase, e.g., 'acme' or 'myproject')"
validate_org_prefix "$ORG_PREFIX" || exit 1

prompt PRIMARY_REGION "Primary AWS region" "$DEFAULT_REGION"
prompt STATE_BUCKET_SUFFIX "State bucket suffix for uniqueness (optional, press Enter to skip)" ""

# GitHub repository info for OIDC
echo ""
log_info "GitHub Repository (for OIDC role trust)"
prompt GITHUB_ORG "GitHub organization or username"
prompt GITHUB_REPO "GitHub repository name"

# Ask about IAM provisioning
echo ""
prompt_yn PROVISION_IAM "Provision IAM roles automatically? (requires AWS CLI with admin access)"

if [ "$PROVISION_IAM" = "true" ]; then
  need_cmd aws
  prompt_yn DRY_RUN "Dry run mode? (show what would be created without making changes)"
fi

echo ""
log_info "Environment Configuration"
echo ""
echo "Configure each environment (dev, stage, prod). Enter 'skip' to skip an environment."
echo ""

declare -A ENV_ACCOUNTS
declare -A ENV_BOOTSTRAP_ROLES
declare -A ENV_EXEC_ROLES
declare -A ENV_BUCKETS

for env in dev stage prod; do
  echo ""
  log_info "=== $env environment ==="
  prompt account_id "AWS Account ID for $env (or 'skip')"
  
  if [ "$account_id" = "skip" ]; then
    log_warn "Skipping $env environment"
    continue
  fi
  
  validate_account_id "$account_id" || exit 1
  ENV_ACCOUNTS[$env]="$account_id"
  
  prompt bootstrap_role "Bootstrap IAM Role name for $env" "TerraformBootstrapRole"
  ENV_BOOTSTRAP_ROLES[$env]="$bootstrap_role"
  
  prompt exec_role "Terraform Execution Role name for $env" "TerraformExecutionRole"
  ENV_EXEC_ROLES[$env]="$exec_role"
  
  # Compute bucket name
  if [ -n "$STATE_BUCKET_SUFFIX" ]; then
    bucket_name="${ORG_PREFIX}-tfstate-${env}-${account_id}-${PRIMARY_REGION}-${STATE_BUCKET_SUFFIX}"
  else
    bucket_name="${ORG_PREFIX}-tfstate-${env}-${account_id}-${PRIMARY_REGION}"
  fi
  ENV_BUCKETS[$env]="$bucket_name"
done

# Provision IAM if requested
if [ "$PROVISION_IAM" = "true" ]; then
  echo ""
  log_info "Provisioning IAM resources..."
  echo ""
  
  for env in "${!ENV_ACCOUNTS[@]}"; do
    provision_iam \
      "$env" \
      "${ENV_ACCOUNTS[$env]}" \
      "$PRIMARY_REGION" \
      "${ENV_BUCKETS[$env]}" \
      "${ENV_BOOTSTRAP_ROLES[$env]}" \
      "${ENV_EXEC_ROLES[$env]}" \
      "$GITHUB_ORG" \
      "$GITHUB_REPO" \
      "true" \
      "${DRY_RUN:-false}" || true
    echo ""
  done
fi

echo ""
log_info "Generating configuration files..."
echo ""

# Generate bootstrap configs for each environment
for env in "${!ENV_ACCOUNTS[@]}"; do
  account_id="${ENV_ACCOUNTS[$env]}"
  bootstrap_role="${ENV_BOOTSTRAP_ROLES[$env]}"
  exec_role="${ENV_EXEC_ROLES[$env]}"
  bucket_name="${ENV_BUCKETS[$env]}"
  
  # Bootstrap tfvars
  cat > "${ROOT_DIR}/bootstrap/${env}.tfvars" <<EOF
org_prefix = "${ORG_PREFIX}"
env        = "${env}"
account_id = "${account_id}"

primary_region      = "${PRIMARY_REGION}"
state_bucket_suffix = "${STATE_BUCKET_SUFFIX}"

use_kms            = true
enable_access_logs = false
log_bucket_name    = null
log_bucket_prefix  = "tfstate/"

aws_profile     = null
assume_role_arn = null

state_bucket_admin_principals = ["arn:aws:iam::${account_id}:role/${bootstrap_role}"]
state_bucket_rw_principals    = ["arn:aws:iam::${account_id}:role/${exec_role}"]
kms_admin_principals          = ["arn:aws:iam::${account_id}:role/${bootstrap_role}"]

extra_tags = {}
EOF
  log_success "Created bootstrap/${env}.tfvars"
  
  # Bootstrap backend.hcl
  cat > "${ROOT_DIR}/bootstrap/${env}.backend.hcl" <<EOF
bucket       = "${bucket_name}"
key          = "bootstrap/terraform.tfstate"
region       = "${PRIMARY_REGION}"
encrypt      = true
use_lockfile = true
EOF
  log_success "Created bootstrap/${env}.backend.hcl"
  
  # Live stack configs
  for stack in $DEFAULT_STACKS; do
    stack_dir="${ROOT_DIR}/live/${env}/${stack}"
    
    if [ ! -d "$stack_dir" ]; then
      log_warn "Stack directory not found: live/${env}/${stack}, skipping"
      continue
    fi
    
    # backend.hcl
    cat > "${stack_dir}/backend.hcl" <<EOF
bucket       = "${bucket_name}"
key          = "${env}/${stack}/terraform.tfstate"
region       = "${PRIMARY_REGION}"
encrypt      = true
use_lockfile = true
EOF
    log_success "Created live/${env}/${stack}/backend.hcl"
    
    # terraform.tfvars
    cat > "${stack_dir}/terraform.tfvars" <<EOF
env                 = "${env}"
org_prefix          = "${ORG_PREFIX}"
expected_account_id = "${account_id}"

primary_region  = "${PRIMARY_REGION}"
allowed_regions = ["${PRIMARY_REGION}"]

assume_role_arn = null
aws_profile     = null

example_bucket_suffix = ""

extra_tags = {}
EOF
    log_success "Created live/${env}/${stack}/terraform.tfvars"
  done
done

echo ""
echo "==========================================="
echo "  Setup Complete!"
echo "==========================================="
echo ""

log_info "GitHub Environment Secrets (configure in repository settings):"
echo ""
echo "For each environment (dev, stage, prod), set these secrets:"
for env in "${!ENV_ACCOUNTS[@]}"; do
  account_id="${ENV_ACCOUNTS[$env]}"
  bootstrap_role="${ENV_BOOTSTRAP_ROLES[$env]}"
  exec_role="${ENV_EXEC_ROLES[$env]}"
  echo ""
  echo "  Environment: ${env}"
  echo "    AWS_REGION: ${PRIMARY_REGION}"
  echo "    AWS_ACCOUNT_ID: ${account_id}"
  echo "    AWS_BOOTSTRAP_ROLE_ARN: arn:aws:iam::${account_id}:role/${bootstrap_role}"
  echo "    AWS_ROLE_ARN: arn:aws:iam::${account_id}:role/${exec_role}"
done

echo ""
log_info "Next steps:"
echo ""
echo "1. Commit the generated configuration files:"
echo "   git add -A && git commit -m 'Configure Terraform for ${ORG_PREFIX}'"
echo ""
echo "2. Configure GitHub Environment secrets (see above)"
echo ""
echo "3. Push to GitHub and run the bootstrap workflow:"
echo "   - Go to Actions → Terraform → Run workflow"
echo "   - Select: target=bootstrap, env=dev, action=apply, bootstrap-phase=initial"
echo "   - After successful apply, run again with bootstrap-phase=migrate"
echo ""
log_success "Configuration complete!"

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/render-stack-config.sh <env> <stack>

Required environment variables:
  TF_ORG_PREFIX
  AWS_ACCOUNT_ID
  AWS_REGION

Optional environment variables:
  TF_STATE_BUCKET_SUFFIX
  TF_ALLOWED_REGIONS (comma-separated)
  TF_STATE_KMS_KEY_ARN
  TF_EXAMPLE_BUCKET_SUFFIX
  TF_EXTRA_TAGS_HCL (single-line HCL map)
EOF
}

if [ $# -lt 2 ]; then
  usage
  exit 1
fi

env_name="$1"
stack_name="$2"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="${TF_ROOT:-$(cd "${script_dir}/.." && pwd)}"

: "${TF_ORG_PREFIX?Missing TF_ORG_PREFIX}"
: "${AWS_ACCOUNT_ID?Missing AWS_ACCOUNT_ID}"
: "${AWS_REGION?Missing AWS_REGION}"

stack_dir="${root_dir}/live/${env_name}/${stack_name}"
backend_file="${stack_dir}/backend.hcl"
tfvars_file="${stack_dir}/terraform.tfvars"

if [ ! -d "$stack_dir" ]; then
  echo "Stack directory not found: $stack_dir" >&2
  exit 1
fi

suffix="${TF_STATE_BUCKET_SUFFIX:-}"
if [ -n "$suffix" ]; then
  bucket_name="${TF_ORG_PREFIX}-tfstate-${env_name}-${AWS_ACCOUNT_ID}-${AWS_REGION}-${suffix}"
else
  bucket_name="${TF_ORG_PREFIX}-tfstate-${env_name}-${AWS_ACCOUNT_ID}-${AWS_REGION}"
fi

kms_line=""
if [ -n "${TF_STATE_KMS_KEY_ARN:-}" ]; then
  kms_line="kms_key_id   = \"${TF_STATE_KMS_KEY_ARN}\""
fi

cat > "$backend_file" <<EOF
bucket         = "$bucket_name"
key            = "${env_name}/${stack_name}/terraform.tfstate"
region         = "$AWS_REGION"
encrypt        = true
use_lockfile   = true
${kms_line}
EOF

allowed_regions="${TF_ALLOWED_REGIONS:-$AWS_REGION}"
allowed_hcl=""
IFS=',' read -ra regions <<< "$allowed_regions"
for region in "${regions[@]}"; do
  region="${region//[[:space:]]/}"
  [ -z "$region" ] && continue
  if [ -z "$allowed_hcl" ]; then
    allowed_hcl="\"$region\""
  else
    allowed_hcl="$allowed_hcl, \"$region\""
  fi
done
if [ -z "$allowed_hcl" ]; then
  allowed_hcl="\"$AWS_REGION\""
fi

extra_tags="${TF_EXTRA_TAGS_HCL:-{}}"
example_suffix="${TF_EXAMPLE_BUCKET_SUFFIX:-}"

cat > "$tfvars_file" <<EOF
env                 = "$env_name"
org_prefix          = "$TF_ORG_PREFIX"
expected_account_id = "$AWS_ACCOUNT_ID"

primary_region = "$AWS_REGION"
allowed_regions = [${allowed_hcl}]

assume_role_arn = null
aws_profile     = null

example_bucket_suffix = "$example_suffix"

extra_tags = ${extra_tags}
EOF

#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "Error: $1" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

need_cmd aws

usage() {
  cat <<'EOF'
Usage:
  ./scripts/bootstrap-iam.sh --org ORG --repo REPO --env ENV --region AWS_REGION --state-bucket STATE_BUCKET_NAME [options]

Required:
  --org ORG
  --repo REPO
  --env ENV                      (dev|stage|prod)
  --region AWS_REGION
  --state-bucket STATE_BUCKET_NAME

Optional:
  --account-id ACCOUNT_ID         (verify credentials match)
  --bootstrap-role ROLE_NAME      (default: TerraformBootstrapRole)
  --exec-role ROLE_NAME           (default: TerraformExecutionRole)
  --use-kms true|false            (default: true)
  --state-kms-key-arn ARN
  --dry-run                       (print actions without making changes)

You can also provide these via environment variables:
  ORG, REPO, ENV_NAME, AWS_REGION, STATE_BUCKET_NAME, ACCOUNT_ID,
  BOOTSTRAP_ROLE_NAME, EXEC_ROLE_NAME, USE_KMS, TF_USE_KMS,
  TF_WORKDIR, TF_ORG_PREFIX, TF_STATE_BUCKET_SUFFIX, TF_ENABLE_ACCESS_LOGS,
  TF_LOG_BUCKET_NAME, TF_LOG_BUCKET_PREFIX, TF_EXTRA_TAGS_HCL,
  STATE_KMS_KEY_ARN, DRY_RUN
EOF
}

ORG="${ORG:-}"
REPO="${REPO:-}"
ENV_NAME="${ENV_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
ACCOUNT_ID_INPUT="${ACCOUNT_ID:-}"
STATE_BUCKET_NAME="${STATE_BUCKET_NAME:-}"
BOOTSTRAP_ROLE_NAME="${BOOTSTRAP_ROLE_NAME:-TerraformBootstrapRole}"
EXEC_ROLE_NAME="${EXEC_ROLE_NAME:-TerraformExecutionRole}"
TF_WORKDIR="${TF_WORKDIR:-infra}"
TF_STATE_BUCKET_SUFFIX="${TF_STATE_BUCKET_SUFFIX:-}"
TF_ENABLE_ACCESS_LOGS="${TF_ENABLE_ACCESS_LOGS:-false}"
TF_LOG_BUCKET_NAME="${TF_LOG_BUCKET_NAME:-}"
TF_LOG_BUCKET_PREFIX="${TF_LOG_BUCKET_PREFIX:-tfstate/}"
TF_EXTRA_TAGS_HCL="${TF_EXTRA_TAGS_HCL:-}"
TF_USE_KMS="${TF_USE_KMS:-}"
USE_KMS="${USE_KMS:-${TF_USE_KMS:-true}}"
STATE_KMS_KEY_ARN="${STATE_KMS_KEY_ARN:-}"
DRY_RUN="${DRY_RUN:-false}"

while [ $# -gt 0 ]; do
  case "$1" in
    --org) ORG="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --env) ENV_NAME="$2"; shift 2 ;;
    --region) AWS_REGION="$2"; shift 2 ;;
    --state-bucket) STATE_BUCKET_NAME="$2"; shift 2 ;;
    --account-id) ACCOUNT_ID_INPUT="$2"; shift 2 ;;
    --bootstrap-role) BOOTSTRAP_ROLE_NAME="$2"; shift 2 ;;
    --exec-role) EXEC_ROLE_NAME="$2"; shift 2 ;;
    --use-kms) USE_KMS="$2"; shift 2 ;;
    --state-kms-key-arn) STATE_KMS_KEY_ARN="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

TF_ORG_PREFIX="${TF_ORG_PREFIX:-$ORG}"

if [ -z "$ORG" ] || [ -z "$REPO" ] || [ -z "$ENV_NAME" ] || [ -z "$AWS_REGION" ] || [ -z "$STATE_BUCKET_NAME" ]; then
  usage
  fail "Missing required inputs"
fi

is_dry_run="false"
if [ "$DRY_RUN" = "true" ] || [ "$DRY_RUN" = "1" ]; then
  is_dry_run="true"
fi

account_id="$(aws sts get-caller-identity --query Account --output text)" || fail "Failed to call sts:get-caller-identity. Check AWS credentials."
if [ -n "$ACCOUNT_ID_INPUT" ] && [ "$ACCOUNT_ID_INPUT" != "$account_id" ]; then
  fail "ACCOUNT_ID ($ACCOUNT_ID_INPUT) does not match current credentials ($account_id)"
fi

provider_list="$(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>&1)" \
  || fail "Missing iam:ListOpenIDConnectProviders permission"

provider_arn=""
for arn in $provider_list; do
  [ -z "$arn" ] && continue
  [ "$arn" = "None" ] && continue
  url="$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" --query Url --output text 2>&1)"
  if [ $? -ne 0 ]; then
    if echo "$url" | grep -qi "AccessDenied"; then
      fail "Missing iam:GetOpenIDConnectProvider permission"
    fi
    continue
  fi
  if [ "$url" = "token.actions.githubusercontent.com" ]; then
    provider_arn="$arn"
    break
  fi
done

if [ -z "$provider_arn" ]; then
  if [ "$is_dry_run" = "true" ]; then
    provider_arn="arn:aws:iam::${account_id}:oidc-provider/token.actions.githubusercontent.com"
    echo "[dry-run] Would create OIDC provider: $provider_arn"
  else
    provider_arn="$(aws iam create-open-id-connect-provider \
      --url https://token.actions.githubusercontent.com \
      --client-id-list sts.amazonaws.com \
      --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
      --query OpenIDConnectProviderArn --output text)" || fail "Failed to create OIDC provider"
  fi
fi

trust_policy="$(cat <<EOF
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
          "token.actions.githubusercontent.com:sub": "repo:${ORG}/${REPO}:environment:${ENV_NAME}"
        }
      }
    }
  ]
}
EOF
)"

ensure_role() {
  local role_name="$1"
  local get_out=""
  if get_out=$(aws iam get-role --role-name "$role_name" 2>&1); then
    echo "Role exists: $role_name (skipping create)"
    return
  fi
  if echo "$get_out" | grep -qi "NoSuchEntity"; then
    if [ "$is_dry_run" = "true" ]; then
      echo "[dry-run] Would create role: $role_name"
      return
    fi
    aws iam create-role --role-name "$role_name" --assume-role-policy-document "$trust_policy" >/dev/null \
      || fail "Missing iam:CreateRole permission for $role_name"
    return
  fi
  fail "Missing iam:GetRole permission for $role_name"
}

ensure_role "$BOOTSTRAP_ROLE_NAME"
ensure_role "$EXEC_ROLE_NAME"

bootstrap_kms_stmt=""
if [ "$USE_KMS" = "true" ] || [ "$USE_KMS" = "1" ]; then
  bootstrap_kms_stmt="$(cat <<'EOF'
,
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
EOF
)"
fi

bootstrap_policy="$(cat <<EOF
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
      "Resource": "arn:aws:s3:::${STATE_BUCKET_NAME}"
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
      "Resource": "arn:aws:s3:::${STATE_BUCKET_NAME}/*"
    }${bootstrap_kms_stmt}
  ]
}
EOF
)"

exec_kms_stmt=""
if [ -n "$STATE_KMS_KEY_ARN" ]; then
  exec_kms_stmt="$(cat <<EOF
,
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
      "Resource": "${STATE_KMS_KEY_ARN}"
    }
EOF
)"
elif [ "$USE_KMS" = "true" ] || [ "$USE_KMS" = "1" ]; then
  exec_kms_stmt="$(cat <<EOF
,
    {
      "Sid": "KmsStateViaS3",
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey*",
        "kms:ReEncrypt*",
        "kms:DescribeKey"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "s3.${AWS_REGION}.amazonaws.com"
        },
        "StringLike": {
          "kms:EncryptionContext:aws:s3:arn": "arn:aws:s3:::${STATE_BUCKET_NAME}/*"
        }
      }
    }
EOF
)"
fi

exec_policy="$(cat <<EOF
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
      "Resource": "arn:aws:s3:::${STATE_BUCKET_NAME}"
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
      "Resource": "arn:aws:s3:::${STATE_BUCKET_NAME}/*"
    }${exec_kms_stmt}
  ]
}
EOF
)"

if [ "$is_dry_run" = "true" ]; then
  echo "[dry-run] Would attach inline policy TerraformBootstrapPolicy to $BOOTSTRAP_ROLE_NAME"
  echo "[dry-run] Would attach inline policy TerraformExecutionPolicy to $EXEC_ROLE_NAME"
else
  aws iam put-role-policy --role-name "$BOOTSTRAP_ROLE_NAME" --policy-name TerraformBootstrapPolicy --policy-document "$bootstrap_policy" \
    || fail "Missing iam:PutRolePolicy permission for $BOOTSTRAP_ROLE_NAME"
  aws iam put-role-policy --role-name "$EXEC_ROLE_NAME" --policy-name TerraformExecutionPolicy --policy-document "$exec_policy" \
    || fail "Missing iam:PutRolePolicy permission for $EXEC_ROLE_NAME"
fi

use_kms_bool="false"
if [ "$USE_KMS" = "true" ] || [ "$USE_KMS" = "1" ]; then
  use_kms_bool="true"
fi

extra_tags_out="${TF_EXTRA_TAGS_HCL:-{}}"

echo "OIDC provider: $provider_arn"
echo "Bootstrap role: arn:aws:iam::${account_id}:role/${BOOTSTRAP_ROLE_NAME}"
echo "Execution role: arn:aws:iam::${account_id}:role/${EXEC_ROLE_NAME}"
echo "Set GitHub Environment variables:"
echo "  TF_WORKDIR=${TF_WORKDIR}"
echo "  TF_ORG_PREFIX=${TF_ORG_PREFIX}"
echo "  TF_STATE_BUCKET_SUFFIX=${TF_STATE_BUCKET_SUFFIX}"
echo "  TF_ENABLE_ACCESS_LOGS=${TF_ENABLE_ACCESS_LOGS}"
echo "  TF_LOG_BUCKET_NAME=${TF_LOG_BUCKET_NAME}"
echo "  TF_LOG_BUCKET_PREFIX=${TF_LOG_BUCKET_PREFIX}"
echo "  TF_USE_KMS=${use_kms_bool}"
echo "  TF_EXTRA_TAGS_HCL=${extra_tags_out}"
echo "  AWS_ACCOUNT_ID=${account_id}"
echo "  AWS_REGION=${AWS_REGION}"
echo "  AWS_BOOTSTRAP_ROLE_ARN=arn:aws:iam::${account_id}:role/${BOOTSTRAP_ROLE_NAME}"
echo "  AWS_ROLE_ARN=arn:aws:iam::${account_id}:role/${EXEC_ROLE_NAME}"

cat <<EOF

Bootstrap tfvars values (append to infra/bootstrap/${ENV_NAME}.tfvars):
env        = "${ENV_NAME}"
account_id = "${account_id}"
primary_region = "${AWS_REGION}"
assume_role_arn = "arn:aws:iam::${account_id}:role/${BOOTSTRAP_ROLE_NAME}"
state_bucket_admin_principals = ["arn:aws:iam::${account_id}:role/${BOOTSTRAP_ROLE_NAME}"]
state_bucket_rw_principals = ["arn:aws:iam::${account_id}:role/${EXEC_ROLE_NAME}"]
kms_admin_principals = ["arn:aws:iam::${account_id}:role/${BOOTSTRAP_ROLE_NAME}"]
use_kms = ${use_kms_bool}

Keep org_prefix and state_bucket_suffix aligned with your naming standard.
EOF

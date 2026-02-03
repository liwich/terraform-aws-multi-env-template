org_prefix = "<ORG_OR_PROJECT_PREFIX>"
env        = "dev"
account_id = "<DEV_ACCOUNT_ID>"

primary_region      = "<PRIMARY_REGION>"
state_bucket_suffix = "<STATE_BUCKET_SUFFIX>" # Optional extra suffix for global uniqueness.

use_kms            = true
enable_access_logs = false
log_bucket_name    = "<CENTRAL_LOG_BUCKET_NAME>" # Required if enable_access_logs = true.
log_bucket_prefix  = "tfstate/"

aws_profile     = "<LOCAL_AWS_PROFILE>" # Optional for local use; set to null in CI.
assume_role_arn = "arn:aws:iam::<DEV_ACCOUNT_ID>:role/<BOOTSTRAP_ROLE_NAME>"

state_bucket_admin_principals = [
  "arn:aws:iam::<DEV_ACCOUNT_ID>:role/<TF_STATE_ADMIN_ROLE_NAME>"
]

state_bucket_rw_principals = [
  "arn:aws:iam::<DEV_ACCOUNT_ID>:role/<TF_STATE_RW_ROLE_NAME>"
]

kms_admin_principals = [
  "arn:aws:iam::<DEV_ACCOUNT_ID>:role/<KMS_ADMIN_ROLE_NAME>"
]

extra_tags = {
  Owner = "<TEAM_NAME>"
}

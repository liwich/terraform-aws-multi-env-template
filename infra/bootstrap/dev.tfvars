org_prefix = "liwich"
env        = "dev"
account_id = "123456789455"

primary_region      = "us-west-2"
state_bucket_suffix = "01"

use_kms            = false
enable_access_logs = false
log_bucket_name    = null
log_bucket_prefix  = "tfstate/"

aws_profile     = null
assume_role_arn = null

state_bucket_admin_principals = ["arn:aws:iam::123456789455:role/TerraformBootstrapRole1"]
state_bucket_rw_principals    = ["arn:aws:iam::123456789455:role/TerraformExecutionRole1"]
kms_admin_principals          = ["arn:aws:iam::123456789455:role/TerraformBootstrapRole1"]

extra_tags = {}

#######################################
# Execution Role Policy (managed by Terraform)
#######################################

manage_execution_role_policy = true
execution_role_name          = "TerraformExecutionRole1"

# S3 permissions automatically scoped to ${org_prefix}-* buckets
enable_s3_permissions = true

# Add extra permissions here (EC2, Lambda, DynamoDB, etc.)
extra_execution_policy_statements = []

org_prefix = "liwich"
env        = "dev"
account_id = "262764262296"

primary_region      = "us-west-2"
state_bucket_suffix = ""

use_kms            = false
enable_access_logs = false
log_bucket_name    = null
log_bucket_prefix  = "tfstate/"

aws_profile     = null
assume_role_arn = null

state_bucket_admin_principals = ["arn:aws:iam::262764262296:role/TerraformBootstrapRole"]
state_bucket_rw_principals    = ["arn:aws:iam::262764262296:role/TerraformExecutionRole"]
kms_admin_principals          = ["arn:aws:iam::262764262296:role/TerraformBootstrapRole"]

extra_tags = {}

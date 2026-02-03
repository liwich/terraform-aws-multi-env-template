env                 = "dev"
org_prefix          = "<ORG_OR_PROJECT_PREFIX>"
expected_account_id = "<DEV_ACCOUNT_ID>"

primary_region = "<PRIMARY_REGION>"
allowed_regions = [
  "<PRIMARY_REGION>"
]

assume_role_arn = "arn:aws:iam::<DEV_ACCOUNT_ID>:role/<TERRAFORM_EXEC_ROLE_NAME>"
aws_profile     = "<LOCAL_AWS_PROFILE>" # Optional for local use; set to null in CI.

example_bucket_suffix = "<OPTIONAL_BUCKET_SUFFIX>"

extra_tags = {
  Owner = "<TEAM_NAME>"
}

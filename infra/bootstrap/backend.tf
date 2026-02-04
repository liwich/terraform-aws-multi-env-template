# Backend configuration for bootstrap state persistence.
# First run: terraform init -backend=false
# After bucket creation: terraform init -migrate-state -backend-config=backend.hcl
terraform {
  backend "s3" {}
}

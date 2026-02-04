variable "env" {
  type        = string
  description = "Environment name: dev, stage, or prod."

  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env must be one of: dev, stage, prod."
  }
}

variable "org_prefix" {
  type        = string
  description = "Org or project prefix used in naming."

  validation {
    condition     = length(var.org_prefix) > 2 && can(regex("^[a-z0-9-]+$", var.org_prefix))
    error_message = "org_prefix must be at least 3 characters and use only lowercase letters, numbers, and hyphens."
  }
}

variable "expected_account_id" {
  type        = string
  description = "Expected AWS account ID for this environment."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must be a 12-digit AWS account ID."
  }
}

variable "primary_region" {
  type        = string
  description = "Primary AWS region for this stack."
}

variable "allowed_regions" {
  type        = list(string)
  description = "Allow-list of regions for this stack."

  validation {
    condition     = length(var.allowed_regions) > 0
    error_message = "allowed_regions must include at least one region."
  }
}

variable "aws_profile" {
  type        = string
  description = "Optional AWS CLI profile for local use."
  default     = null
}

variable "assume_role_arn" {
  type        = string
  description = "Optional role ARN to assume for this stack."
  default     = null
}

variable "example_bucket_suffix" {
  type        = string
  description = "Optional suffix to ensure unique example bucket names."
  default     = ""
}

variable "extra_tags" {
  type        = map(string)
  description = "Extra tags applied to all resources."
  default     = {}
}

variable "org_prefix" {
  type        = string
  description = "Org or project prefix used in naming. Lowercase letters, numbers, and hyphens only."

  validation {
    condition     = length(var.org_prefix) > 2 && can(regex("^[a-z0-9-]+$", var.org_prefix))
    error_message = "org_prefix must be at least 3 characters and use only lowercase letters, numbers, and hyphens."
  }
}

variable "env" {
  type        = string
  description = "Environment name: dev, stage, or prod."

  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env must be one of: dev, stage, prod."
  }
}

variable "account_id" {
  type        = string
  description = "AWS account ID for the target environment."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "primary_region" {
  type        = string
  description = "Primary AWS region for the state bucket."
}

variable "state_bucket_suffix" {
  type        = string
  description = "Optional extra suffix to guarantee global uniqueness."
  default     = ""

  validation {
    condition     = can(regex("^[a-z0-9-]*$", var.state_bucket_suffix))
    error_message = "state_bucket_suffix may only include lowercase letters, numbers, and hyphens."
  }
}

variable "use_kms" {
  type        = bool
  description = "Enable SSE-KMS for the state bucket."
  default     = true
}

variable "kms_admin_principals" {
  type        = list(string)
  description = "Additional IAM principals with admin access to the KMS key."
  default     = []
}

variable "state_bucket_admin_principals" {
  type        = list(string)
  description = "Additional IAM principals with admin access to the state bucket."
  default     = []
}

variable "state_bucket_rw_principals" {
  type        = list(string)
  description = "IAM principals with read/write access to the state bucket objects."
  default     = []
}

variable "enable_access_logs" {
  type        = bool
  description = "Enable S3 access logging to a pre-existing central log bucket."
  default     = false
}

variable "log_bucket_name" {
  type        = string
  description = "Pre-existing log bucket name for access logs. Required when enable_access_logs is true."
  default     = null

  validation {
    condition     = var.enable_access_logs == false || (var.log_bucket_name != null && var.log_bucket_name != "")
    error_message = "log_bucket_name must be set when enable_access_logs is true."
  }
}

variable "log_bucket_prefix" {
  type        = string
  description = "Prefix inside the log bucket for state bucket access logs."
  default     = "tfstate/"
}

variable "aws_profile" {
  type        = string
  description = "Optional AWS CLI profile for local use."
  default     = null
}

variable "assume_role_arn" {
  type        = string
  description = "Optional role ARN to assume for bootstrap operations."
  default     = null
}

variable "extra_tags" {
  type        = map(string)
  description = "Extra tags applied to all bootstrap resources."
  default     = {}
}

#######################################
# Execution Role Policy Management
#######################################

variable "manage_execution_role_policy" {
  type        = bool
  description = "Whether bootstrap should manage the execution role's IAM policy. Set to true after the role exists."
  default     = false
}

variable "execution_role_name" {
  type        = string
  description = "Name of the Terraform execution role to attach policies to."
  default     = "TerraformExecutionRole"
}

variable "enable_s3_permissions" {
  type        = bool
  description = "Grant S3 management permissions scoped to org_prefix-* buckets. Automatically uses var.org_prefix."
  default     = true
}

variable "extra_execution_policy_statements" {
  type        = list(any)
  description = <<-EOT
    Additional IAM policy statements for the execution role.
    Use this for permissions beyond the built-in S3 permissions.
    
    Example:
    [
      {
        Sid      = "EC2Management"
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "ec2:CreateVpc", "ec2:DeleteVpc"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = ["us-east-1"]
          }
        }
      },
      {
        Sid      = "LambdaManagement"
        Effect   = "Allow"
        Action   = ["lambda:*"]
        Resource = "arn:aws:lambda:*:*:function:myprefix-*"
      }
    ]
  EOT
  default     = []
}

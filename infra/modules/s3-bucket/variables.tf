variable "name" {
  type        = string
  description = "Name of the S3 bucket."
}

variable "force_destroy" {
  type        = bool
  description = "Allow force destroy of the bucket."
  default     = false
}

variable "versioning" {
  type        = bool
  description = "Enable versioning on the bucket."
  default     = true
}

variable "sse_algorithm" {
  type        = string
  description = "SSE algorithm: AES256 or aws:kms."
  default     = "AES256"

  validation {
    condition     = contains(["AES256", "aws:kms"], var.sse_algorithm)
    error_message = "sse_algorithm must be AES256 or aws:kms."
  }
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key ARN used when sse_algorithm is aws:kms."
  default     = null

  validation {
    condition     = var.sse_algorithm != "aws:kms" || (var.kms_key_arn != null && var.kms_key_arn != "")
    error_message = "kms_key_arn must be set when sse_algorithm is aws:kms."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to the bucket."
  default     = {}
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "app_name" {
  description = "Application name"
  type        = string
}

# Remote state configuration for storage stack
variable "storage_state_bucket" {
  description = "S3 bucket containing the storage stack's Terraform state"
  type        = string
}

variable "storage_state_key" {
  description = "S3 key for the storage stack's Terraform state"
  type        = string
}

variable "storage_state_region" {
  description = "Region of the storage state bucket"
  type        = string
}

variable "container_image" {
  description = "Docker image for the FastAPI application"
  type        = string
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 8000
}

variable "cpu" {
  description = "Fargate task CPU units"
  type        = number
  default     = 256
}

variable "memory" {
  description = "Fargate task memory in MB"
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Number of tasks to run"
  type        = number
  default     = 1
}

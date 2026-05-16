variable "aws_region" {
  description = "AWS region for Shaka Terraform backend infrastructure."
  type        = string
  default     = "ap-northeast-2"
}

variable "environment" {
  description = "Environment name for tagging backend infrastructure."
  type        = string
  default     = "prod"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Shaka production Terraform state. Must match terraform/environments/prod backend config."
  type        = string
  default     = "dannawagyu-shaka-prod-terraform-state"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name."
  }
}

variable "lock_table_name" {
  description = "DynamoDB table name for Terraform S3 backend state locking. Must match terraform/environments/prod backend config."
  type        = string
  default     = "shaka-prod-terraform-locks"

  validation {
    condition     = length(var.lock_table_name) >= 3 && length(var.lock_table_name) <= 255
    error_message = "lock_table_name must be between 3 and 255 characters."
  }
}

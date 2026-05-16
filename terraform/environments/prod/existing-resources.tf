variable "existing_app_instance_id" {
  description = "Existing Shaka production EC2 app host instance ID. Production Terraform must reference this host instead of creating a replacement EC2 instance."
  type        = string

  validation {
    condition     = can(regex("^i-[0-9a-f]+$", var.existing_app_instance_id))
    error_message = "existing_app_instance_id must be a valid EC2 instance ID such as i-0123456789abcdef0."
  }
}

variable "existing_app_security_group_id" {
  description = "Security group ID attached to the existing Shaka production app host; RDS ingress is restricted to this group."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.existing_app_security_group_id))
    error_message = "existing_app_security_group_id must be a valid security group ID such as sg-0123456789abcdef0."
  }
}

data "aws_instance" "existing_app" {
  instance_id = var.existing_app_instance_id
}

data "aws_subnet" "existing_public" {
  id = data.aws_instance.existing_app.subnet_id
}

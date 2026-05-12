variable "existing_app_instance_id" {
  description = "Existing Shaka production EC2 app host instance ID to reference before any import."
  type        = string
  default     = null
}

variable "existing_public_subnet_id" {
  description = "Existing public subnet ID that currently hosts the Shaka EC2 app server."
  type        = string
  default     = null
}

data "aws_instance" "existing_app" {
  count       = var.existing_app_instance_id == null ? 0 : 1
  instance_id = var.existing_app_instance_id
}

data "aws_security_group" "existing_app" {
  id = var.app_security_group_id
}

data "aws_vpc" "existing" {
  id = var.vpc_id
}

data "aws_subnet" "existing_public" {
  count = var.existing_public_subnet_id == null ? 0 : 1
  id    = var.existing_public_subnet_id
}

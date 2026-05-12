variable "aws_region" {
  description = "AWS region containing the existing Shaka production networking resources."
  type        = string
  default     = "ap-northeast-2"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prod"
}

variable "vpc_id" {
  description = "Existing VPC ID for Shaka production. This PR references/imports existing networking instead of creating a new VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs for the RDS DB subnet group. Use at least two subnets in different AZs when available while keeping the DB instance Single-AZ."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "Provide at least two private subnet IDs for the RDS DB subnet group."
  }
}

variable "app_security_group_id" {
  description = "Existing Shaka app EC2 security group ID allowed to connect to RDS on TCP/3306."
  type        = string
}

variable "database_name" {
  description = "Initial non-secret database name for the Shaka production RDS instance."
  type        = string
  default     = "shaka"
}

variable "db_username" {
  description = "RDS master username. Supply via environment variable, secrets manager workflow, or local tfvars that must never be committed."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "RDS master password. Supply via environment variable, secrets manager workflow, or local tfvars that must never be committed."
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "Low-cost RDS instance class. Default is Graviton db.t4g.micro; use db.t3.micro only as a documented fallback if t4g is unavailable in the selected region."
  type        = string
  default     = "db.t4g.micro"

  validation {
    condition     = contains(["db.t4g.micro", "db.t3.micro"], var.db_instance_class)
    error_message = "Use db.t4g.micro by default, or db.t3.micro as the documented fallback."
  }
}

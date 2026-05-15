variable "aws_region" {
  description = "AWS region for Shaka production infrastructure."
  type        = string
  default     = "ap-northeast-2"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prod"
}

variable "vpc_id" {
  description = "Existing VPC ID for Shaka production. This stack creates EC2/RDS inside the existing VPC rather than replacing networking."
  type        = string
}

variable "public_subnet_id" {
  description = "Existing public subnet ID for the Shaka EC2 app host."
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

variable "operator_ssh_cidr" {
  description = "CIDR allowed to SSH to the EC2 app host. Use a single operator IP/CIDR, never 0.0.0.0/0."
  type        = string

  validation {
    condition     = var.operator_ssh_cidr != "0.0.0.0/0"
    error_message = "operator_ssh_cidr must not be 0.0.0.0/0."
  }
}

variable "ssh_key_name" {
  description = "Existing EC2 key pair name for emergency SSH access."
  type        = string
}

variable "app_ami_id" {
  description = "Ubuntu 24.04 AMI ID for the Shaka app host. Resolve and pin before apply."
  type        = string
}

variable "app_instance_type" {
  description = "Low-cost EC2 instance type for the Shaka app host."
  type        = string
  default     = "t3.micro"

  validation {
    condition     = contains(["t3.micro", "t4g.micro"], var.app_instance_type)
    error_message = "Use t3.micro by default, or t4g.micro only after confirming the AMI/architecture path."
  }
}

variable "app_root_volume_size_gb" {
  description = "Root EBS volume size for the app host."
  type        = number
  default     = 20
}

variable "database_name" {
  description = "Initial non-secret database name for the Shaka production RDS instance."
  type        = string
  default     = "shaka"
}

variable "db_username" {
  description = "RDS master username. Supply through GitHub production environment secrets or local uncommitted environment variables."
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "RDS master password. Supply through GitHub production environment secrets or local uncommitted environment variables."
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

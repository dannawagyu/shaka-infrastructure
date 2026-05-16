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

variable "vpc_cidr" {
  description = "CIDR block for the Terraform-managed Shaka production VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "availability_zones" {
  description = "Two availability zones for the app public subnet and RDS private subnet group. First AZ hosts the EC2 app and preferred RDS AZ."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Provide at least two availability zones for the RDS DB subnet group."
  }
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet that hosts the Shaka EC2 app server."
  type        = string
  default     = "10.42.0.0/24"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private RDS subnets. Provide at least two private subnets in different AZs."
  type        = list(string)
  default     = ["10.42.10.0/24", "10.42.11.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "Provide at least two private subnet CIDRs for the RDS DB subnet group."
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

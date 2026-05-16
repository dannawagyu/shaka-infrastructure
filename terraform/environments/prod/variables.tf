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

variable "availability_zones" {
  description = "Two availability zones for RDS private subnet group in the existing Shaka app VPC."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "Provide at least two availability zones for the RDS DB subnet group."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private RDS subnets in the existing Shaka app VPC. Provide at least two non-overlapping private subnets in different AZs."
  type        = list(string)
  default     = ["10.42.10.0/24", "10.42.11.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "Provide at least two private subnet CIDRs for the RDS DB subnet group."
  }
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

variable "db_engine_version" {
  description = "RDS MySQL engine version. Use the MySQL 8.0 family so AWS selects a supported regional minor version."
  type        = string
  default     = "8.0"

  validation {
    condition     = can(regex("^8\\.0", var.db_engine_version))
    error_message = "Use the MySQL 8.0 engine family for Shaka production RDS."
  }
}

variable "db_backup_retention_period" {
  description = "RDS automated backup retention in days. Default is 1 to satisfy the current AWS account free-tier restriction; increase later after account plan/cost review."
  type        = number
  default     = 1

  validation {
    condition     = var.db_backup_retention_period >= 1 && var.db_backup_retention_period <= 7
    error_message = "Use 1-7 days for the low-cost Shaka production RDS backup retention period."
  }
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

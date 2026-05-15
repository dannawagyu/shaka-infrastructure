output "vpc_id" {
  description = "Terraform-managed Shaka production VPC ID."
  value       = aws_vpc.shaka.id
}

output "public_subnet_id" {
  description = "Terraform-managed public app subnet ID."
  value       = aws_subnet.app_public.id
}

output "private_subnet_ids" {
  description = "Terraform-managed private RDS subnet IDs."
  value       = aws_subnet.rds_private[*].id
}

output "app_instance_id" {
  description = "Terraform-managed Shaka production EC2 instance ID."
  value       = aws_instance.app.id
}

output "app_public_ip" {
  description = "Public IPv4 address for the Shaka production EC2 app host."
  value       = aws_instance.app.public_ip
}

output "app_security_group_id" {
  description = "Terraform-managed Shaka app security group ID."
  value       = aws_security_group.app.id
}

output "rds_endpoint" {
  description = "Shaka production RDS writer endpoint hostname."
  value       = aws_db_instance.shaka.address
}

output "rds_port" {
  description = "Shaka production RDS MySQL port."
  value       = aws_db_instance.shaka.port
}

output "database_name" {
  description = "Initial Shaka production database name."
  value       = aws_db_instance.shaka.db_name
}

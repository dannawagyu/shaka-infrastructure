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

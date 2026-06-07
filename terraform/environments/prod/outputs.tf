output "vpc_id" {
  description = "Existing Shaka production VPC ID that hosts the app EC2 instance."
  value       = data.aws_subnet.existing_public.vpc_id
}

output "public_subnet_id" {
  description = "Existing public subnet ID for the Shaka production EC2 app host."
  value       = data.aws_instance.existing_app.subnet_id
}

output "private_subnet_ids" {
  description = "Terraform-managed private RDS subnet IDs in the existing app VPC."
  value       = aws_subnet.rds_private[*].id
}

output "app_instance_id" {
  description = "Existing Shaka production EC2 app host instance ID."
  value       = data.aws_instance.existing_app.id
}

output "app_public_ip" {
  description = "Public IPv4 address for the existing Shaka production EC2 app host."
  value       = data.aws_instance.existing_app.public_ip
}

output "app_security_group_id" {
  description = "Existing Shaka app security group ID allowed to reach RDS."
  value       = var.existing_app_security_group_id
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

output "alb_dns_name" {
  description = "Public DNS name of the Shaka production ALB. Point the application CNAME record at this value."
  value       = aws_lb.shaka.dns_name
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the production ALB for Route53 alias records, if used."
  value       = aws_lb.shaka.zone_id
}

output "alb_access_logs_bucket" {
  description = "S3 bucket holding production ALB access logs."
  value       = aws_s3_bucket.alb_access_logs.id
}

output "acm_certificate_validation_records" {
  description = "DNS CNAME records to add at the external DNS provider to validate the ALB ACM certificate."
  value = [
    for record in aws_acm_certificate.alb.domain_validation_options : {
      name  = record.resource_record_name
      type  = record.resource_record_type
      value = record.resource_record_value
    }
  ]
}

output "state_bucket_name" {
  description = "S3 bucket that stores Shaka production Terraform state."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "S3 bucket ARN for IAM policy scoping."
  value       = aws_s3_bucket.terraform_state.arn
}

output "access_log_bucket_name" {
  description = "S3 bucket that stores server access logs for the Terraform state bucket."
  value       = aws_s3_bucket.terraform_state_logs.id
}

output "access_log_bucket_arn" {
  description = "S3 access log bucket ARN for IAM policy scoping."
  value       = aws_s3_bucket.terraform_state_logs.arn
}

output "lock_table_name" {
  description = "DynamoDB table used for Terraform state locking."
  value       = aws_dynamodb_table.terraform_locks.name
}

output "lock_table_arn" {
  description = "DynamoDB lock table ARN for IAM policy scoping."
  value       = aws_dynamodb_table.terraform_locks.arn
}

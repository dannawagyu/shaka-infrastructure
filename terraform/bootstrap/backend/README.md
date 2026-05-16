# Shaka production Terraform backend bootstrap

This root module creates the privileged storage used by `terraform/environments/prod` for remote state. It intentionally uses local state for the one-time bootstrap because the backend must exist before the production root can initialize against it.

## What it creates

- S3 bucket: `dannawagyu-shaka-prod-terraform-state` by default
- DynamoDB lock table: `shaka-prod-terraform-locks` by default
- S3 bucket versioning
- S3 server-side encryption (`AES256`)
- S3 public access block with all four controls enabled
- S3 bucket-owner-enforced object ownership
- S3 bucket policy denying non-TLS access
- S3 lifecycle rule that aborts incomplete multipart uploads after 7 days and transitions noncurrent state object versions to Standard-IA after 90 days without expiring them
- DynamoDB on-demand billing, `LockID` hash key, server-side encryption, point-in-time recovery, and deletion protection

The S3 bucket and DynamoDB table use Terraform `prevent_destroy` because losing backend state can strand or corrupt production infrastructure management.

## Bootstrap commands

Run this only with approved AWS credentials for the Shaka production account:

```bash
cd terraform/bootstrap/backend
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
terraform apply
```

If the default bucket name is already taken globally, set a unique name in an ignored local tfvars file or `TF_VAR_state_bucket_name`, then update `terraform/environments/prod/providers.tf` to match before initializing production. The static guardrail tests intentionally verify that the bootstrap default and production backend block stay in sync, so update both places in the same PR if the bucket name changes.

## Verification commands

```bash
aws s3api get-bucket-versioning \
  --bucket dannawagyu-shaka-prod-terraform-state

aws s3api get-bucket-encryption \
  --bucket dannawagyu-shaka-prod-terraform-state

aws s3api get-public-access-block \
  --bucket dannawagyu-shaka-prod-terraform-state

aws dynamodb describe-table \
  --table-name shaka-prod-terraform-locks \
  --query 'Table.{TableName:TableName,BillingMode:BillingModeSummary.BillingMode,HashKey:KeySchema[0].AttributeName,SSE: SSEDescription.Status}'
```

Expected results:

- bucket versioning status is `Enabled`
- bucket encryption uses `AES256`
- all public access block booleans are `true`
- DynamoDB table exists with hash key `LockID`

## Production root initialization

After bootstrap succeeds, initialize the production root against the remote backend:

```bash
cd terraform/environments/prod
terraform init -reconfigure
terraform validate
terraform plan -var-file=production.local.tfvars
```

If production local state already exists, migrate it only after explicit operator approval and a state backup:

```bash
cp terraform.tfstate terraform.tfstate.pre-remote-backend-backup
terraform init -migrate-state
```

Do not commit `.terraform/`, `terraform.tfstate*`, `*.tfvars`, generated plans, or backend credentials.

## Stuck lock recovery

Use `terraform force-unlock <LOCK_ID>` only after confirming no active local terminal or GitHub Actions workflow is running `plan` or `apply` for the same state.

# Shaka Infrastructure

Terraform baseline for Shaka production AWS infrastructure.

## Layout

- `terraform/environments/prod/` - production environment Terraform root module.
- `scripts/validate-prod-terraform.sh` - local validation entrypoint.
- `tests/terraform_static_checks.py` - static guardrail checks for issue #1 acceptance criteria.

## Production baseline

This first PR intentionally keeps scope small and low cost:

- References existing Shaka VPC, private subnets, and app EC2 security group through variables.
- Creates a private, Single-AZ MySQL RDS instance.
- Defaults to `db.t4g.micro`; `db.t3.micro` is allowed only as a documented fallback if Graviton/T4g is unavailable in the selected region.
- Uses 20 GiB of encrypted GP3 storage with no Multi-AZ, no NAT Gateway, no RDS Proxy, and no cross-region backup/replication.
- Allows inbound MySQL only from the existing Shaka app EC2 security group.

## Existing EC2/VPC import or reference path

The existing Shaka app EC2 stack is not Terraform-managed in this first PR. Provide the existing AWS IDs at plan/apply time:

- `vpc_id`
- `private_subnet_ids`
- `app_security_group_id`

If a future PR brings existing resources under Terraform management, use `terraform import` into explicit resources or modules before replacing these reference variables. Do not recreate production networking just to satisfy Terraform ownership.

## State and secrets handling

Terraform state can contain sensitive values, including RDS credentials and provider-derived attributes. Treat state as a secret:

- Do not commit `.terraform/`, `terraform.tfstate*`, `*.tfvars`, generated plans, or credentials.
- Use a remote backend with encryption, access controls, locking, and least-privilege IAM before production apply. This repository does not configure a backend yet so validation can run with `terraform init -backend=false`.
- Provide `db_username` and `db_password` through a secure workflow such as environment variables (`TF_VAR_db_username`, `TF_VAR_db_password`), a local ignored `.tfvars` file, or a secrets manager integration. Never commit secret variable files.
- Review generated plans carefully because plan files can also contain sensitive values.

## Safe workflow

From `terraform/environments/prod/`:

```bash
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform plan \
  -var='vpc_id=vpc-...' \
  -var='private_subnet_ids=["subnet-...","subnet-..."]' \
  -var='app_security_group_id=sg-...'
```

Do not run `terraform apply` until a production remote backend and secret handling workflow are approved.

## Guarded deletion behavior

Production database deletion is intentionally guarded by both AWS RDS `deletion_protection = true` and Terraform `lifecycle.prevent_destroy = true`. Destroying or replacing the database requires an explicit code change and review to remove or bypass these safeguards, plus a final snapshot. This is a deliberate safety gate for production data.

## Outputs

Terraform outputs expose only non-secret operational values:

- `rds_endpoint`
- `rds_port`
- `database_name`

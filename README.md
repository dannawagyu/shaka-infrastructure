# Shaka Infrastructure

Terraform baseline for Shaka production AWS infrastructure.

## Layout

- `terraform/environments/prod/` - production environment Terraform root module.
- `scripts/validate-prod-terraform.sh` - local validation entrypoint.
- `tests/terraform_static_checks.py` - static guardrail checks for issue #1 acceptance criteria.

## Production baseline

This first PR intentionally keeps scope small and low cost:

- References the existing Shaka VPC and subnets through variables instead of recreating networking.
- Creates the production EC2 app host and the private, Single-AZ MySQL RDS instance in one Terraform stack so the final cutover can be a reviewed EC2 + RDS apply.
- Creates a Terraform-managed app security group for SSH/HTTP/HTTPS only, with IMDSv2 required on the EC2 instance.
- Defaults RDS to `db.t4g.micro`; `db.t3.micro` is allowed only as a documented fallback if Graviton/T4g is unavailable in the selected region.
- Uses 20 GiB of encrypted GP3 storage with modest autoscaling, no Multi-AZ, no NAT Gateway, no RDS Proxy, and no cross-region backup/replication.
- Allows inbound MySQL only from the Terraform-managed Shaka app EC2 security group.

## Existing EC2/VPC import or reference path

This stack now manages the replacement/cutover EC2 app host and RDS together, but it still does not recreate production networking. Provide the existing AWS IDs at plan/apply time:

- `vpc_id`
- `public_subnet_id`
- `private_subnet_ids`
- `operator_ssh_cidr`
- `ssh_key_name`
- `app_ami_id`

The prior EC2 can still be referenced through optional `existing_app_instance_id` / `existing_public_subnet_id` variables for inventory and no-op review before the cutover. If a future PR brings additional existing resources under Terraform management, use `terraform import` into explicit resources or modules before replacing these reference variables. Do not recreate production networking just to satisfy Terraform ownership.

## State and secrets handling

Terraform state can contain sensitive values, including RDS credentials and provider-derived attributes. Treat state as a secret:

- Do not commit `.terraform/`, `terraform.tfstate*`, `*.tfvars`, generated plans, or credentials.
- Use a remote backend with encryption, access controls, locking, and least-privilege IAM before production apply. This repository does not configure a backend yet so validation can run with `terraform init -backend=false`.
- Provide `db_username` and `db_password` through GitHub Environment `production` secrets (`SHAKA_DB_USERNAME`, `SHAKA_DB_PASSWORD` mapped to `TF_VAR_*`), local ignored `.tfvars`, or another approved secrets manager integration. Never commit secret variable files.
- Do not pass Grafana Cloud remote-write credentials through Terraform `user_data`; the EC2 bootstrap reads them from `/etc/alloy/grafana-cloud.env` so they can be injected by the production deployment path without landing in Terraform state.
- Review generated plans carefully because plan files can also contain sensitive values.

## Safe workflow

From `terraform/environments/prod/`:

```bash
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
terraform plan \
  -var='vpc_id=vpc-...' \
  -var='public_subnet_id=subnet-public...' \
  -var='private_subnet_ids=["subnet-private-a","subnet-private-b"]' \
  -var='operator_ssh_cidr=203.0.113.10/32' \
  -var='ssh_key_name=shaka-production' \
  -var='app_ami_id=ami-...' \
  -var='db_username=...' \
  -var='db_password=...'
```

Do not run `terraform apply` until a production remote backend and secret handling workflow are approved. In GitHub Actions, use the `production` environment workflow in `.github/workflows/terraform-production.yml`; it requires `apply_confirmation=apply-production` for applies.

## Guarded deletion behavior

Production database deletion is intentionally guarded by both AWS RDS `deletion_protection = true` and Terraform `lifecycle.prevent_destroy = true`. Destroying or replacing the database requires an explicit code change and review to remove or bypass these safeguards, plus a final snapshot. This is a deliberate safety gate for production data.

## Outputs

Terraform outputs expose only non-secret operational values:

- `app_instance_id`
- `app_public_ip`
- `app_security_group_id`
- `rds_endpoint`
- `rds_port`
- `database_name`

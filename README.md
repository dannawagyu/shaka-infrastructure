# Shaka Infrastructure

Terraform baseline for Shaka production AWS infrastructure.

## Layout

- `terraform/bootstrap/backend/` - one-time bootstrap root for the production Terraform remote backend.
- `terraform/environments/prod/` - production environment Terraform root module.
- `scripts/validate-prod-terraform.sh` - local validation entrypoint.
- `tests/terraform_static_checks.py` - static guardrail checks for issue #1 and #11 acceptance criteria.

## Production baseline

This first PR intentionally keeps scope small and low cost:

- Creates a Terraform-managed production VPC, public app subnet, private RDS subnets, Internet Gateway, route tables, and security groups.
- Creates the production EC2 app host and the private, Single-AZ MySQL RDS instance in one Terraform stack so the final cutover can be a reviewed VPC + EC2 + RDS apply.
- Creates a Terraform-managed app security group for SSH/HTTP/HTTPS only, with IMDSv2 required on the EC2 instance.
- Defaults RDS to `db.t4g.micro`; `db.t3.micro` is allowed only as a documented fallback if Graviton/T4g is unavailable in the selected region.
- Uses 20 GiB of encrypted GP3 storage with modest autoscaling, no Multi-AZ, no NAT Gateway, no RDS Proxy, and no cross-region backup/replication.
- Allows inbound MySQL only from the Terraform-managed Shaka app EC2 security group. RDS has no public access path; DataGrip access should use SSH tunneling through the EC2 host.

## Existing EC2/VPC import or reference path

This stack now manages the replacement/cutover VPC, EC2 app host, and RDS together. Fill production values in an ignored local file before local plan/apply:

```text
terraform/environments/prod/production.local.tfvars
```

Start by copying:

```bash
cp terraform/environments/prod/production.tfvars.example terraform/environments/prod/production.local.tfvars
```

At minimum Auden/operator should fill:

- `operator_ssh_cidr`
- `ssh_key_name`
- `app_ami_id`
- `db_username`
- `db_password`

The VPC/subnet CIDR defaults can remain unless they overlap another network:

- `vpc_cidr = "10.42.0.0/16"`
- `public_subnet_cidr = "10.42.0.0/24"`
- `private_subnet_cidrs = ["10.42.10.0/24", "10.42.11.0/24"]`

The prior EC2/VPC can still be referenced through optional `existing_app_instance_id`, `existing_vpc_id`, and `existing_public_subnet_id` variables for inventory and no-op review before the cutover. If a future PR brings additional existing resources under Terraform management, use `terraform import` into explicit resources or modules before replacing these reference variables.

## State and secrets handling

Terraform state can contain sensitive values, including RDS credentials and provider-derived attributes. Treat state as a secret:

- Do not commit `.terraform/`, `terraform.tfstate*`, `*.tfvars`, generated plans, or credentials.
- Production Terraform now expects the encrypted S3 remote backend created by `terraform/bootstrap/backend/`: bucket `dannawagyu-shaka-prod-terraform-state`, state key `prod/terraform.tfstate`, region `ap-northeast-2`, and DynamoDB lock table `shaka-prod-terraform-locks`.
- The backend bucket has versioning, server-side encryption, bucket-owner-enforced ownership, public access block, and a non-TLS deny policy; the lock table uses `LockID` with on-demand billing and server-side encryption.
- Bootstrap the backend once from `terraform/bootstrap/backend/` using approved AWS credentials, then run `terraform init -reconfigure` from `terraform/environments/prod/`.
- If local production state already exists, run `terraform init -migrate-state` only after Auden/operator approval and a local state backup. Otherwise initialize fresh remote state.
- Provide `db_username` and `db_password` through GitHub Environment `production` secrets (`SHAKA_DB_USERNAME`, `SHAKA_DB_PASSWORD` mapped to `TF_VAR_*`), local ignored `.tfvars`, or another approved secrets manager integration. Never commit secret variable files.
- Do not pass Grafana Cloud remote-write credentials through Terraform `user_data`; the EC2 bootstrap reads them from `/etc/alloy/grafana-cloud.env` so they can be injected by the production deployment path without landing in Terraform state.
- Review generated plans carefully because plan files can also contain sensitive values.

## Safe workflow

From `terraform/environments/prod/`:

```bash
cd terraform/bootstrap/backend
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan
terraform apply

cd ../../environments/prod
terraform init -reconfigure
terraform fmt -check -recursive
terraform validate
terraform plan \
  -var-file=production.local.tfvars
```

For static validation without contacting the remote backend, `./scripts/validate-prod-terraform.sh` still uses `terraform init -backend=false` in `terraform/environments/prod/`.

Do not enable production `terraform apply` in GitHub Actions until Auden approves the EC2/RDS cutover workflow separately. The current production workflow remains manual and plan-only even after the remote backend exists.

## Guarded deletion behavior

Production database deletion is intentionally guarded by both AWS RDS `deletion_protection = true` and Terraform `lifecycle.prevent_destroy = true`. Destroying or replacing the database requires an explicit code change and review to remove or bypass these safeguards, plus a final snapshot. This is a deliberate safety gate for production data.

## Outputs

Terraform outputs expose only non-secret operational values:

- `vpc_id`
- `public_subnet_id`
- `private_subnet_ids`
- `app_instance_id`
- `app_public_ip`
- `app_security_group_id`
- `rds_endpoint`
- `rds_port`
- `database_name`

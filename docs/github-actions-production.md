# GitHub Actions production environment

This repository uses a dedicated GitHub Environment named `production` for Terraform production runs. The workflow is `.github/workflows/terraform-production.yml` and is manual-only (`workflow_dispatch`).

## Required production environment variables

Set these as GitHub Environment **variables** on `production` because they are non-secret identifiers. For local testing, put equivalent Terraform values in the ignored file `terraform/environments/prod/production.local.tfvars`:

- `AWS_REGION` (default-compatible value: `ap-northeast-2`)
- `SHAKA_EXISTING_APP_INSTANCE_ID` (required existing fixed-IP/domain EC2 app host, mapped to `existing_app_instance_id`)
- `SHAKA_EXISTING_APP_SECURITY_GROUP_ID` (required app host security group allowed to reach RDS, mapped to `existing_app_security_group_id`)
- `SHAKA_AVAILABILITY_ZONES_JSON` (optional JSON array, defaults to `["ap-northeast-2a","ap-northeast-2c"]`)
- `SHAKA_PRIVATE_SUBNET_CIDRS_JSON` (optional JSON array, defaults to `["10.42.10.0/24","10.42.11.0/24"]`; these CIDRs must fit inside the existing app VPC and must not overlap existing subnets)
- `SHAKA_DATABASE_NAME` (optional, defaults to `shaka`)

Do not set `SHAKA_APP_AMI_ID`, `SHAKA_APP_INSTANCE_TYPE`, `SHAKA_SSH_KEY_NAME`, or app public subnet/VPC CIDR variables for the current production root. Terraform must reference the existing EC2 host; it must not create a replacement fixed-IP/domain app server.

## Required production environment secrets

Set these as GitHub Environment **secrets** on `production`:

- Preferred AWS auth: `AWS_ROLE_TO_ASSUME` for OIDC-based auth.
- Fallback AWS auth if OIDC is not configured yet: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.
- RDS bootstrap credentials: `SHAKA_DB_USERNAME`, `SHAKA_DB_PASSWORD`.
- Grafana Cloud runtime credentials for the existing EC2 host/pipeline path: `GRAFANA_PROMETHEUS_REMOTE_WRITE_URL`, `GRAFANA_PROMETHEUS_REMOTE_WRITE_USER`, `GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN`.

Do not commit real `*.tfvars`, Terraform plans, Terraform state, DB credentials, Grafana tokens, Discord webhooks, or AWS credentials.

## Local production value file

For local plans, copy the example file and edit only the ignored local copy:

```bash
cd /Users/dannawagyu/hermes-workspace/repos/shaka-infrastructure/terraform/environments/prod
cp production.tfvars.example production.local.tfvars
```

Then fill `production.local.tfvars`. Do not commit it. The most important values are `existing_app_instance_id`, `existing_app_security_group_id`, `db_username`, and `db_password`. Keep the default private subnet CIDRs only if they fit inside the existing app VPC and do not overlap another VPC subnet, VPN, office network, or Tailscale-routed range.

## RDS/DataGrip access

RDS is private and accepts MySQL only from the existing EC2 app security group. Do not open RDS to an operator IP. For DataGrip, use an SSH tunnel through the EC2 host and connect to the RDS endpoint through that tunnel.

## Backend bootstrap and apply gates

The workflow supports four manual commands:

- `plan`: production root plan only. This initializes `terraform/environments/prod` against the remote backend and runs `terraform plan`; it does not apply app/RDS infrastructure.
- `apply`: production root plan + apply. This requires `apply_confirmation=apply-production`, uses the `production` GitHub Environment plus `AWS_ROLE_TO_ASSUME`, and applies only the exact `production.tfplan` generated earlier in the same run.
- `bootstrap-backend-plan`: plans only the one-time backend bootstrap root at `terraform/bootstrap/backend`.
- `bootstrap-backend-apply`: applies only the backend bootstrap root. This requires `apply_confirmation=bootstrap-production-backend` and uses the `production` GitHub Environment plus `AWS_ROLE_TO_ASSUME`.

Production `terraform apply` is intentionally manual-only and protected by the GitHub `production` environment plus the `apply-production` confirmation string. Review the preceding `plan` output before dispatching `apply`; the expected app-host posture is data-source reference to the existing EC2 host, with no EC2/VPC/Internet Gateway/public-subnet creation. Do not use this workflow to destroy production RDS; the database has `deletion_protection` and Terraform `prevent_destroy` enabled.

The production root now expects the S3 backend created by `terraform/bootstrap/backend`: bucket `dannawagyu-shaka-prod-terraform-state`, key `prod/terraform.tfstate`, region `ap-northeast-2`, and DynamoDB lock table `shaka-prod-terraform-locks`. After bootstrap succeeds, initialize production with:

```bash
cd terraform/environments/prod
terraform init -reconfigure
```

If local production state already exists, use `terraform init -migrate-state` only after explicit Auden/operator approval and a local state backup. If no production state exists yet, initialize fresh remote state.

## Grafana credential handling

Grafana Cloud remote-write credentials are intentionally not passed through Terraform `user_data`, because rendered `user_data` can leak into Terraform state. The existing EC2 host reads Alloy credentials from `/etc/alloy/grafana-cloud.env` via systemd `EnvironmentFile`. Populate that file from the secure production deployment path or operator shell with mode `600`.

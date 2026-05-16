# GitHub Actions production environment

This repository uses a dedicated GitHub Environment named `production` for Terraform production runs. The workflow is `.github/workflows/terraform-production.yml` and is manual-only (`workflow_dispatch`).

## Required production environment variables

Set these as GitHub Environment **variables** on `production` because they are non-secret identifiers. For local testing, put equivalent Terraform values in the ignored file `terraform/environments/prod/production.local.tfvars`:

- `AWS_REGION` (default-compatible value: `ap-northeast-2`)
- `SHAKA_VPC_CIDR` (optional, defaults to `10.42.0.0/16`)
- `SHAKA_PUBLIC_SUBNET_CIDR` (optional, defaults to `10.42.0.0/24`)
- `SHAKA_AVAILABILITY_ZONES_JSON` (optional JSON array, defaults to `["ap-northeast-2a","ap-northeast-2c"]`)
- `SHAKA_PRIVATE_SUBNET_CIDRS_JSON` (optional JSON array, defaults to `["10.42.10.0/24","10.42.11.0/24"]`)
- `SHAKA_OPERATOR_SSH_CIDR` (required single operator CIDR; never `0.0.0.0/0`)
- `SHAKA_SSH_KEY_NAME`
- `SHAKA_APP_AMI_ID`
- `SHAKA_APP_INSTANCE_TYPE` (optional, defaults to `t3.micro`)
- `SHAKA_DATABASE_NAME` (optional, defaults to `shaka`)

## Required production environment secrets

Set these as GitHub Environment **secrets** on `production`:

- Preferred AWS auth: `AWS_ROLE_TO_ASSUME` for OIDC-based auth.
- Fallback AWS auth if OIDC is not configured yet: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.
- RDS bootstrap credentials: `SHAKA_DB_USERNAME`, `SHAKA_DB_PASSWORD`.
- Grafana Cloud runtime credentials for the EC2 host/pipeline path: `GRAFANA_PROMETHEUS_REMOTE_WRITE_URL`, `GRAFANA_PROMETHEUS_REMOTE_WRITE_USER`, `GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN`.

Do not commit real `*.tfvars`, Terraform plans, Terraform state, DB credentials, Grafana tokens, Discord webhooks, or AWS credentials.

## Local production value file

For local plans, copy the example file and edit only the ignored local copy:

```bash
cd /Users/dannawagyu/hermes-workspace/repos/shaka-infrastructure/terraform/environments/prod
cp production.tfvars.example production.local.tfvars
```

Then fill `production.local.tfvars`. Do not commit it. The most important values are `operator_ssh_cidr`, `ssh_key_name`, `app_ami_id`, `db_username`, and `db_password`. Keep the default VPC/subnet CIDRs unless they overlap another VPC, VPN, office network, or Tailscale-routed range.

## RDS/DataGrip access

RDS is private and accepts MySQL only from the Terraform-managed EC2 app security group. Do not open RDS to an operator IP. For DataGrip, use an SSH tunnel through the EC2 host and connect to the RDS endpoint through that tunnel.

## Apply gate

The workflow is intentionally plan-only for this PR. It runs `terraform plan` so production variables, credentials, and resource changes can be validated without creating state on an ephemeral GitHub Actions runner.

`terraform apply` is disabled until a production remote backend with encryption, locking, access controls, and an approved state migration path is configured. Before enabling apply, the existing server should be intentionally drained/stopped and the resulting plan should be reviewed for the expected EC2 + RDS creation path. Do not use this workflow to destroy production RDS; the database has `deletion_protection` and Terraform `prevent_destroy` enabled.

## Grafana credential handling

Grafana Cloud remote-write credentials are intentionally not passed through Terraform `user_data`, because rendered `user_data` can leak into Terraform state. The EC2 bootstrap config reads Alloy credentials from `/etc/alloy/grafana-cloud.env` via systemd `EnvironmentFile`. Populate that file from the secure production deployment path or operator shell with mode `600`.

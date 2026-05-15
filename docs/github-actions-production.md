# GitHub Actions production environment

This repository uses a dedicated GitHub Environment named `production` for Terraform production runs. The workflow is `.github/workflows/terraform-production.yml` and is manual-only (`workflow_dispatch`).

## Required production environment variables

Set these as GitHub Environment **variables** on `production` because they are non-secret identifiers:

- `AWS_REGION` (default-compatible value: `ap-northeast-2`)
- `SHAKA_VPC_ID`
- `SHAKA_PUBLIC_SUBNET_ID`
- `SHAKA_PRIVATE_SUBNET_IDS_JSON` (JSON array, for example `["subnet-a","subnet-b"]`)
- `SHAKA_OPERATOR_SSH_CIDR` (single operator CIDR; never `0.0.0.0/0`)
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

## Apply gate

The workflow always runs `terraform plan`. `terraform apply` runs only when:

1. `command` is `apply`, and
2. `apply_confirmation` is exactly `apply-production`, and
3. the GitHub `production` environment protection rules allow the job to start.

Before the first production apply, the existing server should be intentionally drained/stopped and the resulting plan should be reviewed for the expected EC2 + RDS creation path. Do not use this workflow to destroy production RDS; the database has `deletion_protection` and Terraform `prevent_destroy` enabled.

## Grafana credential handling

Grafana Cloud remote-write credentials are intentionally not passed through Terraform `user_data`, because rendered `user_data` can leak into Terraform state. The EC2 bootstrap config reads Alloy credentials from `/etc/alloy/grafana-cloud.env` via systemd `EnvironmentFile`. Populate that file from the secure production deployment path or operator shell with mode `600`.

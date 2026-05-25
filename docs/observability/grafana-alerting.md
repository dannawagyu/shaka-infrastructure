# Grafana Cloud alerting runbook

Closes #2

This scaffold originally covered Grafana Cloud alert rule IaC and the operator runbook. Production runtime ownership now lives in `shaka-infrastructure` as well: app deploy orchestration, server-local Alloy configuration, systemd/Nginx runtime files, and Grafana OTLP publisher credentials are managed from this repo instead of duplicating secrets in `shaka-server-spring`.

## Terraform scope

Managed by Terraform under `terraform/observability/grafana/`:

- Grafana provider configuration.
- Shaka observability folder.
- RFC-0010 Prometheus/Mimir alert rules for:
  - app scrape down;
  - host scrape down;
  - HTTP 5xx;
  - JVM heap high;
  - root disk warning and critical;
  - memory pressure;
  - CPU saturation;
  - core EC2 systemd service down (`shaka-server`, `nginx`; production MySQL runs on RDS, not systemd);
  - Alloy down.

Manual for now:

- Discord contact point creation and webhook storage. The Discord contact point is manual because Terraform state can store contact point secrets; do not commit or check in Discord webhook URLs.
- Grafana Cloud stack/API token creation.
- Datasource UID lookup after the Prometheus/Mimir datasource exists.

## Required inputs

Provide values from the operator shell or a local uncommitted secret manager wrapper:

```bash
export TF_VAR_grafana_cloud_url="https://<stack>.grafana.net"
export TF_VAR_grafana_auth="<grafana-service-account-token>"
export TF_VAR_prometheus_datasource_uid="<prometheus-datasource-uid>"
export TF_VAR_notification_contact_point_name="discord-shaka-alerts"
```

`TF_VAR_grafana_cloud_url` and `TF_VAR_grafana_auth` are marked sensitive in Terraform. Do not place them in committed `.tfvars`, logs, screenshots, or PR comments.

## Safe plan/apply workflow

```bash
cd terraform/observability/grafana
terraform init -backend=false
terraform fmt -check
terraform validate
terraform plan
```

Only run `terraform apply` after reviewing the plan for unexpected deletions or broad alert changes. This PR does not run apply and does not create real Grafana Cloud resources by itself.

## Manual Discord contact point

1. In Grafana Cloud, open **Alerting -> Contact points**.
2. Create a Discord contact point named `discord-shaka-alerts`.
3. Paste the incident-channel webhook for Discord channel `1495707393412169779` in the Grafana UI only.
4. Keep payload templates free of secrets, Authorization headers, DB credentials, JWTs, and user content.
5. Use Grafana's **test notification** button to send exactly one test notification to the incident channel.
6. Confirm the notification arrives, then keep the webhook only in Grafana Cloud configuration.

## Alloy runtime credentials and validation

Production EC2 user data installs Alloy and a local validator for `/etc/alloy/grafana-cloud.env`, but it does not render Grafana Cloud remote_write credentials into Terraform state or EC2 user data. Populate that file only through the deployment/operator secret path:

```bash
sudo install -o root -g root -m 0600 /dev/stdin /etc/alloy/grafana-cloud.env <<'EOF'
GRAFANA_PROMETHEUS_REMOTE_WRITE_URL=https://prometheus-prod-xx.grafana.net/api/prom/push
GRAFANA_PROMETHEUS_REMOTE_WRITE_USER=<grafana-prometheus-user>
GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN=<grafana-cloud-token>
EOF
sudo /usr/local/sbin/validate-alloy-grafana-cloud-env
sudo systemctl restart alloy
```

Do not place real remote_write values in Terraform variables, committed files, user_data, shell history, logs, screenshots, or PR comments. The systemd drop-in runs the validator before Alloy starts so a missing, world-readable, or placeholder credential file fails closed.

## Label and Free-tier guardrails

Rules assume the EC2 Alloy user_data config supplies low-cardinality labels such as `service_name`, `deployment_environment`, and stable Prometheus `job` names (`shaka-server`, `shaka-host`). Alert queries for scrape health explicitly use those `job` labels. If live label discovery differs, adjust Alloy labels and Terraform queries together after verifying the labels in Grafana Explore.

Do not enable broad Loki log ingestion, traces, request-body capture, user IDs as labels, request IDs as labels, JWT subjects, or URL paths with IDs as labels in this ticket. Grafana Cloud Free compatibility and privacy guardrails remain the default.

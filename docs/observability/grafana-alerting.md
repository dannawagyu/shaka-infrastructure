# Grafana Cloud alerting runbook

Closes #2

This scaffold originally covered Grafana Cloud alert rule IaC and the operator runbook. Production runtime ownership now lives in `shaka-infrastructure` as well: app deploy orchestration, server-local Alloy configuration, systemd/Nginx runtime files, and Grafana OTLP publisher credentials are managed from this repo instead of duplicating secrets in `shaka-server-spring`.

## Terraform scope

Managed by Terraform under `terraform/observability/grafana/`:

- Grafana provider configuration.
- Shaka observability folder.
- RFC-0010 Grafana Cloud Prometheus/Mimir alert rules using OTLP-exported metrics and OpenTelemetry resource labels for:
  - app OTLP metrics missing (`target_info{service_name="shaka-server"}` absent);
  - HTTP 5xx via OpenTelemetry HTTP server request duration counters;
  - JVM heap high via OpenTelemetry JVM memory metrics;
  - root disk warning and critical via OpenTelemetry host filesystem usage/limit metrics;
  - memory pressure via OpenTelemetry host memory usage metrics;
  - CPU saturation via OpenTelemetry host CPU time;
  - supplemental core systemd service down when `node_systemd_unit_state` is available;
  - Alloy OTLP pipeline missing (`system_cpu_time_seconds_total{service_name="shaka-host"}` absent).

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

Production deploy installs `/etc/alloy/config.alloy` from `deploy/grafana/alloy-otlp-config.alloy` and stores Grafana Cloud OTLP credentials in `/etc/alloy/shaka-observability.env` through the deployment/operator secret path. The active metrics path is:

```text
OpenTelemetry Java agent + Alloy hostmetrics receiver
  -> local Alloy OTLP pipeline
  -> Grafana Cloud OTLP endpoint
  -> Grafana Cloud Prometheus/Mimir datasource
```

Required runtime values are supplied from GitHub production environment secrets/vars or an equivalent operator secret path, not committed files:

```bash
GRAFANA_CLOUD_OTLP_ENDPOINT=https://<stack>.grafana.net/otlp
GRAFANA_CLOUD_OTLP_USERNAME=<grafana-otlp-user>
GRAFANA_CLOUD_OTLP_PASSWORD=<grafana-otlp-token>
OTEL_SERVICE_NAME=shaka-server
OTEL_DEPLOYMENT_ENVIRONMENT=prod
EC2_INSTANCE_ID=<resolved by deploy script from IMDSv2>
```

Do not place real OTLP credentials in Terraform variables, committed files, user_data, shell history, logs, screenshots, or PR comments. Keep the old Prometheus remote_write scrape alerts disabled/replaced once OTLP metrics are verified.

## Label and Free-tier guardrails

Rules assume the active Alloy OTLP config upserts low-cardinality OpenTelemetry resource attributes that Grafana Cloud exposes as Prometheus labels: `service_name`, `deployment_environment`, and `service_instance_id`. Alert queries intentionally avoid legacy scrape `job` labels and `/actuator/prometheus` `up` checks. If live label discovery differs, adjust Alloy resource processors and Terraform queries together after verifying labels in Grafana Explore.

Do not enable broad Loki log ingestion, traces, request-body capture, user IDs as labels, request IDs as labels, JWT subjects, or URL paths with IDs as labels in this ticket. Grafana Cloud Free compatibility and privacy guardrails remain the default.

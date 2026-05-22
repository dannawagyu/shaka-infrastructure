# Grafana dashboards

This runbook documents the Terraform-managed Shaka production dashboard.

## Scope

Dashboard-as-Code lives under `terraform/observability/grafana/` and reuses the existing `Shaka Observability` Grafana folder:

- `grafana_dashboard.shaka_prod_overview`
- `dashboards/shaka-prod-overview.json.tftpl`

The dashboard is Prometheus/Mimir-only. It does not enable Loki log ingestion, Tempo tracing, alert routing, Discord webhooks, or any production runtime change.

## Required operator inputs

Provide these from an operator shell or uncommitted secret wrapper:

```bash
export TF_VAR_grafana_cloud_url="https://<stack>.grafana.net"
export TF_VAR_grafana_auth="<grafana-service-account-token>"
export TF_VAR_prometheus_datasource_uid="<prometheus-datasource-uid>"
```

No secrets, tokens, Discord webhooks, remote_write credentials, DB credentials, or JWT material belong in dashboard JSON, Terraform files, PR comments, screenshots, or logs.

## Pre-apply Explore checks

Before applying the dashboard, confirm the deployed server is still visible in Grafana Explore with the Prometheus datasource:

```promql
up
up{job="shaka-server"}
up{job="shaka-host"}
jvm_memory_used_bytes
node_cpu_seconds_total
```

If these fail, do not apply dashboards as a substitute for ingestion debugging. Check production Alloy first: `systemctl status alloy`, Alloy logs, local `/actuator/prometheus`, and remote_write credentials.

## Dashboard panels

`Shaka Prod Overview` includes:

- app scrape status: `up{job="shaka-server"}`;
- host scrape status: `up{job="shaka-host"}`;
- service label inventory from `up`;
- core systemd service state for `shaka-server.service`, `nginx.service`, and `alloy.service`;
- HTTP request and 5xx rates;
- JVM heap and memory panels;
- host CPU, memory, and root disk panels;
- metric ingestion inventory table.

## Safe plan/apply workflow

```bash
cd terraform/observability/grafana
terraform init -backend=false
terraform fmt -check
terraform validate
terraform plan
```

Only run `terraform apply` after Auden approval and after reviewing the plan for unexpected dashboard/folder/alert changes. Applying this dashboard changes Grafana Cloud UI resources only; it does not deploy the server or modify AWS resources.

## Post-apply verification

After apply:

1. Open Grafana folder `Shaka Observability`.
2. Open dashboard `Shaka Prod Overview`.
3. Confirm app and host scrape stat panels show `1`.
4. Confirm JVM and host graphs show recent data over the last 15 minutes.
5. Confirm no panel query uses local-only addresses, secrets, user IDs, or high-cardinality Loki/Tempo labels.

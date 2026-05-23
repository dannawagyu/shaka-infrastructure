# Grafana dashboards

This runbook documents the Terraform-managed Shaka production dashboard.

## Scope

Dashboard-as-Code lives under `terraform/observability/grafana/` and reuses the existing `Shaka Observability` Grafana folder:

- `grafana_dashboard.shaka_prod_overview`
- `dashboards/shaka-prod-overview.json.tftpl`

The dashboard is Prometheus/Mimir-only. It does not enable Loki log ingestion, Tempo tracing, alert routing, Discord webhooks, or any production runtime change. Panels are managed as code with Grafana UI editing disabled (`editable = false` in the rendered dashboard JSON) so Terraform remains the source of truth.

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

- app scrape status: `up{job="shaka-server",deployment_environment="prod"}`;
- host scrape status: `up{job="shaka-host",deployment_environment="prod"}`;
- service label inventory from `up`, filtered by `deployment_environment`;
- core systemd service state for `shaka-server.service`, `nginx.service`, and `alloy.service`;
- HTTP request and 5xx rates; the 5xx panel renders 0 when there are no error series;
- `HTTP 401 rate by URI` for route-level only 401 spike triage, with no user IDs, IP addresses, or request IDs;
- JVM heap and memory panels;
- host CPU, memory, and root disk panels, with memory pressure centered on available memory below 10%;
- metric ingestion inventory table.

## Safe plan/apply workflow

```bash
cd terraform/observability/grafana
terraform init
terraform fmt -check
terraform validate
terraform plan
```

Only run `terraform apply` after maintainer approval and after reviewing the plan for unexpected dashboard/folder/alert changes. Applying this dashboard changes Grafana Cloud UI resources only; it does not deploy the server or modify AWS resources.

## Post-apply verification

After apply:

1. Open Grafana folder `Shaka Observability`.
2. Open dashboard `Shaka Prod Overview`.
3. Confirm app and host scrape stat panels show `1`.
4. Confirm JVM and host graphs show recent data over the last 15 minutes.
5. Confirm no panel query uses local-only addresses, secrets, user IDs, or high-cardinality Loki/Tempo labels.

## Follow-up diagnostics notes

- The HTTP 5xx panel must render `0` rather than `No data` when no 5xx time series exists, so operators can distinguish zero errors from broken ingestion.
- `HTTP 401 rate by URI` is route-level only: it groups by Micrometer `method`, `uri`, and `status`. Do not add user IDs, IP addresses, request IDs, raw paths, `instance`, or `service_instance_id` to this panel. Keep `UNKNOWN` route values visible so unmapped auth probes are not hidden; if raw paths ever appear in the `uri` label, fix application instrumentation before sharing screenshots or widening dashboard access.
- Host memory pressure is treated as available memory below 10% / usage above 90%. The dashboard turns red below 10% available and green at or above 20% available.

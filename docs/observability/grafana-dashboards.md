# Grafana dashboards

This runbook documents the Terraform-managed Shaka production dashboards.

## Scope

Dashboard-as-Code lives under `terraform/observability/grafana/` and reuses the existing `Shaka Observability` Grafana folder:

- `grafana_dashboard.shaka_prod_overview`
- `dashboards/shaka-prod-overview.json.tftpl`
- `grafana_dashboard.shaka_amazon_rds`
- `dashboards/amazon-rds.json.tftpl`

`Shaka Prod Overview` references existing Grafana Cloud Prometheus/Mimir, Loki, and Tempo datasources by UID. `Shaka Amazon RDS` imports Grafana.com dashboard [11264 Amazon RDS](https://grafana.com/grafana/dashboards/11264-amazon-rds/), references an existing Grafana CloudWatch datasource by UID, and defaults its AWS Region variable from production `AWS_REGION` so panels do not silently query the datasource's default region. These dashboards do not by themselves enable Loki log ingestion, Tempo tracing, alert routing, Discord webhooks, AWS IAM access, CloudWatch datasource credentials, or any production runtime change. Panels are managed as code with Grafana UI editing disabled (`editable = false` in the rendered dashboard JSON) so Terraform remains the source of truth.

## Required operator inputs

Provide these from an operator shell or uncommitted secret wrapper:

```bash
export TF_VAR_grafana_cloud_url="https://<stack>.grafana.net"
export TF_VAR_grafana_auth="<grafana-service-account-token>"
export TF_VAR_prometheus_datasource_uid="<prometheus-datasource-uid>"
export TF_VAR_cloudwatch_datasource_uid="<cloudwatch-datasource-uid>"
export TF_VAR_loki_datasource_uid="<loki-datasource-uid>"
export TF_VAR_tempo_datasource_uid="<tempo-datasource-uid>"
```

No secrets, tokens, Discord webhooks, remote_write credentials, DB credentials, AWS access keys, or JWT material belong in dashboard JSON, Terraform files, PR comments, screenshots, or logs. The CloudWatch datasource should already exist in Grafana Cloud or be created through a separately reviewed operator path with least-privilege AWS CloudWatch permissions for RDS metrics.

## Pre-apply Explore checks

Before applying the dashboard, confirm the deployed server is still visible in Grafana Explore with the Prometheus datasource:

```promql
target_info{service_name="shaka-server"}
system_cpu_time_seconds_total or node_cpu_seconds_total
system_memory_usage_bytes or node_memory_MemAvailable_bytes
system_filesystem_usage_bytes or node_filesystem_avail_bytes
jvm_memory_used_bytes{service_name="shaka-server"}
http_server_request_duration_seconds_count{service_name="shaka-server"}
```

If these fail, do not apply dashboards as a substitute for ingestion debugging. Check production Alloy first: `systemctl status alloy`, Alloy logs, local `/actuator/prometheus`, and remote_write credentials.

For `Shaka Amazon RDS`, also confirm before any plan/apply that `GRAFANA_CLOUDWATCH_DATASOURCE_UID` points to a Grafana CloudWatch datasource scoped to the intended Shaka production RDS metrics only, and that the `Shaka Observability` folder is restricted to operators allowed to view production RDS infrastructure names and metrics. If the datasource can read unrelated AWS accounts, environments, or services, tighten the datasource/IAM scope before applying the dashboard.

## Dashboard panels

`Shaka Prod Overview` includes:

- app OTLP heartbeat status: any recent `target_info`, `jvm_memory_used_bytes`, or `http_server_request_duration_seconds_count` series for `service_name="shaka-server",deployment_environment="prod"`, rendered as `UP`/`DOWN` instead of raw `1`/`0`;
- host OTLP heartbeat status: any recent `system_cpu_time_seconds_total`, `node_cpu_seconds_total`, or `up` series for `service_name="shaka-host",deployment_environment="prod"`, rendered as `UP`/`DOWN` instead of raw `1`/`0`;
- service label inventory from OTLP app and host heartbeat metrics, filtered by `deployment_environment`, rendered as `PRESENT`/`MISSING`;
- core systemd service state for `shaka-server.service`, `nginx.service`, and `alloy.service`, rendered as `ACTIVE`/`DOWN`;
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
3. Confirm app and host scrape stat panels show `UP`, service inventory shows `PRESENT`, and core systemd services show `ACTIVE`.
4. Confirm JVM and host graphs show recent data over the last 15 minutes.
5. Confirm Loki log panels show either recent entries or `0 / NO LOGS`, and Tempo panels show recent traces after a traced request.
6. Open `Shaka Amazon RDS`, select the intended CloudWatch datasource/region/period, and confirm the RDS CPU, connections, freeable memory, storage, latency, and I/O panels show recent CloudWatch data.
7. Confirm no panel query uses local-only addresses, secrets, user IDs, or high-cardinality Loki/Tempo labels.

## Follow-up diagnostics notes

- The HTTP 5xx panel must render `0` rather than `No data` when no 5xx time series exists, so operators can distinguish zero errors from broken ingestion.
- `HTTP 401 rate by URI` is route-level only: it groups by Micrometer `method`, `uri`, and `status`. Do not add user IDs, IP addresses, request IDs, raw paths, `instance`, or `service_instance_id` to this panel. Keep `UNKNOWN` route values visible so unmapped auth probes are not hidden; if raw paths ever appear in the `uri` label, fix application instrumentation before sharing screenshots or widening dashboard access.
- `Loki log entries, last 5m` counts app logs only by `service_name` and `deployment_environment`.
- `Recent application logs` shows a narrow Loki stream query filtered only by `service_name` and `deployment_environment`.
- `Recent Tempo traces` uses TraceQL filtered only by stable `resource.service.name` and `resource.deployment.environment` attributes.
- Do not add user IDs, IP addresses, request IDs, `instance`, `service_instance_id`, raw URL paths, request bodies, Authorization/JWT material, or user-generated content as Loki labels, Tempo resource attributes, legend labels, or dashboard variables.
- Host memory pressure is treated as available memory below 10% / usage above 90%. The dashboard turns red below 10% available and green at or above 20% available.

`Shaka Amazon RDS` is based on Grafana.com dashboard 11264 and includes CloudWatch `AWS/RDS` panels for instance-level RDS metrics such as CPU utilization, database connections, and freeable memory. The upstream dashboard's `DBClusterIdentifier` panels are intentionally removed for the current Shaka topology because production uses a standard RDS instance rather than an Aurora/RDS cluster; use `DBInstanceIdentifier` panels as the source of truth. Use the dashboard `CloudWatch data source`, `AWS Region`, and `Period [sec]` variables to select the intended Grafana CloudWatch datasource, AWS region, and query period. If panels show no data, first verify the CloudWatch datasource credentials and region/RDS dimension support in Grafana Explore; do not treat an empty dashboard as proof that RDS metrics are unavailable.

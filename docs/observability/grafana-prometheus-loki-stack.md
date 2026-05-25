# Grafana Prometheus and Loki stack specification

Closes #3

This document specifies the Shaka Grafana Cloud observability stack split for Prometheus / Metrics and Loki / Logs. It extends the alerting scaffold from issue #2 and records the updated ownership model: production app deploy, server-local Alloy, and runtime Grafana credentials are infra-owned in `shaka-infrastructure`, while `shaka-server-spring` owns application code and the build artifact contract.

## Terraform owns

Terraform owns non-secret Grafana Cloud organization of the Shaka observability stack:

- Grafana provider and folder scaffolding.
- Prometheus / Metrics alert rule definitions for RFC-0010.
- Sensitive variable declarations for Prometheus remote_write and Loki endpoints/users/tokens.
- Low-cardinality shared labels for metrics/logs alignment:
  - `service.name=shaka-server` maps to `service_name=shaka-server` in Prometheus-safe labels.
  - `deployment.environment=prod` maps to `deployment_environment=prod`.
  - Host metrics continue to use `service.name=shaka-host` on the collector side.

Terraform does not currently manage live Grafana Cloud stack creation, real datasource credentials, or the Discord contact point secret.

## Manual / operator-owned

Manual items remain manual because they either contain secrets or require live Grafana Cloud UI/API discovery:

- Grafana Cloud access policy token creation.
- Prometheus datasource UID lookup.
- Discord contact point creation and test notification. The Discord contact point remains manual to avoid storing webhook secrets in Terraform state.
- Any real remote_write/Loki credentials. Prometheus remote_write credentials for EC2 Alloy must be populated at runtime in `/etc/alloy/grafana-cloud.env` by the deployment/operator secret path with `root:root` ownership and mode `0600`; never render them through Terraform state or user_data.

## Prometheus / Metrics

Metrics are enabled first. Alloy scrapes Spring Boot `/actuator/prometheus` and host metrics, then sends them to Grafana Cloud Prometheus/Mimir remote_write. Alert rules cover app scrape down, host scrape down, HTTP 5xx, JVM heap high, root disk warning/critical, memory pressure, CPU saturation, core EC2 systemd service down (`shaka-server`, `nginx`; database is RDS), and Alloy down.

Live labels must be checked in Grafana Explore before tightening alert queries. Keep labels low-cardinality and stable. EC2 Alloy user_data explicitly normalizes Prometheus `job` labels to `shaka-server` and `shaka-host` to match the Grafana alert rules.

## Loki / Logs

Loki is specified but staged off by default with `enable_loki_ingestion = false`.

If a later approved apply enables Loki, the initial ingestion scope should be minimal:

- Spring Boot application logs only, or app plus Nginx error logs after review.
- no request bodies.
- no Authorization/JWT headers.
- no DB credentials, environment variables, or user content payloads.
- short retention aligned with Grafana Cloud Free constraints.

Allowed labels must stay low-cardinality:

- `service.name=shaka-server`.
- `deployment.environment=prod`.
- `source=app` or `source=nginx-error`.
- avoid userId, requestId, URL paths with IDs, JWT subject, arbitrary exception text, or user-generated content as labels.

Terraform alone cannot ingest logs from EC2. Runtime Alloy pipeline changes are implemented through the infra-owned production deploy path, not a `shaka-server-spring` secret path. Any Loki-specific file tailing pipeline still needs privacy/cardinality review before enabling `enable_loki_ingestion`; the OTLP-first path uses the OpenTelemetry Java agent and local Alloy OTLP receiver managed from this repo.

## Safe commands

```bash
cd terraform/observability/grafana
terraform init -backend=false
terraform fmt -check
terraform validate
terraform plan
```

Do not run `terraform apply` until the plan is reviewed and all secrets are supplied from the operator environment.

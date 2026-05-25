# Loki and Tempo diagnostics staging

Closes #24
Closes #25

This runbook documents the older Loki/Tempo staging guardrails and the privacy/cost gates that still apply to signal-specific file tailing or trace-only experiments. The active production direction is now infra-owned OTLP-first deployment: OpenTelemetry Java agent metrics/logs/traces -> local Alloy OTLP receiver -> Grafana Cloud OTLP endpoint.

## RFC status and gate

- RFC-0017 remains draft for Loki log ingestion. This PR only documents the staged design and keeps `enable_loki_ingestion = false`.
- RFC-0018 remains draft for Tempo trace ingestion. This PR only documents the spike plan and keeps `enable_tempo_tracing = false`.
- Do not change either RFC to approved, run production `terraform apply`, enable Alloy log shipping, or enable Java agent/OTLP trace export from this ticket alone.

## Loki staging decision

The first Loki source should be application JSON file logs, not broad systemd journal ingestion.

Reasoning:

- Application JSON file logs are the narrowest useful source for Shaka API diagnostics.
- They can be parsed with predictable fields and drop/redaction stages before `loki.write`.
- Journal ingestion is valuable for service lifecycle events, but it is broader and may include package/system messages that are harder to privacy-review as a first rollout.
- Nginx error logs can be considered later, after the application-only pipeline proves safe and low volume.

### Disabled-by-default Terraform placeholders

`terraform/observability/grafana/stack-variables.tf` declares Loki endpoint/user/token placeholders and keeps `enable_loki_ingestion = false`. The variables are sensitive placeholders only; Terraform must not render real Grafana Cloud Logs credentials into state or EC2 user data.

### Allowed Loki payload and labels

Allowed labels are deliberately low-cardinality:

- `service_name`
- `deployment_environment`
- `service_instance_id`
- `log_source`

The initial `log_source` value should be `app`. Do not use user IDs, request IDs, note IDs, raw paths with IDs, JWT subject, exception text, or arbitrary message text as labels.

No request bodies, Authorization/JWT/refresh/Apple tokens, database credentials, Grafana tokens, Discord webhooks, or user-generated note/comment content may be shipped. If an approved field can contain user input, drop it by default until a dedicated privacy review approves redaction or hashing.

### Loki rollback

Disable the Loki pipeline without changing Prometheus remote_write:

1. Set the Alloy Loki enable flag to false or remove the Loki pipeline block.
2. Restart Alloy.
3. Confirm metrics still ingest with `up{job="shaka-server"}`, `up{job="shaka-host"}`, and JVM metrics in Grafana Explore.
4. Rotate the Grafana Cloud Logs token if any unsafe payload or credential exposure is suspected.

## Tempo evaluation plan

Tempo remains a planning/spike item. The two viable options are:

1. OpenTelemetry Java agent + Alloy OTLP + Tempo.
2. Sentry-only tracing with adjusted sampling and documented limitations.

Recommendation: run a controlled spike before choosing a production tracing backend. Shaka is currently a single Spring Boot service on a small production host, so the first tracing decision should be evidence-driven rather than enabled as part of the current infrastructure path.

### Disabled-by-default Terraform placeholders

`terraform/observability/grafana/stack-variables.tf` declares Tempo endpoint/user/token placeholders, keeps `enable_tempo_tracing = false`, and records a conservative `tempo_sampling_rate` default of 1%. The validation cap is 5% for the staged design so an accidental high-volume trace rollout is rejected before review. These Tempo variables must remain unreferenced by Terraform resources, EC2 user data, or rendered templates until a separately approved enablement PR, because sensitive Terraform values can still enter state once they are consumed.

### Spike measurement checklist

Measure before and after enabling the Java agent and OTLP path in a local/staging or explicitly approved low-traffic production window:

- CPU usage.
- memory usage.
- JVM heap usage.
- startup time.
- request latency.
- Alloy process CPU/memory impact.
- Grafana Cloud trace volume and cardinality.

Sampling should start at 1% and stay within 1% to 5% until the production host has enough headroom data. Any operator override must be explicit and documented.

### Sensitive trace data rules

Spans must exclude request and response bodies, Authorization/JWT/refresh/Apple tokens, database credentials, Grafana tokens, Discord webhooks, and user-generated note/comment content. Stable resource attributes may include `service.name=shaka-server`, `deployment.environment=prod`, and `service.instance.id=<EC2_INSTANCE_ID>`; request-specific values should not become labels/resource attributes.

### Tempo rollback

Disable the Java agent and OTLP export without affecting metrics:

1. Remove or disable the Java agent/OTLP environment flags from the Shaka service.
2. Disable the Alloy OTLP receiver/export pipeline if it was added.
3. Restart Shaka and Alloy if needed.
4. Confirm `/actuator/health` and `/actuator/prometheus` return healthy responses.
5. Confirm Grafana Prometheus metrics remain present.
6. Rotate the Tempo/OTLP token if any unsafe data or credential exposure is suspected.

## Follow-up work before enablement

- Keep server-side Alloy runtime configuration in `shaka-infrastructure`, not `shaka-server-spring`.
- Keep static validation for any legacy Loki/Tempo Terraform placeholders that remain disabled by default.
- Run security/privacy review before enabling any additional file-tail Loki pipeline or increasing trace/log volume.
- Capture Grafana Explore evidence after a safe synthetic event/trace test.

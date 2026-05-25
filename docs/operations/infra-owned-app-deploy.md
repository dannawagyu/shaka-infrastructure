# Infra-owned Shaka production app deploy

`shaka-infrastructure` owns the production runtime deployment path. The server
repo remains responsible for source code, tests, and release versioning; this
repo owns the EC2 runtime mutation: jar rotation, Nginx/systemd config, Alloy,
OpenTelemetry Java agent, and Grafana Cloud OTLP credentials.

## Required GitHub production environment values

Secrets in `shaka-infrastructure` → `production`:

```text
SHAKA_PROD_HOST
SHAKA_PROD_SSH_KEY
SHAKA_PROD_SSH_KNOWN_HOSTS
SHAKA_PROD_URL
GRAFANA_CLOUD_OTLP_ENDPOINT
GRAFANA_CLOUD_OTLP_USERNAME
GRAFANA_CLOUD_OTLP_PASSWORD
```

Optional secrets:

```text
SHAKA_PROD_SSH_USER     # defaults to ubuntu when unset
SHAKA_SERVER_REPO_TOKEN # only if shaka-server-spring checkout needs a PAT
```

Vars:

```text
OTEL_SERVICE_NAME=shaka-server
OTEL_DEPLOYMENT_ENVIRONMENT=prod
```

Do not duplicate `GRAFANA_CLOUD_OTLP_*` in `shaka-server-spring`. Runtime
observability credentials are managed from this repo's single production
environment.

## Deploy command

Run `.github/workflows/app-production-deploy.yml` from `main` only:

```text
server_ref=server-v* / release/server-v* tag or a full 40-character commit SHA
release_version=<optional exact Gradle version>
deploy_confirmation=deploy-shaka-production
otel_java_agent_version=2.15.0
otel_java_agent_sha256=<expected 64-character sha256>
```

The first workflow job builds and tests the server repo without production secrets, rejects SNAPSHOT versions, and uploads a short-lived artifact. The production-environment job downloads that artifact and runs `scripts/deploy-shaka-production.sh`.

## Observability direction

Primary path:

```text
OpenTelemetry Java agent metrics/logs/traces
  -> local Alloy OTLP receiver on 127.0.0.1:4317/4318
  -> Grafana Cloud OTLP endpoint
```

The old signal-specific credentials are not part of this path:

```text
GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN
GRAFANA_CLOUD_LOKI_API_KEY
TEMPO_OTLP_PASSWORD
```

Keep any already-working Prometheus remote_write path as rollback/fallback until
OTLP metrics are verified in Grafana, then remove it in a separate cleanup.

`SHAKA_PROD_SSH_KNOWN_HOSTS` should contain the pinned SSH host key line for the production host; do not rely on first-connect `accept-new` in production deploys.

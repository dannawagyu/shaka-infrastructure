#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/deploy-shaka-production.sh

Infra-owned production deploy for Shaka server artifacts. Build the server jar in
CI first, then run this script with SHAKA_SERVER_DIR pointing at that checkout.

Required environment variables:
  SHAKA_SERVER_DIR
  SHAKA_PROD_HOST
  SHAKA_PROD_SSH_KEY or SHAKA_PROD_SSH_KEY_PATH
  SHAKA_PROD_SSH_KNOWN_HOSTS
  SHAKA_PROD_URL
  RELEASE_VERSION
  OTEL_JAVA_AGENT_SHA256
  GRAFANA_CLOUD_OTLP_ENDPOINT
  GRAFANA_CLOUD_OTLP_USERNAME
  GRAFANA_CLOUD_OTLP_PASSWORD

Optional environment variables:
  SHAKA_INFRA_DIR                 defaults to repository root
  SHAKA_PROD_SSH_USER             defaults to ubuntu
  OTEL_SERVICE_NAME               defaults to shaka-server
  OTEL_DEPLOYMENT_ENVIRONMENT     defaults to prod
  OTEL_JAVA_AGENT_VERSION         defaults to 2.15.0
USAGE
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

INFRA_DIR="${SHAKA_INFRA_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
SERVER_DIR="${SHAKA_SERVER_DIR:?SHAKA_SERVER_DIR is required}"
: "${SHAKA_PROD_HOST:?SHAKA_PROD_HOST is required}"
: "${SHAKA_PROD_URL:?SHAKA_PROD_URL is required}"
: "${RELEASE_VERSION:?RELEASE_VERSION is required}"
: "${OTEL_JAVA_AGENT_SHA256:?OTEL_JAVA_AGENT_SHA256 is required}"
: "${GRAFANA_CLOUD_OTLP_ENDPOINT:?GRAFANA_CLOUD_OTLP_ENDPOINT is required}"
: "${GRAFANA_CLOUD_OTLP_USERNAME:?GRAFANA_CLOUD_OTLP_USERNAME is required}"
: "${GRAFANA_CLOUD_OTLP_PASSWORD:?GRAFANA_CLOUD_OTLP_PASSWORD is required}"

SHAKA_PROD_SSH_USER="${SHAKA_PROD_SSH_USER:-ubuntu}"
OTEL_SERVICE_NAME="${OTEL_SERVICE_NAME:-shaka-server}"
OTEL_DEPLOYMENT_ENVIRONMENT="${OTEL_DEPLOYMENT_ENVIRONMENT:-prod}"
OTEL_JAVA_AGENT_VERSION="${OTEL_JAVA_AGENT_VERSION:-2.15.0}"
REMOTE_DIR="/opt/shaka"
RELEASES_DIR="${REMOTE_DIR}/releases"
CURRENT_LINK="${REMOTE_DIR}/current.jar"
JAR_FILE="shaka-${RELEASE_VERSION}.jar"
LOCAL_JAR="${SERVER_DIR}/build/libs/${JAR_FILE}"
NGINX_CONF="${INFRA_DIR}/deploy/nginx/shaka-server.conf"
SYSTEMD_CONF="${INFRA_DIR}/deploy/systemd/shaka-server.service"
ENV_EXAMPLE="${INFRA_DIR}/deploy/env/shaka-env.example"
ALLOY_CONFIG="${INFRA_DIR}/deploy/grafana/alloy-otlp-config.alloy"
OTEL_AGENT_URL="https://repo1.maven.org/maven2/io/opentelemetry/javaagent/opentelemetry-javaagent/${OTEL_JAVA_AGENT_VERSION}/opentelemetry-javaagent-${OTEL_JAVA_AGENT_VERSION}.jar"

for path in "$LOCAL_JAR" "$NGINX_CONF" "$SYSTEMD_CONF" "$ENV_EXAMPLE" "$ALLOY_CONFIG"; do
  if [[ ! -f "$path" ]]; then
    echo "ERROR: required file not found: $path" >&2
    exit 1
  fi
done

case "$GRAFANA_CLOUD_OTLP_ENDPOINT" in
  https://*.grafana.net*|https://*.grafana.com*) ;;
  *) echo "ERROR: GRAFANA_CLOUD_OTLP_ENDPOINT must be a Grafana Cloud HTTPS endpoint" >&2; exit 1 ;;
esac
if [[ ! "$OTEL_JAVA_AGENT_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "ERROR: OTEL_JAVA_AGENT_SHA256 must be a 64-character SHA-256 hex digest" >&2
  exit 1
fi

quote_env_value() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

write_env_line() {
  local file="$1"
  local name="$2"
  printf '%s=' "$name" >> "$file"
  quote_env_value "${!name}" >> "$file"
  printf '\n' >> "$file"
}

KEY_FILE="${SHAKA_PROD_SSH_KEY_PATH:-}"
TEMP_KEY=""
KNOWN_HOSTS_FILE=""
OBS_ENV_FILE=""
REMOTE_STAGING_DIR=""
if [[ -z "$KEY_FILE" ]]; then
  : "${SHAKA_PROD_SSH_KEY:?SHAKA_PROD_SSH_KEY or SHAKA_PROD_SSH_KEY_PATH is required}"
  TEMP_KEY="$(mktemp)"
  chmod 600 "$TEMP_KEY"
  printf '%s\n' "$SHAKA_PROD_SSH_KEY" > "$TEMP_KEY"
  KEY_FILE="$TEMP_KEY"
fi

cleanup() {
  if [[ -n "$TEMP_KEY" && -f "$TEMP_KEY" ]]; then rm -f "$TEMP_KEY"; fi
  if [[ -n "$KNOWN_HOSTS_FILE" && -f "$KNOWN_HOSTS_FILE" ]]; then rm -f "$KNOWN_HOSTS_FILE"; fi
  if [[ -n "$OBS_ENV_FILE" && -f "$OBS_ENV_FILE" ]]; then rm -f "$OBS_ENV_FILE"; fi
  if [[ -n "${REMOTE_STAGING_DIR:-}" && -n "${SSH[*]:-}" ]]; then
    "${SSH[@]}" "case '$REMOTE_STAGING_DIR' in /tmp/shaka-infra-deploy.*) rm -rf '$REMOTE_STAGING_DIR' ;; esac" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

: "${SHAKA_PROD_SSH_KNOWN_HOSTS:?SHAKA_PROD_SSH_KNOWN_HOSTS is required}"
KNOWN_HOSTS_FILE="$(mktemp)"
chmod 600 "$KNOWN_HOSTS_FILE"
printf '%s
' "$SHAKA_PROD_SSH_KNOWN_HOSTS" > "$KNOWN_HOSTS_FILE"

SSH=(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" "${SHAKA_PROD_SSH_USER}@${SHAKA_PROD_HOST}")
SCP=(scp -i "$KEY_FILE" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS_FILE")
PREVIOUS_TARGET_REMOTE="$("${SSH[@]}" 'readlink /opt/shaka/current.jar 2>/dev/null || true')"

rollback_remote() {
  if [[ -n "$REMOTE_STAGING_DIR" ]]; then
    "${SSH[@]}" bash -s -- "$REMOTE_STAGING_DIR" <<'ROLLBACK_REMOTE'
set -euo pipefail
REMOTE_STAGING_DIR="$1"
BACKUP_DIR="${REMOTE_STAGING_DIR}/rollback"
restore_if_present() {
  local src="$1"
  local dest="$2"
  local mode="$3"
  if [[ -f "$src" ]]; then
    sudo install -o root -g root -m "$mode" "$src" "$dest"
  fi
}
if [[ -d "$BACKUP_DIR" ]]; then
  if [[ -f "$BACKUP_DIR/current-target" ]]; then
    previous_target="$(cat "$BACKUP_DIR/current-target")"
    sudo ln -sfn "$previous_target" /opt/shaka/current.jar
    sudo chown -h ubuntu:ubuntu /opt/shaka/current.jar
  fi
  restore_if_present "$BACKUP_DIR/shaka-server.conf" /etc/nginx/conf.d/shaka-server.conf 0644
  restore_if_present "$BACKUP_DIR/shaka-server.service" /etc/systemd/system/shaka-server.service 0644
  restore_if_present "$BACKUP_DIR/config.alloy" /etc/alloy/config.alloy 0644
  restore_if_present "$BACKUP_DIR/shaka-observability.conf" /etc/systemd/system/alloy.service.d/shaka-observability.conf 0644
  restore_if_present "$BACKUP_DIR/env" /etc/shaka/env 0640
  sudo chown root:ubuntu /etc/shaka/env 2>/dev/null || true
  sudo systemctl daemon-reload
  sudo nginx -t && sudo systemctl reload nginx || true
  sudo systemctl restart alloy || true
  sudo systemctl restart shaka-server || true
fi
ROLLBACK_REMOTE
  elif [[ -n "$PREVIOUS_TARGET_REMOTE" ]]; then
    "${SSH[@]}" bash -s -- "$PREVIOUS_TARGET_REMOTE" <<'ROLLBACK_REMOTE_FALLBACK'
set -euo pipefail
previous_target="$1"
sudo ln -sfn "$previous_target" /opt/shaka/current.jar
sudo chown -h ubuntu:ubuntu /opt/shaka/current.jar
sudo systemctl restart shaka-server || true
ROLLBACK_REMOTE_FALLBACK
  fi
}

OBS_ENV_FILE="$(mktemp)"
chmod 600 "$OBS_ENV_FILE"
write_env_line "$OBS_ENV_FILE" GRAFANA_CLOUD_OTLP_ENDPOINT
write_env_line "$OBS_ENV_FILE" GRAFANA_CLOUD_OTLP_USERNAME
write_env_line "$OBS_ENV_FILE" GRAFANA_CLOUD_OTLP_PASSWORD
write_env_line "$OBS_ENV_FILE" OTEL_SERVICE_NAME
write_env_line "$OBS_ENV_FILE" OTEL_DEPLOYMENT_ENVIRONMENT
# EC2_INSTANCE_ID is resolved on the host via IMDSv2 and appended before install.

echo "Preflighting production host and OpenTelemetry Java agent before app mutation..."
"${SSH[@]}" bash -s -- "$OTEL_AGENT_URL" "$OTEL_JAVA_AGENT_SHA256" <<'REMOTE_PREFLIGHT'
set -euo pipefail
OTEL_AGENT_URL="$1"
OTEL_JAVA_AGENT_SHA256="$2"
if [[ ! -f /etc/shaka/env ]]; then
  echo "ERROR: /etc/shaka/env is missing; populate app runtime secrets before deploy" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required on the production host" >&2
  exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
  echo "ERROR: sha256sum is required on the production host" >&2
  exit 1
fi
stage="$(mktemp -d /tmp/shaka-otel-agent.XXXXXX)"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT
curl -fsSL "$OTEL_AGENT_URL.sha256" -o "$stage/opentelemetry-javaagent.jar.sha256"
curl -fsSL "$OTEL_AGENT_URL" -o "$stage/opentelemetry-javaagent.jar"
expected="$(tr -d '[:space:]' < "$stage/opentelemetry-javaagent.jar.sha256")"
printf '%s  %s\n' "$expected" "$stage/opentelemetry-javaagent.jar" | sha256sum -c - >/dev/null
sudo install -d -o root -g root -m 0755 /opt/shaka
sudo install -o root -g root -m 0644 "$stage/opentelemetry-javaagent.jar" /opt/shaka/opentelemetry-javaagent.jar
REMOTE_PREFLIGHT

REMOTE_STAGING_DIR="$("${SSH[@]}" 'tmpdir="$(mktemp -d /tmp/shaka-infra-deploy.XXXXXX)" && chmod 0700 "$tmpdir" && printf "%s" "$tmpdir"')"
"${SCP[@]}" "$LOCAL_JAR" "$NGINX_CONF" "$SYSTEMD_CONF" "$ENV_EXAMPLE" "$ALLOY_CONFIG" "$OBS_ENV_FILE" "${SHAKA_PROD_SSH_USER}@${SHAKA_PROD_HOST}:${REMOTE_STAGING_DIR}/"

"${SSH[@]}" bash -s -- "$JAR_FILE" "$REMOTE_STAGING_DIR" "$(basename "$OBS_ENV_FILE")" <<'REMOTE_DEPLOY'
set -euo pipefail
JAR_FILE="$1"
REMOTE_STAGING_DIR="$2"
OBS_ENV_BASE="$3"
REMOTE_DIR="/opt/shaka"
RELEASES_DIR="${REMOTE_DIR}/releases"
CURRENT_LINK="${REMOTE_DIR}/current.jar"
PREVIOUS_TARGET=""
if [[ -L "$CURRENT_LINK" ]]; then
  PREVIOUS_TARGET="$(readlink "$CURRENT_LINK")"
fi
case "$REMOTE_STAGING_DIR" in
  /tmp/shaka-infra-deploy.*) ;;
  *) echo "ERROR: invalid staging directory" >&2; exit 1 ;;
esac
BACKUP_DIR="${REMOTE_STAGING_DIR}/rollback"
mkdir -p "$BACKUP_DIR"
if [[ -L "$CURRENT_LINK" ]]; then
  readlink "$CURRENT_LINK" > "$BACKUP_DIR/current-target"
fi
for src_dest in   /etc/nginx/conf.d/shaka-server.conf:shaka-server.conf   /etc/systemd/system/shaka-server.service:shaka-server.service   /etc/alloy/config.alloy:config.alloy   /etc/systemd/system/alloy.service.d/shaka-observability.conf:shaka-observability.conf   /etc/shaka/env:env; do
  src="${src_dest%%:*}"
  dest="${src_dest##*:}"
  if [[ -f "$src" ]]; then
    cp "$src" "$BACKUP_DIR/$dest"
  fi
done

rollback_from_backup() {
  restore_if_present() {
    local src="$1"
    local dest="$2"
    local mode="$3"
    if [[ -f "$src" ]]; then
      sudo install -o root -g root -m "$mode" "$src" "$dest"
    fi
  }
  if [[ -f "$BACKUP_DIR/current-target" ]]; then
    previous_target="$(cat "$BACKUP_DIR/current-target")"
    sudo ln -sfn "$previous_target" "$CURRENT_LINK"
    sudo chown -h ubuntu:ubuntu "$CURRENT_LINK"
  fi
  restore_if_present "$BACKUP_DIR/shaka-server.conf" /etc/nginx/conf.d/shaka-server.conf 0644
  restore_if_present "$BACKUP_DIR/shaka-server.service" /etc/systemd/system/shaka-server.service 0644
  restore_if_present "$BACKUP_DIR/config.alloy" /etc/alloy/config.alloy 0644
  restore_if_present "$BACKUP_DIR/shaka-observability.conf" /etc/systemd/system/alloy.service.d/shaka-observability.conf 0644
  restore_if_present "$BACKUP_DIR/env" /etc/shaka/env 0640
  sudo chown root:ubuntu /etc/shaka/env 2>/dev/null || true
  sudo systemctl daemon-reload
  sudo nginx -t && sudo systemctl reload nginx || true
  sudo systemctl restart alloy || true
  sudo systemctl restart shaka-server || true
}

if [[ ! -f /opt/shaka/opentelemetry-javaagent.jar ]]; then
  echo "ERROR: /opt/shaka/opentelemetry-javaagent.jar is missing after preflight" >&2
  exit 1
fi

imds_token=""
instance_id="unknown"
if imds_token="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)"; then
  instance_id="$(curl -fsS -H "X-aws-ec2-metadata-token: $imds_token" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || printf unknown)"
fi
obs_env_file="${REMOTE_STAGING_DIR}/${OBS_ENV_BASE}"
if [[ ! -f "$obs_env_file" ]]; then
  echo "ERROR: staged observability env file missing" >&2
  exit 1
fi
printf 'EC2_INSTANCE_ID="%s"\n' "$instance_id" | sudo tee -a "$obs_env_file" >/dev/null
sudo python3 - "$obs_env_file" <<'PY'
import os
import stat
import sys
from pathlib import Path

path = Path(sys.argv[1])
required = {
    "GRAFANA_CLOUD_OTLP_ENDPOINT",
    "GRAFANA_CLOUD_OTLP_USERNAME",
    "GRAFANA_CLOUD_OTLP_PASSWORD",
    "OTEL_SERVICE_NAME",
    "OTEL_DEPLOYMENT_ENVIRONMENT",
    "EC2_INSTANCE_ID",
}
values = {}
for raw in path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, value = line.split("=", 1)
    values[key.strip()] = value.strip().strip('"').strip("'")
missing = sorted(key for key in required if not values.get(key))
if missing:
    raise SystemExit("ERROR: missing required Alloy OTLP env keys: " + ", ".join(missing))
endpoint = values["GRAFANA_CLOUD_OTLP_ENDPOINT"]
if not (endpoint.startswith("https://") and (".grafana.net" in endpoint or ".grafana.com" in endpoint)):
    raise SystemExit("ERROR: GRAFANA_CLOUD_OTLP_ENDPOINT must be a Grafana Cloud HTTPS endpoint")
for key, value in values.items():
    lowered = value.lower()
    if "<" in value or ">" in value or "placeholder" in lowered or "changeme" in lowered:
        raise SystemExit(f"ERROR: placeholder value is not allowed for {key}")
mode = stat.S_IMODE(path.stat().st_mode)
if mode & 0o077:
    raise SystemExit("ERROR: staged Alloy OTLP env file must not be group/world readable")
PY

sudo install -d -o ubuntu -g ubuntu -m 0755 "$RELEASES_DIR" "$REMOTE_DIR"
sudo install -o ubuntu -g ubuntu -m 0644 "${REMOTE_STAGING_DIR}/${JAR_FILE}" "${RELEASES_DIR}/${JAR_FILE}"
sudo ln -sfn "${RELEASES_DIR}/${JAR_FILE}" "$CURRENT_LINK"
sudo chown -h ubuntu:ubuntu "$CURRENT_LINK"
sudo install -o root -g root -m 0644 "${REMOTE_STAGING_DIR}/shaka-server.conf" /etc/nginx/conf.d/shaka-server.conf
sudo install -o root -g root -m 0644 "${REMOTE_STAGING_DIR}/shaka-server.service" /etc/systemd/system/shaka-server.service
sudo install -o root -g root -m 0644 "${REMOTE_STAGING_DIR}/shaka-env.example" /etc/shaka/env.example
sudo install -o root -g root -m 0644 "${REMOTE_STAGING_DIR}/alloy-otlp-config.alloy" /etc/alloy/config.alloy
sudo install -o root -g root -m 0600 "$obs_env_file" /etc/alloy/shaka-observability.env
sudo install -d -o root -g root -m 0755 /etc/systemd/system/alloy.service.d
sudo tee /etc/systemd/system/alloy.service.d/shaka-observability.conf >/dev/null <<'DROPIN'
[Service]
# Clear the legacy Prometheus remote_write validator from older bootstrap drop-ins.
ExecStartPre=
EnvironmentFile=/etc/alloy/shaka-observability.env
DROPIN

sudo python3 - <<'PY'
from pathlib import Path
path = Path('/etc/shaka/env')
text = path.read_text(encoding='utf-8') if path.exists() else ''
keys = {
    'OTEL_SERVICE_NAME': 'shaka-server',
    'OTEL_RESOURCE_ATTRIBUTES': 'deployment.environment=prod,service.namespace=shaka',
    'OTEL_TRACES_EXPORTER': 'otlp',
    'OTEL_METRICS_EXPORTER': 'otlp',
    'OTEL_LOGS_EXPORTER': 'otlp',
    'OTEL_EXPORTER_OTLP_ENDPOINT': 'http://127.0.0.1:4317',
    'OTEL_EXPORTER_OTLP_PROTOCOL': 'grpc',
    'OTEL_TRACES_SAMPLER': 'parentbased_traceidratio',
    'OTEL_TRACES_SAMPLER_ARG': '0.01',
}
lines = []
existing_java_tool_options = ''
for line in text.splitlines():
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        lines.append(line)
        continue
    name, _, value = stripped.partition('=')
    name = name.strip()
    if name == 'JAVA_TOOL_OPTIONS':
        existing_java_tool_options = value.strip().strip('"').strip("'")
    elif name not in keys:
        lines.append(line)
agent_option = '-javaagent:/opt/shaka/opentelemetry-javaagent.jar'
if agent_option not in existing_java_tool_options:
    keys['JAVA_TOOL_OPTIONS'] = f'{existing_java_tool_options} {agent_option}'.strip()
else:
    keys['JAVA_TOOL_OPTIONS'] = existing_java_tool_options
for key, value in keys.items():
    lines.append(f'{key}={value}')
path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
PY
sudo chown root:ubuntu /etc/shaka/env
sudo chmod 0640 /etc/shaka/env

sudo systemctl daemon-reload
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl restart alloy
sudo systemctl is-active --quiet alloy

set +e
sudo systemctl restart shaka-server
restart_status=$?
set -e
if [[ "$restart_status" -ne 0 ]]; then
  rollback_from_backup
  exit "$restart_status"
fi

for attempt in $(seq 1 12); do
  sleep 5
  health="$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/actuator/health 2>/dev/null || echo '000')"
  echo "  Local health attempt ${attempt}/12: HTTP ${health}"
  if [[ "$health" == "200" ]]; then
    break
  fi
  if [[ "$attempt" == "12" ]]; then
    echo "ERROR: local health check failed after 60 seconds" >&2
    rollback_from_backup
    exit 1
  fi
done
REMOTE_DEPLOY

external_code="$(curl -s -o /dev/null -w '%{http_code}' "${SHAKA_PROD_URL%/}/actuator/health" || echo '000')"
echo "External health: HTTP ${external_code}"
if [[ "$external_code" != "200" ]]; then
  echo "ERROR: external health check failed for ${SHAKA_PROD_URL%/}/actuator/health" >&2
  rollback_remote
  exit 1
fi

"${SSH[@]}" 'curl -fsS http://localhost:8080/actuator/health >/dev/null && sudo systemctl is-active --quiet alloy'
echo "Deploy successful: ${JAR_FILE} with OTLP metrics/logs/traces primary"

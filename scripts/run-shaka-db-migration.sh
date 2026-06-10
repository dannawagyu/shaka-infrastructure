#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/run-shaka-db-migration.sh

Runs the production DB migration gate for the infra-owned server deploy workflow.
The runner executes a trusted Flyway CLI distribution against SQL-only migration
resources; it never runs server Gradle/build logic with production secrets.

Required environment variables:
  SHAKA_MIGRATION_DIR
  DB_MIGRATION_MODE              one of: none, validate-only, apply
  SHAKA_PROD_DB_URL
  SHAKA_PROD_DB_USERNAME
  SHAKA_PROD_DB_PASSWORD
  SHAKA_PROD_HOST
  SHAKA_PROD_SSH_KEY or SHAKA_PROD_SSH_KEY_PATH
  SHAKA_PROD_SSH_KNOWN_HOSTS

Required when DB_MIGRATION_MODE=apply:
  DB_MIGRATION_CONFIRMATION      migrate-shaka-production
  SHAKA_RDS_DB_INSTANCE_IDENTIFIER

Optional environment variables:
  AWS_REGION                     defaults to ap-southeast-2
  SHAKA_PROD_SSH_USER            defaults to ubuntu
  SHAKA_FLYWAY_BASELINE_ON_MIGRATE true only for reviewed first-time Flyway adoption
  SHAKA_FLYWAY_CLI_URL             defaults to pinned Flyway commandline 10.10.0
  SHAKA_FLYWAY_CLI_SHA256          defaults to pinned Flyway commandline 10.10.0 SHA-256
  SHAKA_MYSQL_CONNECTOR_J_URL      defaults to pinned MySQL Connector/J 8.3.0
  SHAKA_MYSQL_CONNECTOR_J_SHA256   defaults to pinned MySQL Connector/J 8.3.0 SHA-256
USAGE
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MIGRATION_DIR="${SHAKA_MIGRATION_DIR:?SHAKA_MIGRATION_DIR is required}"
DB_MIGRATION_MODE="${DB_MIGRATION_MODE:-none}"
DB_MIGRATION_CONFIRMATION="${DB_MIGRATION_CONFIRMATION:-}"
AWS_REGION="${AWS_REGION:-ap-southeast-2}"
SHAKA_PROD_SSH_USER="${SHAKA_PROD_SSH_USER:-ubuntu}"
SHAKA_FLYWAY_BASELINE_ON_MIGRATE="${SHAKA_FLYWAY_BASELINE_ON_MIGRATE:-false}"
SHAKA_FLYWAY_CLI_URL="${SHAKA_FLYWAY_CLI_URL:-https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/10.10.0/flyway-commandline-10.10.0.tar.gz}"
SHAKA_FLYWAY_CLI_SHA256="${SHAKA_FLYWAY_CLI_SHA256:-77dd0af6f85b7caba74126f98920d026ddc3b5682de590322582da7ee957c331}"
SHAKA_MYSQL_CONNECTOR_J_URL="${SHAKA_MYSQL_CONNECTOR_J_URL:-https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.3.0/mysql-connector-j-8.3.0.jar}"
SHAKA_MYSQL_CONNECTOR_J_SHA256="${SHAKA_MYSQL_CONNECTOR_J_SHA256:-94e7fa815370cdcefed915db7f53f88445fac110f8c3818392b992ec9ee6d295}"

case "$DB_MIGRATION_MODE" in
  none|validate-only|apply) ;;
  *)
    echo "ERROR: DB_MIGRATION_MODE must be one of: none, validate-only, apply" >&2
    exit 1
    ;;
esac

case "$SHAKA_FLYWAY_BASELINE_ON_MIGRATE" in
  true|false) ;;
  *)
    echo "ERROR: SHAKA_FLYWAY_BASELINE_ON_MIGRATE must be true or false" >&2
    exit 1
    ;;
esac

: "${SHAKA_PROD_DB_URL:?SHAKA_PROD_DB_URL is required}"
: "${SHAKA_PROD_DB_USERNAME:?SHAKA_PROD_DB_USERNAME is required}"
: "${SHAKA_PROD_DB_PASSWORD:?SHAKA_PROD_DB_PASSWORD is required}"
: "${SHAKA_PROD_HOST:?SHAKA_PROD_HOST is required}"
: "${SHAKA_PROD_SSH_KNOWN_HOSTS:?SHAKA_PROD_SSH_KNOWN_HOSTS is required}"
if [[ ! -d "$MIGRATION_DIR" ]]; then
  echo "ERROR: required migration SQL directory not found: $MIGRATION_DIR" >&2
  exit 1
fi
if ! find "$MIGRATION_DIR" -maxdepth 1 -type f -name 'V*.sql' | grep -q .; then
  echo "ERROR: migration SQL directory has no Flyway versioned migrations: $MIGRATION_DIR" >&2
  exit 1
fi

if [[ "$SHAKA_PROD_DB_URL" =~ [Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]= ]]; then
  echo "ERROR: SHAKA_PROD_DB_URL must not embed a password; pass credentials separately" >&2
  exit 1
fi

mask_for_github() {
  local value="${1:-}"
  if [[ -n "$value" && -n "${GITHUB_ACTIONS:-}" ]]; then
    printf '::add-mask::%s\n' "$value"
  fi
}

mask_for_github "$SHAKA_PROD_DB_URL"
mask_for_github "$SHAKA_PROD_DB_USERNAME"
mask_for_github "$SHAKA_PROD_DB_PASSWORD"

parse_db_url() {
  SHAKA_PROD_DB_URL="$SHAKA_PROD_DB_URL" python3 - <<'PY'
import os
from urllib.parse import urlsplit, urlunsplit

value = os.environ["SHAKA_PROD_DB_URL"]
prefix = "jdbc:mysql://"
if not value.startswith(prefix):
    raise SystemExit("ERROR: SHAKA_PROD_DB_URL must be a MySQL JDBC URL")
parsed = urlsplit("mysql://" + value[len(prefix):])
if not parsed.hostname:
    raise SystemExit("ERROR: SHAKA_PROD_DB_URL must include a database host")
port = parsed.port or 3306
print(parsed.hostname)
print(port)
print(urlunsplit(("mysql", f"127.0.0.1:__LOCAL_PORT__", parsed.path, parsed.query, parsed.fragment)).replace("mysql://", prefix, 1))
PY
}

choose_local_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  printf '%s  %s\n' "$expected" "$file" | shasum -a 256 -c - >/dev/null
}

install_flyway_cli() {
  local work_dir="$1"
  local cli_archive="$work_dir/flyway-cli.tgz"
  local driver_jar="$work_dir/mysql-connector-j.jar"

  curl -fsSL "$SHAKA_FLYWAY_CLI_URL" -o "$cli_archive"
  verify_sha256 "$cli_archive" "$SHAKA_FLYWAY_CLI_SHA256"
  mkdir -p "$work_dir/flyway"
  tar -xzf "$cli_archive" -C "$work_dir/flyway" --strip-components=1

  curl -fsSL "$SHAKA_MYSQL_CONNECTOR_J_URL" -o "$driver_jar"
  verify_sha256 "$driver_jar" "$SHAKA_MYSQL_CONNECTOR_J_SHA256"
  mkdir -p "$work_dir/flyway/drivers"
  cp "$driver_jar" "$work_dir/flyway/drivers/"

  if [[ ! -x "$work_dir/flyway/flyway" ]]; then
    echo "ERROR: trusted Flyway CLI archive did not contain an executable flyway binary" >&2
    exit 1
  fi
  FLYWAY_BIN="$work_dir/flyway/flyway"
}

KEY_FILE="${SHAKA_PROD_SSH_KEY_PATH:-}"
TEMP_KEY=""
KNOWN_HOSTS_FILE=""
SSH_TUNNEL_PID=""
FLYWAY_WORK_DIR=""
info_output=""
cleanup() {
  if [[ -n "$SSH_TUNNEL_PID" ]]; then kill "$SSH_TUNNEL_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$TEMP_KEY" && -f "$TEMP_KEY" ]]; then rm -f "$TEMP_KEY"; fi
  if [[ -n "$KNOWN_HOSTS_FILE" && -f "$KNOWN_HOSTS_FILE" ]]; then rm -f "$KNOWN_HOSTS_FILE"; fi
  if [[ -n "$FLYWAY_WORK_DIR" && -d "$FLYWAY_WORK_DIR" ]]; then rm -rf "$FLYWAY_WORK_DIR"; fi
  rm -f "${info_output:-}"
}
trap cleanup EXIT

if [[ -z "$KEY_FILE" ]]; then
  : "${SHAKA_PROD_SSH_KEY:?SHAKA_PROD_SSH_KEY or SHAKA_PROD_SSH_KEY_PATH is required}"
  TEMP_KEY="$(mktemp)"
  chmod 600 "$TEMP_KEY"
  printf '%s\n' "$SHAKA_PROD_SSH_KEY" > "$TEMP_KEY"
  KEY_FILE="$TEMP_KEY"
fi

KNOWN_HOSTS_FILE="$(mktemp)"
chmod 600 "$KNOWN_HOSTS_FILE"
printf '%s\n' "$SHAKA_PROD_SSH_KNOWN_HOSTS" > "$KNOWN_HOSTS_FILE"

parsed_db="$(parse_db_url)"
DB_HOST="$(printf '%s\n' "$parsed_db" | sed -n '1p')"
DB_PORT="$(printf '%s\n' "$parsed_db" | sed -n '2p')"
LOCAL_DB_URL_TEMPLATE="$(printf '%s\n' "$parsed_db" | sed -n '3p')"
LOCAL_DB_PORT="$(choose_local_port)"
FLYWAY_JDBC_URL="${LOCAL_DB_URL_TEMPLATE/__LOCAL_PORT__/$LOCAL_DB_PORT}"
mask_for_github "$FLYWAY_JDBC_URL"

FLYWAY_WORK_DIR="$(mktemp -d)"
install_flyway_cli "$FLYWAY_WORK_DIR"

wait_for_tunnel() {
  local port="$1"
  local deadline=$((SECONDS + 15))
  while (( SECONDS < deadline )); do
    if ! kill -0 "$SSH_TUNNEL_PID" >/dev/null 2>&1; then
      echo "ERROR: SSH tunnel for production DB migration exited before accepting connections" >&2
      exit 1
    fi
    if python3 - "$port" <<'PY' >/dev/null 2>&1
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1):
    pass
PY
    then
      return 0
    fi
    sleep 1
  done
  echo "ERROR: SSH tunnel for production DB migration did not become reachable" >&2
  exit 1
}

echo "Opening SSH tunnel from runner localhost to production RDS through the app host..."
ssh -i "$KEY_FILE" \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
  -o ExitOnForwardFailure=yes \
  -N \
  -L "127.0.0.1:${LOCAL_DB_PORT}:${DB_HOST}:${DB_PORT}" \
  "${SHAKA_PROD_SSH_USER}@${SHAKA_PROD_HOST}" &
SSH_TUNNEL_PID="$!"
wait_for_tunnel "$LOCAL_DB_PORT"

run_flyway_task() {
  local task="$1"
  shift
  local args=("$@")
  if [[ "$task" == "migrate" && "$SHAKA_FLYWAY_BASELINE_ON_MIGRATE" == "true" ]]; then
    args+=("-baselineOnMigrate=true" "-baselineVersion=0")
  fi
  FLYWAY_URL="$FLYWAY_JDBC_URL" \
    FLYWAY_USER="$SHAKA_PROD_DB_USERNAME" \
    FLYWAY_PASSWORD="$SHAKA_PROD_DB_PASSWORD" \
    FLYWAY_LOCATIONS="filesystem:${MIGRATION_DIR}" \
    "$FLYWAY_BIN" "${args[@]}" "$task"
}

require_backup_readiness() {
  : "${SHAKA_RDS_DB_INSTANCE_IDENTIFIER:?SHAKA_RDS_DB_INSTANCE_IDENTIFIER is required for DB_MIGRATION_MODE=apply}"
  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: aws CLI is required to verify RDS backup readiness before migration apply" >&2
    exit 1
  fi

  local metadata
  metadata="$(aws rds describe-db-instances \
    --region "$AWS_REGION" \
    --db-instance-identifier "$SHAKA_RDS_DB_INSTANCE_IDENTIFIER" \
    --query 'DBInstances[0].{DBInstanceIdentifier:DBInstanceIdentifier,BackupRetentionPeriod:BackupRetentionPeriod,LatestRestorableTime:LatestRestorableTime}' \
    --output json)"

  RDS_BACKUP_METADATA="$metadata" python3 - <<'PY'
import json
import os

metadata = json.loads(os.environ["RDS_BACKUP_METADATA"])
if not isinstance(metadata, dict):
    raise SystemExit("ERROR: RDS DB instance was not found")
identifier = metadata.get("DBInstanceIdentifier")
retention = metadata.get("BackupRetentionPeriod") or 0
latest = metadata.get("LatestRestorableTime")
if not identifier:
    raise SystemExit("ERROR: RDS DB instance was not found")
if retention < 1:
    raise SystemExit("ERROR: RDS automated backup retention must be at least 1 day before migration apply")
if not latest:
    raise SystemExit("ERROR: RDS LatestRestorableTime is missing; PITR is not ready")
print(f"RDS backup readiness verified for {identifier}: retention_days={retention}, latest_restorable_time={latest}")
PY
}

info_output="$(mktemp)"

echo "Running Flyway info for production migration state..."
run_flyway_task info | tee "$info_output"

pending_migrations=0
if grep -Eiq '\|[[:space:]]*Pending[[:space:]]*\|' "$info_output"; then
  pending_migrations=1
fi

if [[ "$DB_MIGRATION_MODE" == "none" && "$pending_migrations" -eq 1 ]]; then
  echo "ERROR: pending Flyway migration detected; rerun with db_migration_mode=apply after approval or validate-only for inspection" >&2
  exit 1
fi

echo "Running Flyway validate for production migration state..."
if [[ "$DB_MIGRATION_MODE" == "none" ]]; then
  run_flyway_task validate
else
  run_flyway_task validate "-ignoreMigrationPatterns=*:pending"
fi

case "$DB_MIGRATION_MODE" in
  none)
    echo "Production DB migration gate passed with no pending migrations; app deploy may continue."
    ;;
  validate-only)
    echo "Production DB migration validate-only completed; app deploy is intentionally skipped."
    ;;
  apply)
    if [[ "$DB_MIGRATION_CONFIRMATION" != "migrate-shaka-production" ]]; then
      echo "ERROR: DB_MIGRATION_MODE=apply requires DB_MIGRATION_CONFIRMATION=migrate-shaka-production" >&2
      exit 1
    fi
    require_backup_readiness
    echo "Running Flyway migrate for approved production migration..."
    run_flyway_task migrate
    echo "Re-running Flyway validate after production migration..."
    run_flyway_task validate
    ;;
esac

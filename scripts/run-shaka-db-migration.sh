#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/run-shaka-db-migration.sh

Runs the production DB migration gate for the infra-owned server deploy workflow.

Required environment variables:
  SHAKA_SERVER_DIR
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
USAGE
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SERVER_DIR="${SHAKA_SERVER_DIR:?SHAKA_SERVER_DIR is required}"
DB_MIGRATION_MODE="${DB_MIGRATION_MODE:-none}"
DB_MIGRATION_CONFIRMATION="${DB_MIGRATION_CONFIRMATION:-}"
AWS_REGION="${AWS_REGION:-ap-southeast-2}"
SHAKA_PROD_SSH_USER="${SHAKA_PROD_SSH_USER:-ubuntu}"
SHAKA_FLYWAY_BASELINE_ON_MIGRATE="${SHAKA_FLYWAY_BASELINE_ON_MIGRATE:-false}"

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

for path in "$SERVER_DIR/gradlew" "$SERVER_DIR/build.gradle" "$SERVER_DIR/src/main/resources/db/migration"; do
  if [[ ! -e "$path" ]]; then
    echo "ERROR: required server migration artifact not found: $path" >&2
    exit 1
  fi
done

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

KEY_FILE="${SHAKA_PROD_SSH_KEY_PATH:-}"
TEMP_KEY=""
KNOWN_HOSTS_FILE=""
SSH_TUNNEL_PID=""
cleanup() {
  if [[ -n "$SSH_TUNNEL_PID" ]]; then kill "$SSH_TUNNEL_PID" >/dev/null 2>&1 || true; fi
  if [[ -n "$TEMP_KEY" && -f "$TEMP_KEY" ]]; then rm -f "$TEMP_KEY"; fi
  if [[ -n "$KNOWN_HOSTS_FILE" && -f "$KNOWN_HOSTS_FILE" ]]; then rm -f "$KNOWN_HOSTS_FILE"; fi
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

echo "Opening SSH tunnel from runner localhost to production RDS through the app host..."
ssh -i "$KEY_FILE" \
  -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
  -o ExitOnForwardFailure=yes \
  -N \
  -L "127.0.0.1:${LOCAL_DB_PORT}:${DB_HOST}:${DB_PORT}" \
  "${SHAKA_PROD_SSH_USER}@${SHAKA_PROD_HOST}" &
SSH_TUNNEL_PID="$!"
sleep 2
if ! kill -0 "$SSH_TUNNEL_PID" >/dev/null 2>&1; then
  echo "ERROR: SSH tunnel for production DB migration failed to start" >&2
  exit 1
fi

run_flyway_task() {
  local task="$1"
  shift
  local args=("$@")
  if [[ "$task" == "flywayMigrate" && "$SHAKA_FLYWAY_BASELINE_ON_MIGRATE" == "true" ]]; then
    args+=("-Dflyway.baselineOnMigrate=true" "-Dflyway.baselineVersion=0")
  fi
  (
    cd "$SERVER_DIR"
    FLYWAY_URL="$FLYWAY_JDBC_URL" \
      FLYWAY_USER="$SHAKA_PROD_DB_USERNAME" \
      FLYWAY_PASSWORD="$SHAKA_PROD_DB_PASSWORD" \
      ./gradlew --no-daemon --console=plain "${args[@]}" "$task"
  )
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
run_flyway_task flywayInfo | tee "$info_output"

pending_migrations=0
if grep -Eiq '(^|[[:space:]\|])Pending([[:space:]\|]|$)' "$info_output"; then
  pending_migrations=1
fi

if [[ "$DB_MIGRATION_MODE" == "none" && "$pending_migrations" -eq 1 ]]; then
  echo "ERROR: pending Flyway migration detected; rerun with db_migration_mode=apply after approval or validate-only for inspection" >&2
  exit 1
fi

echo "Running Flyway validate for production migration state..."
if [[ "$DB_MIGRATION_MODE" == "none" ]]; then
  run_flyway_task flywayValidate
else
  run_flyway_task flywayValidate "-Dflyway.ignoreMigrationPatterns=*:pending"
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
    run_flyway_task flywayMigrate
    echo "Re-running Flyway validate after production migration..."
    run_flyway_task flywayValidate
    ;;
esac

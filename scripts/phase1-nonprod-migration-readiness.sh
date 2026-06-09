#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OFFLINE=0

usage() {
  cat <<'EOF'
Usage: phase1-nonprod-migration-readiness.sh [--offline]

Validates Phase 1 group_member migration readiness inputs without touching
production state, secrets, Terraform state, or live databases.

Environment:
  SHAKA_PHASE1_ENV              local|dev|staging (production/prod forbidden)
  SHAKA_PHASE1_MIGRATION_SQL    path to server Phase 1 migration SQL

Optional operator evidence for real non-prod dry-run handoff:
  SHAKA_PHASE1_BACKUP_REF       sanitized backup/snapshot evidence reference
  SHAKA_PHASE1_RESTORE_REF      sanitized restore rehearsal evidence reference
  SHAKA_PHASE1_ROLLBACK_OWNER   owner/on-call reference for rollback window
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline)
      OFFLINE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "FAIL: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

phase_env="${SHAKA_PHASE1_ENV:-local}"
phase_env_lc="$(printf '%s' "$phase_env" | tr '[:upper:]' '[:lower:]')"
case "$phase_env_lc" in
  prod|production)
    echo "FAIL: production is not allowed for Phase 1 non-prod migration readiness" >&2
    exit 1
    ;;
  local|dev|development|staging)
    ;;
  *)
    echo "FAIL: SHAKA_PHASE1_ENV must be local, dev, or staging; got '$phase_env'" >&2
    exit 1
    ;;
esac

migration_sql="${SHAKA_PHASE1_MIGRATION_SQL:-}"
if [[ -z "$migration_sql" ]]; then
  for candidate in \
    "$ROOT/../shaka-server-spring/src/main/resources/db/migration/V20260607_01__phase1_group_member.sql" \
    "$ROOT/../worktrees/shaka-server-spring-phase1-membership/src/main/resources/db/migration/V20260607_01__phase1_group_member.sql"; do
    if [[ -f "$candidate" ]]; then
      migration_sql="$candidate"
      break
    fi
  done
fi

if [[ -z "$migration_sql" || ! -f "$migration_sql" ]]; then
  echo "FAIL: SHAKA_PHASE1_MIGRATION_SQL must point to the server Phase 1 migration SQL" >&2
  exit 1
fi

drift_sql="$ROOT/scripts/sql/phase1-group-member-drift-check.sql"
repair_sql="$ROOT/scripts/sql/phase1-group-member-repair.sql"
rds_dashboard="$ROOT/terraform/observability/grafana/dashboards/amazon-rds.json.tftpl"
alerts_tf="$ROOT/terraform/observability/grafana/alert-rules.tf"

for required_file in "$drift_sql" "$repair_sql" "$rds_dashboard" "$alerts_tf"; do
  if [[ ! -f "$required_file" ]]; then
    echo "FAIL: missing required readiness file: ${required_file#$ROOT/}" >&2
    exit 1
  fi
done

require_pattern() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eiq "$pattern" "$file"; then
    echo "FAIL: $message (${file#$ROOT/})" >&2
    exit 1
  fi
}

reject_pattern() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if grep -Eiq "$pattern" "$file"; then
    echo "FAIL: destructive SQL or forbidden operation detected: $message (${file#$ROOT/})" >&2
    exit 1
  fi
}

require_pattern "$migration_sql" 'CREATE[[:space:]]+TABLE[[:space:]]+(IF[[:space:]]+NOT[[:space:]]+EXISTS[[:space:]]+)?(`group_member`|group_member([[:space:](]|$))' "migration must create group_member"
require_pattern "$migration_sql" 'ALTER[[:space:]]+TABLE[[:space:]]+(`group`|group([[:space:]]|$))' "migration must add group metadata additively"
require_pattern "$migration_sql" 'INSERT[[:space:]]+INTO[[:space:]]+(`group_member`|group_member([[:space:](]|$))' "migration must backfill group_member"
require_pattern "$migration_sql" 'CREATE[[:space:]]+(OR[[:space:]]+REPLACE[[:space:]]+)?VIEW[[:space:]]+(`v_group_member_drift`|v_group_member_drift([[:space:]]|$))' "migration must expose drift check view"
require_pattern "$migration_sql" 'FOREIGN[[:space:]]+KEY' "migration must include membership foreign keys"

for file in "$migration_sql" "$drift_sql" "$repair_sql"; do
  reject_pattern "$file" 'DROP[[:space:]]+(TABLE|DATABASE)' "DROP table/database is forbidden"
  reject_pattern "$file" 'DROP[[:space:]]+(COLUMN[[:space:]]+)?(`group_id`|group_id([[:space:],;]|$))' "legacy user.group_id cleanup is Phase 2+ and forbidden"
  reject_pattern "$file" 'TRUNCATE[[:space:]]+(TABLE[[:space:]]+)?' "TRUNCATE is forbidden"
  reject_pattern "$file" 'DELETE[[:space:]]+FROM[[:space:]]+(`user`|user([[:space:];]|$))' "deleting users is forbidden"
  reject_pattern "$file" 'terraform[[:space:]]+apply|production[[:space:]]+apply' "production apply is forbidden"
done

for pattern in \
  'missing_active_membership' \
  'legacy_group_mismatch' \
  'orphan_active_membership' \
  'owner_without_active_membership'; do
  require_pattern "$drift_sql" "$pattern" "drift-check SQL must cover $pattern"
done

require_pattern "$repair_sql" 'START[[:space:]]+TRANSACTION' "repair SQL must be transactional"
require_pattern "$repair_sql" 'ON[[:space:]]+DUPLICATE[[:space:]]+KEY[[:space:]]+UPDATE' "repair SQL must be idempotent"
require_pattern "$repair_sql" 'ROLLBACK' "repair SQL must default to dry-run rollback"
reject_pattern "$repair_sql" 'COMMIT[[:space:]]*;' "repair SQL must not commit by default"

for metric in CPUUtilization DatabaseConnections FreeStorageSpace ReadLatency WriteLatency WriteIOPS; do
  require_pattern "$rds_dashboard" "$metric" "RDS dashboard must include $metric"
done
require_pattern "$alerts_tf" 'var[.]cloudwatch_datasource_uid' "RDS alert rules must use the CloudWatch datasource"
require_pattern "$alerts_tf" 'DBInstanceIdentifier[[:space:]]*=[[:space:]]*var[.]rds_db_instance_identifier' "RDS alert rules must scope DBInstanceIdentifier explicitly"
reject_pattern "$alerts_tf" 'DBInstanceIdentifier[[:space:]]*=[[:space:]]*"[*]"' "RDS alert rules must not use wildcard DBInstanceIdentifier"
for alert_uid in \
  phase1_rds_cpu_high \
  phase1_rds_connections_high \
  phase1_rds_storage_low \
  phase1_rds_write_latency_high; do
  require_pattern "$alerts_tf" "$alert_uid" "Phase 1 RDS alert coverage must include $alert_uid"
done
for metric in CPUUtilization DatabaseConnections FreeStorageSpace WriteLatency; do
  require_pattern "$alerts_tf" "$metric" "Phase 1 RDS alert coverage must include $metric"
done

if [[ "$OFFLINE" -eq 0 && "$phase_env_lc" != "local" ]]; then
  : "${SHAKA_PHASE1_BACKUP_REF:?Set sanitized SHAKA_PHASE1_BACKUP_REF before non-prod dry-run handoff}"
  : "${SHAKA_PHASE1_RESTORE_REF:?Set sanitized SHAKA_PHASE1_RESTORE_REF before non-prod dry-run handoff}"
  : "${SHAKA_PHASE1_ROLLBACK_OWNER:?Set SHAKA_PHASE1_ROLLBACK_OWNER before non-prod dry-run handoff}"
fi

cat <<EOF
Phase 1 non-prod migration readiness checks passed.
- environment: $phase_env
- migration SQL: $migration_sql
- drift-check SQL: ${drift_sql#$ROOT/}
- repair SQL: ${repair_sql#$ROOT/}
- RDS dashboard metrics: CPUUtilization, DatabaseConnections, FreeStorageSpace, ReadLatency, WriteLatency, WriteIOPS
- RDS alert coverage: phase1_rds_cpu_high, phase1_rds_connections_high, phase1_rds_storage_low, phase1_rds_write_latency_high
- mode: $([[ "$OFFLINE" -eq 1 ]] && echo offline || echo operator-evidence)
EOF

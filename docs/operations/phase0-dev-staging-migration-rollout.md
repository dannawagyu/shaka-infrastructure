# Phase 0 Dev/Staging Migration Rollout Guardrail

Status: Phase 0 readiness check only. This document does not authorize production apply, production state mutation, or secret changes.

## Scope

Use this runbook before any Phase 1 schema migration branch begins. It covers dev/staging rehearsal planning for the motion/schema/server/iOS incremental rollout.

Allowed in Phase 0:

- dev/staging plan-only validation,
- backup and rollback checklist review,
- observability evidence review,
- Terraform formatting/validation and repository tests.

Forbidden in Phase 0:

- production apply,
- production Terraform state mutation,
- production secret changes,
- production database migration,
- v1-to-v2 data rewrite.

## Dev/staging preflight

1. Confirm the server branch has passed the v1 group/note contract tests and schema baseline test.
2. Confirm the iOS branch builds with the intended DesignSystem/Motion target inclusion or records why motion sources are intentionally excluded.
3. Run infra validation without backend state writes:

   ```bash
   ./scripts/validate-terraform-ci.sh
   python3 -m unittest discover -s tests -v
   ```

4. Record the target environment, expected schema version, rollback owner, and observability dashboard links in the release checklist.

## Backup checklist

Before a dev/staging rehearsal, capture:

- current application version and commit SHA,
- database endpoint and schema snapshot identifier,
- app deploy artifact or image reference,
- rollback command owner and communication channel,
- timestamped backup/export evidence.

Do not store secrets, database credentials, Terraform state, or raw dumps in git.

## Rollback decision matrix

Rollback immediately when any of these appear during dev/staging rehearsal:

| Signal | Action | Evidence |
| --- | --- | --- |
| Migration validation fails | Stop rollout and restore from the rehearsal backup | validation log |
| Server v1 contract regression | Revert the server artifact, keep data untouched | failing test/log |
| iOS launch/build regression | Revert iOS artifact, keep server schema unchanged | build/test log |
| Observability gap | Pause rollout; do not continue to Phase 1 | dashboard/screenshot gap |

## Observability checklist

Before considering Phase 1, capture dev/staging evidence for:

- application health endpoint status,
- API 4xx/5xx rate around `/api/v1/group` and `/api/v1/note`,
- server startup logs after clean schema bootstrap,
- migration rehearsal duration and failure/rollback logs,
- Grafana/Loki/Tempo dashboard availability where configured.

## Production guardrail

Production actions remain out of scope for Phase 0. A separate reviewed approval must exist before production plan/apply, secret rotation, Terraform state import/move, or production database migration.

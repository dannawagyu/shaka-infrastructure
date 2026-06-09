#!/usr/bin/env python3
"""Executable guardrails for Phase 1 non-prod migration readiness."""
from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "phase1-nonprod-migration-readiness.sh"
DRIFT_SQL = ROOT / "scripts" / "sql" / "phase1-group-member-drift-check.sql"
REPAIR_SQL = ROOT / "scripts" / "sql" / "phase1-group-member-repair.sql"
RDS_DASHBOARD = ROOT / "terraform" / "observability" / "grafana" / "dashboards" / "amazon-rds.json.tftpl"
ALERTS_TF = ROOT / "terraform" / "observability" / "grafana" / "alert-rules.tf"
VARIABLES_TF = ROOT / "terraform" / "observability" / "grafana" / "variables.tf"
PHASE1_RDS_ALERT_UIDS = {
    "phase1_rds_cpu_high",
    "phase1_rds_connections_high",
    "phase1_rds_storage_low",
    "phase1_rds_write_latency_high",
}


VALID_MIGRATION_SQL = """
ALTER TABLE `group` ADD COLUMN `owner_id` BIGINT NULL;
ALTER TABLE `group` ADD COLUMN `status` VARCHAR(20) NOT NULL DEFAULT 'ACTIVE';
ALTER TABLE `group` ADD COLUMN `deleted_at` DATETIME(6) NULL;
CREATE TABLE IF NOT EXISTS `group_member` (
  `id` BIGINT NOT NULL AUTO_INCREMENT,
  `group_id` BIGINT NOT NULL,
  `user_id` BIGINT NOT NULL,
  PRIMARY KEY (`id`),
  CONSTRAINT `uk_group_member_group_user` UNIQUE (`group_id`, `user_id`),
  CONSTRAINT `fk_group_member_group` FOREIGN KEY (`group_id`) REFERENCES `group` (`id`),
  CONSTRAINT `fk_group_member_user` FOREIGN KEY (`user_id`) REFERENCES `user` (`id`)
);
INSERT INTO `group_member` (`group_id`, `user_id`, `role`, `status`)
SELECT u.`group_id`, u.`id`, 'MEMBER', 'ACTIVE'
FROM `user` u JOIN `group` g ON g.`id` = u.`group_id`;
CREATE OR REPLACE VIEW `v_group_member_drift` AS SELECT 1;
"""


class Phase1MigrationReadinessTest(unittest.TestCase):
    def write_sql_fixture(self, body: str = VALID_MIGRATION_SQL) -> Path:
        temp = tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False)
        self.addCleanup(lambda: Path(temp.name).unlink(missing_ok=True))
        temp.write(textwrap.dedent(body))
        temp.close()
        return Path(temp.name)

    def run_script(
        self,
        migration_sql: Path,
        environment: str = "staging",
        offline: bool = True,
        extra_env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env["SHAKA_PHASE1_ENV"] = environment
        env["SHAKA_PHASE1_MIGRATION_SQL"] = str(migration_sql)
        if extra_env:
            env.update(extra_env)
        args = ["bash", str(SCRIPT)]
        if offline:
            args.append("--offline")
        return subprocess.run(
            args,
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_readiness_script_passes_offline_with_safe_migration_sql(self) -> None:
        result = self.run_script(self.write_sql_fixture())

        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("Phase 1 non-prod migration readiness checks passed", result.stdout)
        self.assertIn("drift-check SQL", result.stdout)
        self.assertIn("repair SQL", result.stdout)
        self.assertIn("RDS dashboard metrics", result.stdout)
        self.assertIn("alert coverage", result.stdout)

    def test_readiness_script_refuses_production_environment(self) -> None:
        result = self.run_script(self.write_sql_fixture(), environment="production")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("production is not allowed", result.stderr)

    def test_readiness_script_rejects_destructive_sql(self) -> None:
        migration = self.write_sql_fixture(VALID_MIGRATION_SQL + "\nALTER TABLE `user` DROP COLUMN `group_id`;")

        result = self.run_script(migration)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("destructive SQL", result.stderr)

    def test_readiness_script_rejects_drop_group_id_without_column_keyword(self) -> None:
        migration = self.write_sql_fixture(VALID_MIGRATION_SQL + "\nALTER TABLE `user` DROP `group_id`;")

        result = self.run_script(migration)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("destructive SQL", result.stderr)

    def test_readiness_script_rejects_truncate_without_table_keyword(self) -> None:
        migration = self.write_sql_fixture(VALID_MIGRATION_SQL + "\nTRUNCATE `group_member`;")

        result = self.run_script(migration)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("destructive SQL", result.stderr)

    def test_readiness_script_does_not_treat_group_member_prefix_as_group_metadata(self) -> None:
        migration = self.write_sql_fixture("""
        ALTER TABLE `group_member` ADD COLUMN `owner_id` BIGINT NULL;
        CREATE TABLE `group_member` (
          `id` BIGINT NOT NULL AUTO_INCREMENT,
          `group_id` BIGINT NOT NULL,
          `user_id` BIGINT NOT NULL,
          PRIMARY KEY (`id`),
          CONSTRAINT `fk_group_member_group` FOREIGN KEY (`group_id`) REFERENCES `group` (`id`)
        );
        INSERT INTO `group_member` (`group_id`, `user_id`, `role`, `status`)
        SELECT u.`group_id`, u.`id`, 'MEMBER', 'ACTIVE' FROM `user` u;
        CREATE VIEW `v_group_member_drift` AS SELECT 1;
        """)

        result = self.run_script(migration)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("migration must add group metadata", result.stderr)

    def test_non_offline_staging_handoff_requires_backup_restore_and_owner_refs(self) -> None:
        migration = self.write_sql_fixture()

        missing_evidence = self.run_script(migration, offline=False)

        self.assertNotEqual(missing_evidence.returncode, 0)
        self.assertIn("SHAKA_PHASE1_BACKUP_REF", missing_evidence.stderr)

        with_evidence = self.run_script(
            migration,
            offline=False,
            extra_env={
                "SHAKA_PHASE1_BACKUP_REF": "sanitized-snapshot-ref",
                "SHAKA_PHASE1_RESTORE_REF": "sanitized-restore-drill-ref",
                "SHAKA_PHASE1_ROLLBACK_OWNER": "on-call-owner",
            },
        )

        self.assertEqual(with_evidence.returncode, 0, with_evidence.stderr + with_evidence.stdout)
        self.assertIn("mode: operator-evidence", with_evidence.stdout)

    def test_drift_and_repair_sql_cover_phase1_compatibility_cases(self) -> None:
        drift = DRIFT_SQL.read_text(encoding="utf-8")
        repair = REPAIR_SQL.read_text(encoding="utf-8")

        for phrase in [
            "missing_active_membership",
            "legacy_group_mismatch",
            "orphan_active_membership",
            "owner_without_active_membership",
            "`user`.`group_id`",
            "`group_member`",
        ]:
            self.assertIn(phrase, drift)

        for phrase in [
            "START TRANSACTION",
            "INSERT INTO `group_member`",
            "ON DUPLICATE KEY UPDATE",
            "AS `member_role`",
            "`role` = `member_role`",
            "LEFT JOIN `group`",
            "`group`.`id` IS NULL",
            "status` = 'LEFT'",
            "post_repair_missing_active_membership",
            "post_repair_legacy_group_mismatch",
            "post_repair_orphan_active_membership",
            "post_repair_owner_without_active_membership",
            "ROLLBACK",
        ]:
            self.assertIn(phrase, repair)
        self.assertNotIn("COMMIT;", repair, "repair script must default to dry-run rollback")
        self.assertNotIn("VALUES(`role`)", repair)
        self.assertNotIn("DROP COLUMN", repair)
        self.assertNotIn("DROP TABLE", repair)

    def test_db_metric_and_alert_surfaces_exist_for_migration_window(self) -> None:
        dashboard = RDS_DASHBOARD.read_text(encoding="utf-8")
        alerts = ALERTS_TF.read_text(encoding="utf-8")
        variables = VARIABLES_TF.read_text(encoding="utf-8")

        for metric in [
            "CPUUtilization",
            "DatabaseConnections",
            "FreeStorageSpace",
            "ReadLatency",
            "WriteLatency",
            "WriteIOPS",
        ]:
            self.assertIn(metric, dashboard)
        self.assertIn("var.cloudwatch_datasource_uid", alerts)
        self.assertIn("var.cloudwatch_region", alerts)
        self.assertIn('no_data_state  = "Alerting"', alerts)
        for alert_uid in PHASE1_RDS_ALERT_UIDS:
            self.assertIn(alert_uid, alerts)
        for metric in [
            "CPUUtilization",
            "DatabaseConnections",
            "FreeStorageSpace",
            "WriteLatency",
        ]:
            self.assertIn(metric, alerts)
        for unit in [
            'unit       = "Percent"',
            'unit       = "Count"',
            'unit       = "Bytes"',
            'unit       = "Seconds"',
        ]:
            self.assertIn(unit, alerts)
        self.assertIn("rds_db_instance_identifier", variables)
        self.assertIn("missing configuration fails closed", variables)
        self.assertNotIn('default     = "shaka-prod-mysql"', variables)
        self.assertIn("DBInstanceIdentifier = var.rds_db_instance_identifier", alerts)
        self.assertNotIn('DBInstanceIdentifier = "*"', alerts)
        self.assertIn("matchExact    = true", alerts)
        self.assertIn("broadly-permissioned CloudWatch datasource", alerts)
        self.assertNotIn("terraform apply", alerts)


if __name__ == "__main__":
    unittest.main()

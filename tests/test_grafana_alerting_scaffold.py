#!/usr/bin/env python3
"""Static checks for issue #2 Grafana Cloud alerting Terraform scaffold."""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GRAFANA_DIR = ROOT / "terraform" / "observability" / "grafana"
PROD_USER_DATA = ROOT / "terraform" / "environments" / "prod" / "templates" / "app-user-data.sh.tftpl"
DOC = ROOT / "docs" / "observability" / "grafana-alerting.md"

EXPECTED_ALERT_UIDS = {
    "app_scrape_down",
    "host_scrape_down",
    "http_5xx",
    "jvm_heap_high",
    "root_disk_warn",
    "root_disk_critical",
    "memory_pressure",
    "cpu_saturation",
    "core_systemd_service_down",
    "alloy_down",
}


class GrafanaAlertingScaffoldTest(unittest.TestCase):
    def read_all_tf(self) -> str:
        self.assertTrue(GRAFANA_DIR.is_dir(), f"missing Terraform scaffold: {GRAFANA_DIR}")
        tf_files = sorted(GRAFANA_DIR.glob("*.tf"))
        self.assertTrue(tf_files, f"no Terraform files under {GRAFANA_DIR}")
        return "\n".join(path.read_text() for path in tf_files)

    def test_grafana_inputs_are_sensitive_and_provider_scaffold_exists(self) -> None:
        tf = self.read_all_tf()
        self.assertIn("required_providers", tf)
        self.assertIn("grafana/grafana", tf)
        self.assertRegex(tf, r'variable\s+"grafana_cloud_url"[\s\S]*?sensitive\s+=\s+true')
        self.assertRegex(tf, r'variable\s+"grafana_auth"[\s\S]*?sensitive\s+=\s+true')
        self.assertIn('provider "grafana"', tf)
        self.assertIn("var.grafana_cloud_url", tf)
        self.assertIn("var.grafana_auth", tf)
        forbidden = ["discord.com/api/" + "webhooks", "hooks.slack.com", "glc" + "_", "eyJrIj"]
        for needle in forbidden:
            self.assertNotIn(needle, tf, f"committed secret/webhook-looking value: {needle}")

    def test_rfc_0010_alert_coverage_by_uid(self) -> None:
        tf = self.read_all_tf()
        found = set(re.findall(r'([a-z0-9_]+)\s+=\s+\{', tf))
        missing = EXPECTED_ALERT_UIDS - found
        self.assertFalse(missing, f"missing alert rule uid(s): {sorted(missing)}")
        self.assertIn("var.runbook_base_url", tf)
        self.assertIn("intervalMs    = 15000", tf)
        self.assertIn('query     = { params = ["B"] }', tf)
        for query_part in ["sum by (instance, job) (rate(http_server_requests_seconds_count", "sum by (instance, job) (jvm_memory_used_bytes", "avg by (instance, job) (rate(node_cpu_seconds_total"]:
            self.assertIn(query_part, tf)
        self.assertIn('up{job=\\"shaka-server\\"}', tf)
        self.assertIn('up{job=\\"shaka-host\\"}', tf)
        self.assertIn('(shaka-server|nginx)\\\\.service', tf)
        self.assertNotIn('(shaka-server|nginx)\\\\\\\\.service', tf)
        self.assertNotIn('(shaka-server|mysql|nginx)', tf)
        self.assertNotIn('query     = { params = ["C"] }', tf)
        self.assertNotIn("intervalMs    = 1000", tf)
        self.assertNotIn('runbook_url = "https://github.com/dannawagyu/shaka-infrastructure/blob/main/docs/observability/grafana-alerting.md"', tf)
        self.assertNotIn(
            "grafana_contact_point",
            tf,
            "Discord contact point should be documented as manual unless secret-in-state tradeoff changes",
        )

    def test_docs_cover_safe_operations_and_discord_test(self) -> None:
        self.assertTrue(DOC.is_file(), f"missing runbook: {DOC}")
        text = DOC.read_text()
        required_phrases = [
            "terraform init -backend=false",
            "terraform plan",
            "TF_VAR_grafana_cloud_url",
            "TF_VAR_grafana_auth",
            "Discord contact point",
            "manual",
            "test notification",
            "Closes #2",
        ]
        for phrase in required_phrases:
            self.assertIn(phrase, text, f"docs missing phrase: {phrase}")

    def test_ec2_alloy_labels_and_runtime_secret_validation_match_alerts(self) -> None:
        self.assertTrue(PROD_USER_DATA.is_file(), f"missing EC2 user_data template: {PROD_USER_DATA}")
        user_data = PROD_USER_DATA.read_text()
        for phrase in [
            'target_label = "job"',
            'replacement  = "shaka-server"',
            'replacement  = "shaka-host"',
            'target_label = "service_name"',
            'target_label = "deployment_environment"',
            'unit_include = "^(shaka-server|nginx|alloy)\\\\.service$"',
            'enable_collectors = ["systemd"]',
            'ExecStartPre=/usr/local/sbin/validate-alloy-grafana-cloud-env',
            'owner_group="$(stat -c',
            '(permissions & 8#077) != 0',
            'GRAFANA_PROMETHEUS_REMOTE_WRITE_URL',
            'GRAFANA_PROMETHEUS_REMOTE_WRITE_USER',
            'GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN',
        ]:
            self.assertIn(phrase, user_data, f"user_data missing phrase: {phrase}")
        self.assertNotIn("glc_", user_data)
        self.assertNotRegex(user_data, r"(?m)^\\s*enabled_collectors\\s*=")


if __name__ == "__main__":
    unittest.main()

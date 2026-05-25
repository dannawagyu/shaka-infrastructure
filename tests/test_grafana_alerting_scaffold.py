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
    "http_5xx",
    "jvm_heap_high",
    "root_disk_warn",
    "root_disk_critical",
    "memory_pressure",
    "cpu_saturation",
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
        for query_part in [
            'target_info{service_name=\\"shaka-server\\",deployment_environment=\\"${var.environment}\\"}',
            'system_cpu_time_seconds{service_name=\\"shaka-host\\",deployment_environment=\\"${var.environment}\\"}',
            'http_server_request_duration_seconds_count{service_name=\\"shaka-server\\",deployment_environment=\\"${var.environment}\\"',
            'jvm_memory_used_bytes{service_name=\\"shaka-server\\",deployment_environment=\\"${var.environment}\\",jvm_memory_type=\\"heap\\"}',
            'system_filesystem_utilization_ratio{service_name=\\"shaka-host\\",deployment_environment=\\"${var.environment}\\"',
            'system_memory_utilization_ratio{service_name=\\"shaka-host\\",deployment_environment=\\"${var.environment}\\",state=\\"used\\"}',
        ]:
            self.assertIn(query_part, tf)
        self.assertIn('absent_over_time(', tf)
        self.assertIn('or vector(0)', tf)
        self.assertIn('no_data_state  = "OK"', tf)
        self.assertNotIn('up{job=\\"shaka-server\\"}', tf)
        self.assertNotIn('up{job=\\"shaka-host\\"}', tf)
        self.assertNotIn('node_systemd_unit_state', tf)
        self.assertNotIn('(shaka-server|mysql|nginx)', tf)
        self.assertNotIn('query     = { params = ["C"] }', tf)
        self.assertNotIn("intervalMs    = 1000", tf)
        self.assertNotIn('runbook_url = "https://github.com/dannawagyu/shaka-infrastructure/blob/main/docs/observability/grafana-alerting.md"', tf)
        self.assertNotIn(
            "grafana_contact_point",
            tf,
            "Discord contact point should be documented as manual unless secret-in-state tradeoff changes",
        )

    def test_memory_pressure_alert_is_available_memory_below_10_percent(self) -> None:
        tf = self.read_all_tf()
        memory_rule = re.search(r'memory_pressure\s+=\s+\{(?P<body>[\s\S]*?)\n\s+\}', tf)
        self.assertIsNotNone(memory_rule, "missing memory_pressure alert rule")
        body = memory_rule.group('body')
        self.assertIn('system_memory_utilization_ratio', body)
        self.assertIn(r'service_name=\"shaka-host\"', body)
        self.assertIn(r'state=\"used\"', body)
        self.assertIn('> 0.90', body)
        self.assertIn('available memory is below 10%', body)
        self.assertIn('usage above 90%', body)

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

    def test_otlp_alloy_config_labels_match_alert_queries(self) -> None:
        alloy = ROOT / "deploy" / "grafana" / "alloy-otlp-config.alloy"
        self.assertTrue(alloy.is_file(), f"missing OTLP Alloy config: {alloy}")
        text = alloy.read_text()
        for phrase in [
            'otelcol.receiver.otlp "shaka"',
            'otelcol.receiver.hostmetrics "shaka_host"',
            'collection_interval = "30s"',
            'key    = "service.name"',
            'value  = sys.env("OTEL_SERVICE_NAME")',
            'value  = "shaka-host"',
            'key    = "deployment.environment"',
            'value  = sys.env("OTEL_DEPLOYMENT_ENVIRONMENT")',
            'metrics = [otelcol.processor.resource.shaka_host.input]',
            'metrics = [otelcol.exporter.otlphttp.grafana_cloud.input]',
        ]:
            self.assertIn(phrase, text, f"OTLP Alloy config missing phrase: {phrase}")
        self.assertNotIn("GRAFANA_PROMETHEUS_REMOTE_WRITE", text)
        self.assertNotIn("glc_", text)



if __name__ == "__main__":
    unittest.main()

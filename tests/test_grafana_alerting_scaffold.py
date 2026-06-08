#!/usr/bin/env python3
"""Static checks for issue #2 Grafana Cloud alerting Terraform scaffold."""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GRAFANA_DIR = ROOT / "terraform" / "observability" / "grafana"
PROD_USER_DATA = ROOT / "terraform" / "environments" / "prod" / "templates" / "app-user-data.sh.tftpl"
README = ROOT / "README.md"

EXPECTED_ALERT_UIDS = {
    "app_scrape_down",
    "http_5xx",
    "jvm_heap_high",
    "root_disk_warn",
    "root_disk_critical",
    "memory_pressure",
    "cpu_saturation",
    "core_systemd_service_down",
    "alloy_down",
}

PHASE1_RDS_ALERT_UIDS = {
    "phase1_rds_cpu_high",
    "phase1_rds_connections_high",
    "phase1_rds_storage_low",
    "phase1_rds_write_latency_high",
}

EXPLICIT_ALERT_UIDS = EXPECTED_ALERT_UIDS | PHASE1_RDS_ALERT_UIDS


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
        for uid in EXPLICIT_ALERT_UIDS:
            self.assertRegex(
                tf,
                rf'{uid}\s+=\s+\{{[\s\S]*?uid\s+=\s+"{uid}"',
                f"alert rule {uid} must declare its Grafana UID explicitly",
            )
        groups = {
            "RFC-0010": re.search(
                r'resource "grafana_rule_group" "shaka_rfc_0010" \{(?P<body>[\s\S]*?)\nresource "grafana_rule_group" "shaka_phase1_rds_migration_window"',
                tf,
            ),
            "Phase 1 RDS": re.search(
                r'resource "grafana_rule_group" "shaka_phase1_rds_migration_window" \{(?P<body>[\s\S]*)',
                tf,
            ),
        }
        for name, match in groups.items():
            self.assertIsNotNone(match, f"missing {name} alert rule group")
            self.assertIn("uid            = rule.value.uid", match.group("body"))
            self.assertNotIn("uid            = rule.key", match.group("body"))
        self.assertIn("var.runbook_base_url", tf)
        self.assertIn("intervalMs    = 15000", tf)
        self.assertIn('query     = { params = ["B"] }', tf)
        for query_part in [
            'target_info{service_name=\\"shaka-server\\",deployment_environment=\\"${var.environment}\\"}',
            'http_server_request_duration_seconds_count{service_name=\\"shaka-server\\",deployment_environment=\\"${var.environment}\\"',
            'jvm_memory_used_bytes{service_name=\\"shaka-server\\",deployment_environment=\\"${var.environment}\\",jvm_memory_type=\\"heap\\"}',
            'node_cpu_seconds_total{service_name=\\"shaka-host\\",deployment_environment=\\"${var.environment}\\",mode=\\"idle\\"}',
            'node_memory_MemAvailable_bytes{service_name=\\"shaka-host\\",deployment_environment=\\"${var.environment}\\"}',
            'node_memory_MemTotal_bytes{service_name=\\"shaka-host\\",deployment_environment=\\"${var.environment}\\"}',
            'node_filesystem_avail_bytes{service_name=\\"shaka-host\\",deployment_environment=\\"${var.environment}\\",mountpoint=\\"/\\",fstype!~\\"tmpfs|overlay\\"}',
            'node_filesystem_size_bytes{service_name=\\"shaka-host\\",deployment_environment=\\"${var.environment}\\",mountpoint=\\"/\\",fstype!~\\"tmpfs|overlay\\"}',
            'sum by (service_instance_id)',
        ]:
            self.assertIn(query_part, tf)
        self.assertIn('absent_over_time(', tf)
        self.assertIn('or vector(0)', tf)
        self.assertIn('no_data_state  = "OK"', tf)
        self.assertNotIn('up{job=\\"shaka-server\\"}', tf)
        self.assertNotIn('up{job=\\"shaka-host\\"}', tf)
        self.assertIn('node_systemd_unit_state', tf)
        self.assertIn('node_systemd_unit_state{service_name=\\"shaka-host\\",deployment_environment=\\"${var.environment}\\",name=~\\"(shaka-server|nginx|alloy)[.]service\\",state=\\"active\\"} == bool 0', tf)
        self.assertIn('(shaka-server|nginx|alloy)[.]service', tf)
        self.assertNotIn('(shaka-server|mysql|nginx)', tf)
        self.assertNotIn('query     = { params = ["C"] }', tf)
        self.assertNotIn("intervalMs    = 1000", tf)
        self.assertNotIn('runbook_url = "https://github.com/dannawagyu/shaka-infrastructure/blob/main/docs/observability/grafana-alerting.md"', tf)
        self.assertNotIn(
            "grafana_contact_point",
            tf,
            "Discord contact point should be documented as manual unless secret-in-state tradeoff changes",
        )

    def test_host_alerts_use_node_exporter_metrics_without_otlp_hostmetrics(self) -> None:
        tf = self.read_all_tf()
        alloy = (ROOT / "deploy" / "grafana" / "alloy-otlp-config.alloy").read_text()
        prod_user_data = PROD_USER_DATA.read_text()
        forbidden_system_metrics = [
            "system_cpu_time_seconds_total",
            "system_memory_usage_bytes",
            "system_filesystem_usage_bytes",
            "system_filesystem_limit_bytes",
        ]

        self.assertNotIn("otelcol.receiver.hostmetrics", alloy)
        self.assertIn('prometheus.exporter.unix "shaka_host"', prod_user_data)
        self.assertIn('prometheus.remote_write "grafana_cloud"', prod_user_data)
        for metric in forbidden_system_metrics:
            self.assertNotIn(metric, tf, f"active alert rules must not query uncollected OTel host metric {metric}")

        for metric in [
            "node_cpu_seconds_total",
            "node_memory_MemAvailable_bytes",
            "node_memory_MemTotal_bytes",
            "node_filesystem_avail_bytes",
            "node_filesystem_size_bytes",
            "node_systemd_unit_state",
        ]:
            self.assertIn(metric, tf)
        self.assertIn('service_name=\\"shaka-host\\"', tf)
        self.assertIn('deployment_environment=\\"${var.environment}\\"', tf)
        self.assertIn('absent_over_time(node_cpu_seconds_total{service_name=\\"shaka-host\\",deployment_environment=\\"${var.environment}\\"}[10m]) or vector(0)', tf)
        self.assertIn('title     = "Shaka host metrics heartbeat missing"', tf)
        self.assertIn('no_data_state  = "OK"', tf)

    def test_memory_pressure_alert_is_available_memory_below_10_percent(self) -> None:
        tf = self.read_all_tf()
        memory_rule = re.search(r'memory_pressure\s+=\s+\{(?P<body>[\s\S]*?)\n\s+\}', tf)
        self.assertIsNotNone(memory_rule, "missing memory_pressure alert rule")
        body = memory_rule.group('body')
        self.assertIn('node_memory_MemAvailable_bytes', body)
        self.assertIn('node_memory_MemTotal_bytes', body)
        self.assertIn(r'service_name=\"shaka-host\"', body)
        self.assertIn('< 0.10', body)
        self.assertIn('available memory is below 10%', body)
        self.assertNotIn('system_memory_usage_bytes', body)

    def test_runbook_moved_to_canonical_wiki(self) -> None:
        text = README.read_text()
        self.assertIn("shaka-wiki", text)
        self.assertIn("engineering/repository-docs/shaka-infrastructure", text)
        tf = self.read_all_tf()
        self.assertIn("WagyuShark/shaka-wiki", tf)

    def test_otlp_alloy_pipeline_uses_only_supported_alloy_components(self) -> None:
        # Host-level signals (system_*) are not collected in this config: the
        # OTel hostmetrics receiver is not packaged as an Alloy component and
        # neither is the OTel resource processor. Host metrics are collected by
        # prometheus.exporter.unix in production user data, while this file stays
        # OTLP-only for app telemetry. service.name and
        # deployment.environment are set by the Java agent on every OTLP signal,
        # so the Alloy transform only needs to inject service.instance.id.
        alloy = ROOT / "deploy" / "grafana" / "alloy-otlp-config.alloy"
        self.assertTrue(alloy.is_file(), f"missing OTLP Alloy config: {alloy}")
        text = alloy.read_text()
        for phrase in [
            'otelcol.receiver.otlp "shaka"',
            'otelcol.processor.transform "shaka"',
            'sys.env("EC2_INSTANCE_ID")',
            'metrics = [otelcol.processor.transform.shaka.input]',
            'metrics = [otelcol.exporter.otlphttp.grafana_cloud.input]',
        ]:
            self.assertIn(phrase, text, f"OTLP Alloy config missing phrase: {phrase}")
        self.assertNotIn("otelcol.receiver.hostmetrics", text)
        self.assertNotIn("otelcol.processor.resource", text)
        self.assertNotIn('set(attributes["service.name"]', text)
        self.assertNotIn('set(attributes["deployment.environment"]', text)
        self.assertNotIn("GRAFANA_PROMETHEUS_REMOTE_WRITE", text)
        self.assertNotIn("glc_", text)



if __name__ == "__main__":
    unittest.main()

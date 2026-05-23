#!/usr/bin/env python3
"""Static checks for Shaka Grafana dashboard-as-code."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GRAFANA_DIR = ROOT / "terraform" / "observability" / "grafana"
DASHBOARDS_TF = GRAFANA_DIR / "dashboards.tf"
DASHBOARD = GRAFANA_DIR / "dashboards" / "shaka-prod-overview.json.tftpl"
DOC = ROOT / "docs" / "observability" / "grafana-dashboards.md"

REQUIRED_QUERIES = [
    'up{job="shaka-server",deployment_environment="prod"}',
    'up{job="shaka-host",deployment_environment="prod"}',
    'jvm_memory_used_bytes{job="shaka-server",deployment_environment="prod",',
    'node_cpu_seconds_total{job="shaka-host",deployment_environment="prod",',
    'node_systemd_unit_state{job="shaka-host",deployment_environment="prod",',
    'http_server_requests_seconds_count{job="shaka-server",deployment_environment="prod",',
    'node_filesystem_avail_bytes{job="shaka-host",deployment_environment="prod",',
]

FORBIDDEN = [
    "discord.com/api/" + "webhooks",
    "glc_",
    "eyJrIj",
    "GRAFANA_CLOUD_API_KEY",
    "GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN",
]

class GrafanaDashboardsTest(unittest.TestCase):
    def rendered_dashboard(self) -> dict:
        rendered = DASHBOARD.read_text().replace('${prometheus_datasource_uid}', 'prometheus-test-uid').replace('${environment_title}', 'Prod').replace('${environment}', 'prod')
        return json.loads(rendered)

    def panel_by_title(self, title: str) -> dict:
        model = self.rendered_dashboard()
        for panel in model.get('panels', []):
            if panel.get('title') == title:
                return panel
        self.fail(f"dashboard missing panel titled {title!r}")

    def test_dashboard_resource_and_template_exist(self) -> None:
        self.assertTrue(DASHBOARDS_TF.is_file(), "missing dashboards.tf")
        self.assertTrue(DASHBOARD.is_file(), "missing Shaka dashboard template")
        tf = DASHBOARDS_TF.read_text()
        self.assertIn('resource "grafana_dashboard" "shaka_prod_overview"', tf)
        self.assertIn('grafana_folder.shaka_observability.uid', tf)
        self.assertIn('templatefile("${path.module}/dashboards/shaka-prod-overview.json.tftpl"', tf)
        self.assertIn('prometheus_datasource_uid = var.prometheus_datasource_uid', tf)
        self.assertIn('overwrite = true', tf)

    def test_dashboard_json_is_parseable_after_template_substitution(self) -> None:
        model = self.rendered_dashboard()
        self.assertEqual(model['uid'], 'shaka-prod-overview')
        self.assertEqual(model['title'], 'Shaka Prod Overview')
        self.assertGreaterEqual(len(model.get('panels', [])), 10)
        self.assertEqual(model.get('refresh'), '30s')
        self.assertIn('terraform', model.get('tags', []))

    def test_dashboard_queries_match_live_alloy_labels(self) -> None:
        model = self.rendered_dashboard()
        expressions = []
        for panel in model.get('panels', []):
            for target in panel.get('targets', []):
                if 'expr' in target:
                    expressions.append(target['expr'])
        expression_text = "\n".join(expressions)
        for query in REQUIRED_QUERIES:
            self.assertIn(query, expression_text, f"dashboard missing query evidence: {query}")
        self.assertNotIn('mysql.service', expression_text)
        self.assertNotIn('127.0.0.1:9090', expression_text)
        self.assertNotIn('service_instance_id', expression_text)
        self.assertNotIn('instance,', expression_text)

    def test_http_5xx_panel_falls_back_to_zero_when_no_error_series(self) -> None:
        panel = self.panel_by_title('HTTP 5xx rate')
        self.assertEqual(panel['datasource']['uid'], 'prometheus-test-uid')
        self.assertEqual(panel['fieldConfig']['defaults']['unit'], 'reqps')
        expr = panel['targets'][0]['expr']
        self.assertIn('status=~"5.."', expr)
        self.assertIn('deployment_environment="prod"', expr)
        self.assertIn('or vector(0)', expr)

    def test_http_401_panel_uses_route_level_safe_labels_only(self) -> None:
        panel = self.panel_by_title('HTTP 401 rate by URI')
        self.assertEqual(panel['type'], 'timeseries')
        expr = panel['targets'][0]['expr']
        self.assertIn('topk(10,', expr)
        self.assertIn('status="401"', expr)
        self.assertIn('job="shaka-server"', expr)
        self.assertIn('deployment_environment="prod"', expr)
        self.assertIn('sum by (uri, method, status)', expr)
        self.assertNotIn('uri!="UNKNOWN"', expr)
        for unsafe_label in ['user', 'user_id', 'ip', 'client_ip', 'request_id', 'service_instance_id', 'instance']:
            self.assertNotIn(unsafe_label, expr)
        self.assertIn('{{method}} {{uri}}', panel['targets'][0]['legendFormat'])

    def test_host_memory_dashboard_thresholds_show_below_10_percent_pressure(self) -> None:
        panel = self.panel_by_title('Host memory available %')
        self.assertEqual(panel['fieldConfig']['defaults']['unit'], 'percent')
        steps = panel['fieldConfig']['defaults']['thresholds']['steps']
        self.assertEqual(steps[0], {'color': 'red', 'value': None})
        self.assertIn({'color': 'orange', 'value': 10}, steps)
        self.assertIn({'color': 'green', 'value': 20}, steps)

    def test_dashboard_contains_no_secrets_or_webhooks(self) -> None:
        combined = DASHBOARDS_TF.read_text() + "\n" + DASHBOARD.read_text()
        for forbidden in FORBIDDEN:
            self.assertNotIn(forbidden, combined)

    def test_dashboard_runbook_documents_safe_apply_and_explore_checks(self) -> None:
        self.assertTrue(DOC.is_file(), "missing dashboard docs")
        text = DOC.read_text()
        for phrase in [
            "terraform plan",
            "terraform apply",
            "TF_VAR_prometheus_datasource_uid",
            "up{job=\"shaka-server\"}",
            "up{job=\"shaka-host\"}",
            "jvm_memory_used_bytes",
            "node_cpu_seconds_total",
            "No secrets",
            "deployment_environment",
            "editable",
            "5xx panel renders 0 when there are no error series",
            "HTTP 401 rate by URI",
            "route-level only",
            "no user IDs, IP addresses, or request IDs",
            "available memory below 10%",
        ]:
            self.assertIn(phrase, text)

if __name__ == "__main__":
    unittest.main()

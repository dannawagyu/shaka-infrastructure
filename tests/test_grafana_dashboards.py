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
    'jvm_memory_used_bytes{job="shaka-server",deployment_environment="prod"',
    'node_cpu_seconds_total{job="shaka-host",deployment_environment="prod"',
    'node_systemd_unit_state{job="shaka-host",deployment_environment="prod"',
    'http_server_requests_seconds_count{job="shaka-server",deployment_environment="prod"',
    'node_filesystem_avail_bytes{job="shaka-host",deployment_environment="prod"',
]

FORBIDDEN = [
    "discord.com/api/" + "webhooks",
    "glc_",
    "eyJrIj",
    "GRAFANA_CLOUD_API_KEY",
    "GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN",
]

class GrafanaDashboardsTest(unittest.TestCase):
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
        text = DASHBOARD.read_text()
        rendered = text.replace('${prometheus_datasource_uid}', 'prometheus-test-uid').replace('${environment_title}', 'Prod').replace('${environment}', 'prod')
        model = json.loads(rendered)
        self.assertEqual(model['uid'], 'shaka-prod-overview')
        self.assertEqual(model['title'], 'Shaka Prod Overview')
        self.assertGreaterEqual(len(model.get('panels', [])), 10)
        self.assertEqual(model.get('refresh'), '30s')
        self.assertIn('terraform', model.get('tags', []))

    def test_dashboard_queries_match_live_alloy_labels(self) -> None:
        rendered = DASHBOARD.read_text().replace('${prometheus_datasource_uid}', 'prometheus-test-uid').replace('${environment_title}', 'Prod').replace('${environment}', 'prod')
        model = json.loads(rendered)
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
        ]:
            self.assertIn(phrase, text)

if __name__ == "__main__":
    unittest.main()

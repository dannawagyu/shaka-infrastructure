#!/usr/bin/env python3
"""Lightweight checks for rendered Shaka Grafana dashboard JSON."""
from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GRAFANA_DIR = ROOT / "terraform" / "observability" / "grafana"
DASHBOARD = GRAFANA_DIR / "dashboards" / "shaka-prod-overview.json.tftpl"
DASHBOARDS_TF = GRAFANA_DIR / "dashboards.tf"
VARIABLES_TF = GRAFANA_DIR / "variables.tf"

FORBIDDEN_LITERAL_FRAGMENTS = [
    "discord.com/api/webhooks",
    "glc_",
    "eyJrIj",
    "GRAFANA_CLOUD_API_KEY",
    "GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN",
]


class GrafanaDashboardRenderingTest(unittest.TestCase):
    def rendered_dashboard(self) -> dict:
        rendered = (
            DASHBOARD.read_text(encoding="utf-8")
            .replace("${prometheus_datasource_uid}", "prometheus-test-uid")
            .replace("${loki_datasource_uid}", "loki-test-uid")
            .replace("${tempo_datasource_uid}", "tempo-test-uid")
            .replace("${environment_title}", "Prod")
            .replace("${environment}", "prod")
        )
        return json.loads(rendered)

    def panel(self, title: str) -> dict:
        for panel in self.rendered_dashboard().get("panels", []):
            if panel.get("title") == title:
                return panel
        self.fail(f"missing dashboard panel: {title}")

    def test_dashboard_template_renders_valid_json_with_expected_datasources(self) -> None:
        dashboard = self.rendered_dashboard()
        self.assertEqual(dashboard["uid"], "shaka-prod-overview")
        self.assertEqual(dashboard["title"], "Shaka Prod Overview")
        datasource_by_panel = {
            panel["title"]: panel.get("datasource", {})
            for panel in dashboard.get("panels", [])
            if panel.get("title") in {
                "HTTP 5xx rate",
                "Loki log entries, last 5m",
                "Recent application logs",
                "Recent Tempo traces",
            }
        }
        self.assertEqual(datasource_by_panel["HTTP 5xx rate"], {"type": "prometheus", "uid": "prometheus-test-uid"})
        self.assertEqual(datasource_by_panel["Loki log entries, last 5m"], {"type": "loki", "uid": "loki-test-uid"})
        self.assertEqual(datasource_by_panel["Recent application logs"], {"type": "loki", "uid": "loki-test-uid"})
        self.assertEqual(datasource_by_panel["Recent Tempo traces"], {"type": "tempo", "uid": "tempo-test-uid"})

    def test_dashboard_uses_loki_zero_fallback_and_safe_tempo_filter(self) -> None:
        loki_stat = self.panel("Loki log entries, last 5m")
        self.assertIn("or vector(0)", loki_stat["targets"][0]["expr"])
        self.assertEqual(loki_stat["gridPos"]["h"], 8)

        trace_query = self.panel("Recent Tempo traces")["targets"][0]["query"]
        self.assertIn('resource.service.name = "shaka-server"', trace_query)
        self.assertIn('resource.deployment.environment = "prod"', trace_query)

    def test_loki_and_tempo_queries_avoid_sensitive_or_high_cardinality_filters(self) -> None:
        dashboard = self.rendered_dashboard()
        query_text = []
        for panel in dashboard.get("panels", []):
            if panel.get("datasource", {}).get("type") in {"loki", "tempo"}:
                for target in panel.get("targets", []):
                    query_text.append(target.get("expr", ""))
                    query_text.append(target.get("query", ""))
        combined = "\n".join(query_text)
        for unsafe in [
            "user", "user_id", "userId", "ip", "client_ip", "request_id",
            "requestId", "instance", "service_instance_id", "path", "url",
            "Authorization", "authorization", "jwt", "JWT",
        ]:
            self.assertNotIn(unsafe, combined)

    def test_terraform_wires_dashboard_datasource_uids_without_literal_secrets(self) -> None:
        combined = "\n".join(
            path.read_text(encoding="utf-8")
            for path in [DASHBOARDS_TF, VARIABLES_TF, DASHBOARD]
        )
        self.assertIn("prometheus_datasource_uid = var.prometheus_datasource_uid", combined)
        self.assertIn("loki_datasource_uid       = var.loki_datasource_uid", combined)
        self.assertIn("tempo_datasource_uid      = var.tempo_datasource_uid", combined)
        for forbidden in FORBIDDEN_LITERAL_FRAGMENTS:
            self.assertNotIn(forbidden, combined)


if __name__ == "__main__":
    unittest.main()

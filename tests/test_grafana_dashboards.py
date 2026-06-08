#!/usr/bin/env python3
"""Lightweight checks for rendered Shaka Grafana dashboard JSON."""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GRAFANA_DIR = ROOT / "terraform" / "observability" / "grafana"
SHAKA_OVERVIEW_DASHBOARD = GRAFANA_DIR / "dashboards" / "shaka-prod-overview.json.tftpl"
RDS_DASHBOARD = GRAFANA_DIR / "dashboards" / "amazon-rds.json.tftpl"
DASHBOARDS_TF = GRAFANA_DIR / "dashboards.tf"
VARIABLES_TF = GRAFANA_DIR / "variables.tf"

FORBIDDEN_LITERAL_FRAGMENTS = [
    "discord.com/api/webhooks",
    "glc_",
    "eyJrIj",
    "GRAFANA_CLOUD_API_KEY",
    "GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN",
    "aws_access_key_id",
    "aws_secret_access_key",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_ACCESS_KEY_ID",
]


def render_template(path: Path, replacements: dict[str, str]) -> dict:
    rendered = path.read_text(encoding="utf-8")
    for template_var, value in replacements.items():
        rendered = rendered.replace(f"${{{template_var}}}", value)
    return json.loads(rendered)


def iter_panels(panel_or_dashboard: dict):
    for panel in panel_or_dashboard.get("panels", []):
        yield panel
        yield from iter_panels(panel)


class GrafanaDashboardRenderingTest(unittest.TestCase):
    def rendered_dashboard(self) -> dict:
        return render_template(
            SHAKA_OVERVIEW_DASHBOARD,
            {
                "prometheus_datasource_uid": "prometheus-test-uid",
                "loki_datasource_uid": "loki-test-uid",
                "tempo_datasource_uid": "tempo-test-uid",
                "environment_title": "Prod",
                "environment": "prod",
            },
        )

    def rendered_rds_dashboard(self) -> dict:
        return render_template(
            RDS_DASHBOARD,
            {
                "cloudwatch_datasource_uid": "cloudwatch-test-uid",
            },
        )

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
        self.assertIn("count_over_time", loki_stat["targets"][0]["expr"])
        self.assertEqual(loki_stat["options"]["reduceOptions"]["calcs"], ["last"])
        self.assertEqual(loki_stat["options"]["noValue"], "NO LOGS")
        self.assertEqual(loki_stat["gridPos"]["h"], 8)

        trace_panel = self.panel("Recent Tempo traces")
        self.assertEqual(trace_panel["type"], "table")
        trace_query = trace_panel["targets"][0]["query"]
        self.assertIn('resource.service.name = "shaka-server"', trace_query)
        self.assertIn('resource.deployment.environment = "prod"', trace_query)

    def test_401_panel_legend_explains_color_series(self) -> None:
        panel = self.panel("HTTP 401 rate by URI")
        target = panel["targets"][0]

        self.assertIn("http_route", target["expr"])
        self.assertIn("http_request_method", target["expr"])
        self.assertEqual(target["legendFormat"], "{{http_request_method}} {{http_route}} 401")
        self.assertIn("Each color/series is one method + route-template 401 rate", panel["description"])

    def test_overview_prometheus_queries_match_runtime_metric_and_label_names(self) -> None:
        dashboard = self.rendered_dashboard()
        prometheus_exprs = []
        for panel in iter_panels(dashboard):
            if panel.get("datasource", {}).get("type") == "prometheus":
                prometheus_exprs.extend(target.get("expr", "") for target in panel.get("targets", []))
        combined = "\n".join(prometheus_exprs)

        self.assertIn("service_name=\"shaka-server\"", combined)
        self.assertIn("deployment_environment=\"prod\"", combined)
        self.assertIn("http_server_request_duration_seconds_count", combined)
        self.assertIn("http_response_status_code", combined)
        self.assertIn("http_request_method", combined)
        self.assertIn("http_route", combined)
        self.assertIn("jvm_memory_limit_bytes", combined)
        self.assertIn("jvm_memory_type", combined)
        self.assertIn("node_cpu_seconds_total", combined)
        self.assertIn("node_memory_MemAvailable_bytes", combined)
        self.assertIn("node_memory_MemTotal_bytes", combined)
        self.assertIn("node_filesystem_size_bytes", combined)
        self.assertIn("node_filesystem_avail_bytes", combined)
        self.assertIn("node_systemd_unit_state", combined)
        self.assertNotIn("0 * max(node_cpu_seconds_total", combined)

        for unsupported in [
            "up{job=",
            "http_server_requests_seconds_count",
            "status=~\"5..\"",
            "area=\"heap\"",
            "jvm_memory_max_bytes",
            "system_cpu_time_seconds_total",
            "system_memory_usage_bytes",
            "system_filesystem_usage_bytes",
            "system_filesystem_limit_bytes",
        ]:
            self.assertNotIn(unsupported, combined)

    def test_dashboard_panel_ids_are_unique(self) -> None:
        dashboard = self.rendered_dashboard()
        panel_ids = [panel.get("id") for panel in iter_panels(dashboard)]
        duplicated = sorted({panel_id for panel_id in panel_ids if panel_ids.count(panel_id) > 1})
        self.assertEqual(duplicated, [])

    def test_top_row_status_panels_use_current_telemetry_not_systemd_history(self) -> None:
        dashboard = self.rendered_dashboard()
        titles = {panel.get("title") for panel in iter_panels(dashboard)}
        self.assertNotIn("Core systemd active", titles)
        for stale_title in ["Shaka server active", "Nginx active", "Alloy active"]:
            self.assertNotIn(stale_title, titles)

        expected_exprs = {
            "Shaka app telemetry live": "count_over_time(target_info",
            "Backend HTTP traffic live": "count_over_time(http_server_request_duration_seconds_count",
            "Alloy OTLP pipeline live": "count_over_time({__name__=~\"target_info|jvm_memory_used_bytes|http_server_request_duration_seconds_count\"",
        }
        for title, expr_part in expected_exprs.items():
            panel = self.panel(title)
            target = panel["targets"][0]
            self.assertEqual(panel["type"], "stat")
            self.assertTrue(target["instant"], title)
            self.assertFalse(target["range"], title)
            self.assertIn(expr_part, target["expr"])
            self.assertIn("[5m]", target["expr"])
            self.assertIn("or vector(0)", target["expr"])
            self.assertNotIn("node_systemd_unit_state", target["expr"])
            self.assertNotIn("node_cpu_seconds_total", target["expr"])
            self.assertNotIn("0 * max(", target["expr"])
            self.assertEqual(panel["fieldConfig"]["defaults"]["mappings"][0]["options"]["1"]["text"], "LIVE")

    def test_status_stat_panels_use_current_samples_not_stale_last_not_null(self) -> None:
        dashboard = self.rendered_dashboard()
        status_panels = {
            "App scrape status": "DOWN",
            "Host scrape status": "DOWN",
            "Service labels present": "MISSING",
            "Shaka app telemetry live": "DOWN",
            "Backend HTTP traffic live": "NO TRAFFIC",
            "Alloy OTLP pipeline live": "DOWN",
        }

        for panel in iter_panels(dashboard):
            calcs = panel.get("options", {}).get("reduceOptions", {}).get("calcs", [])
            self.assertNotIn("lastNotNull", calcs, panel.get("title"))

        for title, no_value in status_panels.items():
            panel = self.panel(title)
            target = panel["targets"][0]
            self.assertEqual(panel["type"], "stat")
            self.assertTrue(target["instant"], title)
            self.assertFalse(target["range"], title)
            self.assertEqual(panel["options"]["reduceOptions"]["calcs"], ["last"])
            self.assertEqual(panel["options"]["noValue"], no_value)

    def test_cloudwatch_is_only_used_by_rds_dashboard(self) -> None:
        overview = self.rendered_dashboard()
        overview_datasources = {
            panel.get("datasource", {}).get("type")
            for panel in iter_panels(overview)
            if isinstance(panel.get("datasource"), dict)
        }
        self.assertNotIn("cloudwatch", overview_datasources)

        rds = self.rendered_rds_dashboard()
        datasource_variables = {
            item.get("name"): item
            for item in rds.get("templating", {}).get("list", [])
        }
        self.assertEqual(datasource_variables["datasource"]["query"], "cloudwatch")
        cloudwatch_targets = [
            target
            for panel in iter_panels(rds)
            for target in panel.get("targets", [])
            if target.get("namespace") == "AWS/RDS"
        ]
        self.assertGreater(len(cloudwatch_targets), 0)

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

    def test_rds_dashboard_template_renders_valid_json_with_cloudwatch_datasource(self) -> None:
        dashboard = self.rendered_rds_dashboard()
        self.assertEqual(dashboard["uid"], "shaka-amazon-rds")
        self.assertEqual(dashboard["title"], "Shaka Amazon RDS")
        self.assertFalse(dashboard["editable"])
        self.assertIsNone(dashboard["iteration"])

        variables = {item["name"]: item for item in dashboard["templating"]["list"]}
        self.assertEqual(variables["datasource"]["type"], "datasource")
        self.assertEqual(variables["datasource"]["query"], "cloudwatch")
        self.assertEqual(variables["datasource"]["current"]["value"], "cloudwatch-test-uid")
        self.assertEqual(variables["region"]["query"], "regions()")
        self.assertEqual(variables["period"]["query"], "60,300,3600")

        cloudwatch_targets = []
        for panel in iter_panels(dashboard):
            cloudwatch_targets.extend(
                target for target in panel.get("targets", [])
                if target.get("namespace") == "AWS/RDS"
            )
        self.assertGreaterEqual(len(cloudwatch_targets), 3)
        metric_names = {target.get("metricName") for target in cloudwatch_targets}
        for metric_name in {
            "CPUUtilization",
            "DatabaseConnections",
            "FreeableMemory",
            "FreeStorageSpace",
            "ReadLatency",
            "WriteIOPS",
        }:
            self.assertIn(metric_name, metric_names)

    def test_terraform_wires_dashboard_datasource_uids_without_literal_secrets(self) -> None:
        combined = "\n".join(
            path.read_text(encoding="utf-8")
            for path in [DASHBOARDS_TF, VARIABLES_TF, SHAKA_OVERVIEW_DASHBOARD, RDS_DASHBOARD]
        )
        self.assertIn("prometheus_datasource_uid = var.prometheus_datasource_uid", combined)
        self.assertIn("cloudwatch_datasource_uid = var.cloudwatch_datasource_uid", combined)
        self.assertIn("loki_datasource_uid       = var.loki_datasource_uid", combined)
        self.assertIn("tempo_datasource_uid      = var.tempo_datasource_uid", combined)
        for forbidden in FORBIDDEN_LITERAL_FRAGMENTS:
            self.assertNotIn(forbidden, combined)
        self.assertIsNone(re.search(r"\b\d{12}\b", RDS_DASHBOARD.read_text(encoding="utf-8")))

    def test_terraform_registers_rds_dashboard_in_existing_shaka_folder(self) -> None:
        text = DASHBOARDS_TF.read_text(encoding="utf-8")
        self.assertIn('resource "grafana_dashboard" "shaka_amazon_rds"', text)
        resource_block = text.split('resource "grafana_dashboard" "shaka_amazon_rds"', 1)[1]
        self.assertIn("folder = grafana_folder.shaka_observability.uid", resource_block)
        self.assertIn('dashboards/amazon-rds.json.tftpl', resource_block)
        self.assertIn("overwrite = true", resource_block)


if __name__ == "__main__":
    unittest.main()

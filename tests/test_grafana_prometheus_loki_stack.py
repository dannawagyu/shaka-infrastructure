#!/usr/bin/env python3
"""Static checks for issue #3 Grafana Prometheus/Loki stack specification."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
TF = ROOT / "terraform" / "observability" / "grafana"
README = ROOT / "README.md"

class GrafanaPrometheusLokiStackTest(unittest.TestCase):
    def test_loki_inputs_and_free_tier_defaults_exist(self):
        text = (TF / "stack-variables.tf").read_text()
        for name in ["loki_endpoint", "loki_user", "loki_token", "prometheus_remote_write_endpoint", "prometheus_remote_write_user", "prometheus_remote_write_token"]:
            self.assertIn(f'variable "{name}"', text)
        self.assertRegex(text, r'variable\s+"loki_token"[\s\S]*?sensitive\s+=\s+true')
        self.assertRegex(text, r'variable\s+"prometheus_remote_write_token"[\s\S]*?sensitive\s+=\s+true')
        self.assertIn('variable "enable_loki_ingestion"', text)
        self.assertRegex(text, r'variable\s+"enable_loki_ingestion"[\s\S]*?default\s+=\s+false')
        self.assertIn("observability_stack_labels = merge(local.shaka_alert_labels", text)
        self.assertNotIn('service_name           = "shaka-server"', text)
        self.assertNotIn('deployment_environment = var.environment', text)
        self.assertIn('metrics_backend = "grafana-cloud-prometheus"', text)

    def test_runbook_moved_to_canonical_wiki(self):
        text = README.read_text()
        self.assertIn("shaka-wiki", text)
        self.assertIn("engineering/repository-docs/shaka-infrastructure", text)
        self.assertNotIn("discord.com/api/" + "webhooks", text)

if __name__ == "__main__":
    unittest.main()

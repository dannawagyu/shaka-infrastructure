#!/usr/bin/env python3
"""Static checks for issue #3 Grafana Prometheus/Loki stack specification."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
TF = ROOT / "terraform" / "observability" / "grafana"
DOC = ROOT / "docs" / "observability" / "grafana-prometheus-loki-stack.md"

class GrafanaPrometheusLokiStackTest(unittest.TestCase):
    def test_loki_inputs_and_free_tier_defaults_exist(self):
        text = "\n".join(path.read_text() for path in TF.glob("*.tf"))
        for name in ["loki_endpoint", "loki_user", "loki_token", "prometheus_remote_write_endpoint", "prometheus_remote_write_user", "prometheus_remote_write_token"]:
            self.assertIn(f'variable "{name}"', text)
        self.assertRegex(text, r'variable\s+"loki_token"[\s\S]*?sensitive\s+=\s+true')
        self.assertRegex(text, r'variable\s+"prometheus_remote_write_token"[\s\S]*?sensitive\s+=\s+true')
        self.assertIn('variable "enable_loki_ingestion"', text)
        self.assertRegex(text, r'variable\s+"enable_loki_ingestion"[\s\S]*?default\s+=\s+false')

    def test_runbook_documents_ownership_and_privacy(self):
        text = DOC.read_text()
        for phrase in [
            "Prometheus / Metrics",
            "Loki / Logs",
            "Terraform owns",
            "manual",
            "Discord contact point",
            "service.name=shaka-server",
            "deployment.environment=prod",
            "no request bodies",
            "no Authorization/JWT headers",
            "avoid userId",
            "server-side Alloy/Loki pipeline changes",
            "Closes #3",
        ]:
            self.assertIn(phrase, text)
        self.assertNotIn("discord.com/api/" + "webhooks", text)

if __name__ == "__main__":
    unittest.main()

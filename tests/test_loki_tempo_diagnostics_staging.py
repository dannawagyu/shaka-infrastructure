#!/usr/bin/env python3
"""Static checks for staged Loki and Tempo diagnostics guardrails."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
STACK_VARIABLES = ROOT / "terraform" / "observability" / "grafana" / "stack-variables.tf"


class LokiTempoDiagnosticsStagingTest(unittest.TestCase):
    def test_loki_runbook_moved_to_canonical_wiki(self):
        text = README.read_text()
        self.assertIn("shaka-wiki", text)
        self.assertIn("engineering/repository-docs/shaka-infrastructure", text)
        self.assertNotIn("discord.com/api/" + "webhooks", text)

    def test_tempo_runbook_moved_to_canonical_wiki(self):
        text = README.read_text()
        self.assertIn("shaka-wiki", text)
        self.assertIn("engineering/repository-docs/shaka-infrastructure", text)

    def test_tempo_inputs_are_sensitive_and_disabled_by_default(self):
        text = STACK_VARIABLES.read_text()
        for name in [
            "tempo_endpoint",
            "tempo_user",
            "tempo_token",
            "enable_tempo_tracing",
            "tempo_sampling_rate",
        ]:
            self.assertIn(f'variable "{name}"', text)
        for name in ["tempo_endpoint", "tempo_user", "tempo_token"]:
            self.assertRegex(text, rf'variable\s+"{name}"(?:(?!variable)[\s\S])*?sensitive\s+=\s+true')
        self.assertRegex(text, r'variable\s+"enable_loki_ingestion"(?:(?!variable)[\s\S])*?default\s+=\s+false')
        self.assertRegex(text, r'variable\s+"enable_tempo_tracing"(?:(?!variable)[\s\S])*?default\s+=\s+false')
        self.assertRegex(text, r'variable\s+"tempo_sampling_rate"(?:(?!variable)[\s\S])*?default\s+=\s+0\.01')
        self.assertRegex(text, r'variable\s+"tempo_sampling_rate"(?:(?!variable)[\s\S])*?condition\s+=\s+var\.tempo_sampling_rate\s+>=\s+0(?:(?!variable)[\s\S])*?var\.tempo_sampling_rate\s+<=\s+0\.05')
        self.assertRegex(text, r'traces_backend\s+=\s+var\.enable_tempo_tracing \? "grafana-cloud-tempo" : "staged"')


if __name__ == "__main__":
    unittest.main()

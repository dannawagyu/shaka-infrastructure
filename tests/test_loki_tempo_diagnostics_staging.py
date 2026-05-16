#!/usr/bin/env python3
"""Static checks for staged Loki and Tempo diagnostics guardrails."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs" / "observability" / "loki-tempo-diagnostics-staging.md"
STACK_VARIABLES = ROOT / "terraform" / "observability" / "grafana" / "stack-variables.tf"


class LokiTempoDiagnosticsStagingTest(unittest.TestCase):
    def test_runbook_stages_loki_without_enabling_ingestion(self):
        text = DOC.read_text()
        for phrase in [
            "Closes #24",
            "RFC-0017 remains draft",
            "enable_loki_ingestion = false",
            "application JSON file logs",
            "No request bodies",
            "Authorization/JWT/refresh/Apple tokens",
            "database credentials",
            "Grafana tokens",
            "Discord webhooks",
            "user-generated note/comment content",
            "service_name",
            "deployment_environment",
            "service_instance_id",
            "log_source",
            "Disable the Loki pipeline without changing Prometheus remote_write",
        ]:
            self.assertIn(phrase, text)
        self.assertNotIn("discord.com/api/" + "webhooks", text)

    def test_runbook_evaluates_tempo_without_enabling_tracing(self):
        text = DOC.read_text()
        for phrase in [
            "Closes #25",
            "RFC-0018 remains draft",
            "enable_tempo_tracing = false",
            "OpenTelemetry Java agent + Alloy OTLP + Tempo",
            "Sentry-only tracing",
            "1%",
            "5%",
            "CPU",
            "memory",
            "heap",
            "startup",
            "request latency",
            "Disable the Java agent and OTLP export",
            "/actuator/health",
            "/actuator/prometheus",
        ]:
            self.assertIn(phrase, text)

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
            self.assertRegex(text, rf'variable\s+"{name}"[\s\S]*?sensitive\s+=\s+true')
        self.assertRegex(text, r'variable\s+"enable_loki_ingestion"[\s\S]*?default\s+=\s+false')
        self.assertRegex(text, r'variable\s+"enable_tempo_tracing"[\s\S]*?default\s+=\s+false')
        self.assertRegex(text, r'variable\s+"tempo_sampling_rate"[\s\S]*?default\s+=\s+0\.01')
        self.assertRegex(text, r'variable\s+"tempo_sampling_rate"[\s\S]*?condition\s+=\s+var\.tempo_sampling_rate\s+>=\s+0[\s\S]*?var\.tempo_sampling_rate\s+<=\s+0\.05')
        self.assertRegex(text, r'traces_backend\s+=\s+var\.enable_tempo_tracing \? "grafana-cloud-tempo" : "staged"')


if __name__ == "__main__":
    unittest.main()

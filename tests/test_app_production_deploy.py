#!/usr/bin/env python3
"""Static contract checks for infra-owned Shaka production app deploy."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "app-production-deploy.yml"
SCRIPT = ROOT / "scripts" / "deploy-shaka-production.sh"
ALLOY = ROOT / "deploy" / "grafana" / "alloy-otlp-config.alloy"
SYSTEMD = ROOT / "deploy" / "systemd" / "shaka-server.service"

class AppProductionDeployTest(unittest.TestCase):
    def test_workflow_is_infra_owned_and_uses_single_production_environment(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("if: github.ref_name == 'main'", text)
        self.assertIn("environment: production", text)
        self.assertIn("deploy_confirmation=deploy-shaka-production", text)
        self.assertIn("build-server-artifact:", text)
        self.assertIn("Deploy Shaka app from verified artifact", text)
        self.assertIn("repository: dannawagyu/shaka-server-spring", text)
        self.assertIn("working-directory: server", text)
        self.assertIn("./gradlew test --no-daemon", text)
        self.assertIn("./gradlew clean bootJar --no-daemon", text)
        self.assertIn("infra/scripts/deploy-shaka-production.sh", text)
        self.assertIn("GRAFANA_CLOUD_OTLP_ENDPOINT: ${{ secrets.GRAFANA_CLOUD_OTLP_ENDPOINT }}", text)
        self.assertIn("GRAFANA_CLOUD_OTLP_USERNAME: ${{ secrets.GRAFANA_CLOUD_OTLP_USERNAME }}", text)
        self.assertIn("GRAFANA_CLOUD_OTLP_PASSWORD: ${{ secrets.GRAFANA_CLOUD_OTLP_PASSWORD }}", text)
        self.assertIn("SHAKA_PROD_SSH_KNOWN_HOSTS", text)
        self.assertIn("OTEL_JAVA_AGENT_SHA256", text)
        self.assertIn("actions/upload-artifact@v4", text)
        self.assertIn("actions/download-artifact@v4", text)
        self.assertIn("SHAKA_PROD_URL", text)
        self.assertIn("GRAFANA_PROMETHEUS_REMOTE_WRITE_URL", text)
        self.assertIn("GRAFANA_PROMETHEUS_REMOTE_WRITE_USER", text)
        self.assertIn("GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN", text)
        self.assertNotIn("GRAFANA_CLOUD_LOKI_API_KEY", text)
        self.assertNotIn("TEMPO_OTLP_PASSWORD", text)

    def test_deploy_script_preflights_agent_and_combined_alloy_credentials(self):
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("Preflighting production host and OpenTelemetry Java agent before app mutation", text)
        self.assertIn("opentelemetry-javaagent-${OTEL_JAVA_AGENT_VERSION}.jar", text)
        self.assertIn("StrictHostKeyChecking=yes", text)
        self.assertIn("UserKnownHostsFile", text)
        self.assertIn("OTEL_JAVA_AGENT_SHA256", text)
        self.assertIn("sha256sum -c -", text)
        self.assertIn("GRAFANA_CLOUD_OTLP_ENDPOINT", text)
        self.assertIn("GRAFANA_CLOUD_OTLP_USERNAME", text)
        self.assertIn("GRAFANA_CLOUD_OTLP_PASSWORD", text)
        self.assertIn("OTEL_METRICS_EXPORTER': 'otlp'", text)
        self.assertIn("OTEL_LOGS_EXPORTER': 'otlp'", text)
        self.assertIn("OTEL_TRACES_EXPORTER': 'otlp'", text)
        self.assertIn("sudo systemctl restart alloy", text)
        self.assertIn("rollback_remote", text)
        self.assertIn("rollback_from_backup", text)
        self.assertIn("/etc/nginx/conf.d/shaka-server.conf:shaka-server.conf", text)
        self.assertIn("/etc/alloy/config.alloy:config.alloy", text)
        self.assertIn("/etc/shaka/env:env", text)
        self.assertIn('"$(basename "$OBS_ENV_FILE")"', text)
        self.assertIn('OBS_ENV_BASE="$3"', text)
        self.assertIn("agent_option not in existing_java_tool_options", text)
        self.assertIn("ExecStartPre=", text)
        self.assertIn("missing required Alloy OTLP/remote_write env keys", text)
        self.assertIn("placeholder value is not allowed", text)
        self.assertIn("staged Alloy OTLP env file must not be group/world readable", text)
        self.assertIn("must be a Grafana Cloud HTTPS endpoint", text)
        self.assertIn("GRAFANA_CLOUD_OTLP_ENDPOINT", text)
        self.assertIn("sudo install -o root -g root -m 0600", text)
        self.assertIn("external health check failed", text)
        self.assertIn("must be a Grafana Cloud Prometheus remote_write endpoint", text)
        self.assertIn("GRAFANA_PROMETHEUS_REMOTE_WRITE_URL", text)
        self.assertIn("from urllib.parse import urlparse", text)
        self.assertIn("parsed.hostname", text)
        self.assertIn("parsed.path", text)
        self.assertNotIn('".grafana.net/api/prom/push" in remote_write_url', text)
        self.assertNotIn("https://*.grafana.net/api/prom/push", text)
        self.assertNotIn("GRAFANA_CLOUD_LOKI_API_KEY", text)
        self.assertNotIn("TEMPO_OTLP_PASSWORD", text)
        self.assertNotIn("journalctl -u alloy", text)

    def test_remote_write_url_validation_rejects_path_based_host_confusion(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        script = SCRIPT.read_text(encoding="utf-8")
        for text in (workflow, script):
            self.assertIn("urlparse", text)
            self.assertRegex(text, r"parsed[.]hostname")
            self.assertRegex(text, r"parsed[.]path\s*!=\s*expected_path")
            self.assertIn("parsed.username or parsed.password", text)
            self.assertNotIn('".grafana.net/api/prom/push" in', text)
            self.assertNotIn("https://*.grafana.net/api/prom/push", text)

    def test_alloy_config_is_otlp_first_for_all_three_signals(self):
        text = ALLOY.read_text(encoding="utf-8")
        self.assertIn('otelcol.receiver.otlp "shaka"', text)
        self.assertIn('endpoint = "127.0.0.1:4317"', text)
        self.assertIn('endpoint = "127.0.0.1:4318"', text)
        self.assertIn('metrics = [otelcol.processor.transform.shaka.input]', text)
        self.assertIn('logs    = [otelcol.processor.transform.shaka.input]', text)
        self.assertIn('traces  = [otelcol.processor.transform.shaka.input]', text)
        self.assertIn('otelcol.exporter.otlphttp "grafana_cloud"', text)
        self.assertIn('endpoint = sys.env("GRAFANA_CLOUD_OTLP_ENDPOINT")', text)
        self.assertIn('username = sys.env("GRAFANA_CLOUD_OTLP_USERNAME")', text)
        self.assertIn('password = sys.env("GRAFANA_CLOUD_OTLP_PASSWORD")', text)
        self.assertIn('prometheus.exporter.unix "shaka_host"', text)
        self.assertIn('prometheus.remote_write "grafana_cloud"', text)
        self.assertIn('url = sys.env("GRAFANA_PROMETHEUS_REMOTE_WRITE_URL")', text)
        self.assertIn('password = sys.env("GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN")', text)
        self.assertNotIn("loki.write", text)
        self.assertNotIn("processes {}", text)

    def test_runtime_config_lives_in_infra(self):
        self.assertTrue((ROOT / "deploy" / "nginx" / "shaka-server.conf").is_file())
        self.assertTrue(SYSTEMD.is_file())
        self.assertTrue((ROOT / "deploy" / "env" / "shaka-env.example").is_file())
        systemd_text = SYSTEMD.read_text(encoding="utf-8")
        self.assertIn("/opt/shaka/current.jar", systemd_text)
        self.assertIn("User=ubuntu", systemd_text)

    def test_nginx_no_longer_terminates_tls(self):
        nginx_text = (ROOT / "deploy" / "nginx" / "shaka-server.conf").read_text(encoding="utf-8")
        self.assertNotIn("ssl_certificate", nginx_text)
        self.assertNotIn("listen 443", nginx_text)
        self.assertNotIn("letsencrypt", nginx_text.lower())
        self.assertIn("listen 80;", nginx_text)
        self.assertIn("set_real_ip_from 172.31.0.0/16;", nginx_text)

    def test_nginx_keeps_actuator_lockdown(self):
        nginx_text = (ROOT / "deploy" / "nginx" / "shaka-server.conf").read_text(encoding="utf-8")
        self.assertIn("location = /actuator/prometheus { deny all; return 403; }", nginx_text)
        self.assertIn("location /actuator/ { deny all; return 403; }", nginx_text)

if __name__ == "__main__":
    unittest.main()

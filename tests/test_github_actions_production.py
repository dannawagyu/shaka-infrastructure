#!/usr/bin/env python3
"""Static checks for the production Terraform GitHub Actions workflow."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "terraform-production.yml"
USER_DATA = ROOT / "terraform" / "environments" / "prod" / "templates" / "app-user-data.sh.tftpl"


class GitHubActionsProductionTest(unittest.TestCase):
    def test_workflow_uses_production_environment_and_secrets(self):
        text = WORKFLOW.read_text()
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("environment: production", text)
        self.assertIn("TF_VAR_db_username: ${{ secrets.SHAKA_DB_USERNAME }}", text)
        self.assertIn("TF_VAR_db_password: ${{ secrets.SHAKA_DB_PASSWORD }}", text)
        self.assertIn("SHAKA_PRIVATE_SUBNET_IDS_JSON", text)
        self.assertIn("terraform plan -out=production.tfplan", text)
        self.assertIn("terraform apply -auto-approve production.tfplan", text)
        self.assertIn("apply-production", text)
        self.assertNotIn("\nenvironment: production\n", text.split("jobs:", 1)[0])

    def test_grafana_runtime_credentials_are_not_rendered_into_terraform_user_data(self):
        text = USER_DATA.read_text()
        self.assertIn('EnvironmentFile=-/etc/alloy/grafana-cloud.env', text)
        self.assertIn('sys.env("GRAFANA_PROMETHEUS_REMOTE_WRITE_URL")', text)
        self.assertIn('sys.env("GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN")', text)
        self.assertNotIn('${grafana_prometheus_remote_write_token}', text)
        self.assertNotIn('${grafana_prometheus_remote_write_url}', text)


if __name__ == "__main__":
    unittest.main()

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
        self.assertIn("SHAKA_AVAILABILITY_ZONES_JSON", text)
        self.assertIn("SHAKA_PRIVATE_SUBNET_CIDRS_JSON", text)
        self.assertIn("TF_VAR_existing_app_instance_id: ${{ vars.SHAKA_EXISTING_APP_INSTANCE_ID }}", text)
        self.assertIn("TF_VAR_existing_app_security_group_id: ${{ vars.SHAKA_EXISTING_APP_SECURITY_GROUP_ID }}", text)
        self.assertNotIn("SHAKA_APP_AMI_ID", text)
        self.assertNotIn("TF_VAR_app_ami_id", text)
        self.assertIn("terraform -chdir=terraform/environments/prod plan -out=production.tfplan", text)
        self.assertIn("apply", text)
        self.assertIn("apply_confirmation=apply-production", text)
        self.assertIn("terraform -chdir=terraform/environments/prod apply -input=false production.tfplan", text)
        self.assertIn("terraform -chdir=terraform/environments/prod output", text)
        self.assertIn("cleanup-accidental-stack-plan", text)
        self.assertIn("cleanup-accidental-stack-apply", text)
        self.assertIn("accidental_vpc_id:", text)
        self.assertIn("SHAKA_ACCIDENTAL_VPC_ID: ${{ inputs.accidental_vpc_id }}", text)
        self.assertIn("apply_confirmation=cleanup-accidental-stack", text)
        self.assertIn("./scripts/cleanup-accidental-prod-stack.sh plan", text)
        self.assertIn("./scripts/cleanup-accidental-prod-stack.sh apply", text)
        self.assertIn("bootstrap-backend-plan", text)
        self.assertIn("bootstrap-backend-apply", text)
        self.assertIn("apply_confirmation=bootstrap-production-backend", text)
        self.assertIn("terraform -chdir=terraform/bootstrap/backend apply -input=false backend.tfplan", text)
        self.assertIn("aws s3api get-bucket-versioning", text)
        self.assertIn("aws dynamodb describe-table", text)
        self.assertNotIn("terraform apply -auto-approve production.tfplan", text)
        self.assertNotIn("\nenvironment: production\n", text.split("jobs:", 1)[0])

    def test_grafana_runtime_credentials_are_not_rendered_into_terraform_user_data(self):
        text = USER_DATA.read_text()
        self.assertIn('EnvironmentFile=-/etc/alloy/grafana-cloud.env', text)
        self.assertIn('sys.env("GRAFANA_PROMETHEUS_REMOTE_WRITE_URL")', text)
        self.assertIn('sys.env("GRAFANA_PROMETHEUS_REMOTE_WRITE_TOKEN")', text)
        self.assertNotIn('${grafana_prometheus_remote_write_token}', text)
        self.assertNotIn('${grafana_prometheus_remote_write_url}', text)

    def test_user_data_installs_and_starts_alloy_safely(self):
        text = USER_DATA.read_text()
        self.assertIn("apt.grafana.com", text)
        self.assertIn("apt-get install -y alloy", text)
        self.assertIn("http://169.254.169.254/latest/api/token", text)
        self.assertIn("http://169.254.169.254/latest/meta-data/instance-id", text)
        self.assertIn("Environment=EC2_INSTANCE_ID=$${INSTANCE_ID}", text)
        self.assertIn("systemctl enable --now nginx", text)
        self.assertIn("systemctl enable --now alloy", text)
        self.assertIn("systemctl enable shaka-server", text)
        self.assertNotIn("systemctl enable --now shaka-server", text)


if __name__ == "__main__":
    unittest.main()

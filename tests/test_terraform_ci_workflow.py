#!/usr/bin/env python3
"""Static checks for the Terraform CI pull request workflow."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "terraform-ci.yml"
VALIDATE_SCRIPT = ROOT / "scripts" / "validate-terraform-ci.sh"


class TerraformCIWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.workflow = WORKFLOW.read_text(encoding="utf-8")
        self.script = VALIDATE_SCRIPT.read_text(encoding="utf-8")

    def test_pr_validation_runs_on_main_with_least_privilege(self):
        self.assertIn("name: Terraform CI", self.workflow)
        self.assertIn("pull_request:", self.workflow)
        self.assertRegex(self.workflow, r"pull_request:\n\s+branches:\n\s+- main")
        self.assertIn("push:", self.workflow)
        self.assertIn("permissions:\n  contents: read", self.workflow)
        self.assertNotIn("id-token: write", self.workflow)
        self.assertNotIn("write-all", self.workflow)
        self.assertNotIn("pull_request_target:", self.workflow)

    def test_pr_validation_does_not_expose_production_secrets(self):
        forbidden = [
            "secrets.",
            "AWS_ROLE_TO_ASSUME",
            "AWS_ACCESS_KEY_ID",
            "AWS_SECRET_ACCESS_KEY",
            "SHAKA_DB_PASSWORD",
            "terraform plan",
            "terraform apply",
            "environment: production",
        ]
        for token in forbidden:
            self.assertNotIn(token, self.workflow)

    def test_workflow_pins_actions_to_full_commit_sha(self):
        uses_lines = re.findall(r"uses:\s*([^\s#]+)", self.workflow)
        self.assertGreaterEqual(len(uses_lines), 2)
        for action_ref in uses_lines:
            self.assertRegex(action_ref, r"@[0-9a-f]{40}$", f"unpinned action: {action_ref}")

    def test_validation_script_runs_static_tests_and_all_terraform_roots(self):
        self.assertIn("python3 -m unittest discover -s", self.script)
        self.assertIn("terraform -chdir=\"$ROOT\" fmt -check -recursive", self.script)
        self.assertIn("terraform/environments/prod", self.script)
        self.assertIn("terraform/observability/grafana", self.script)
        self.assertIn("init -backend=false -input=false", self.script)
        self.assertIn("terraform -chdir=\"$ROOT/$root\" validate", self.script)
        self.assertIn("AWS_EC2_METADATA_DISABLED", self.script)


if __name__ == "__main__":
    unittest.main()

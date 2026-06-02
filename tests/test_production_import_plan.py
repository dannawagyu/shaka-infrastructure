#!/usr/bin/env python3
"""Static checks for issue #4 production import/inventory plan."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
README = ROOT / "README.md"
TF = ROOT / "terraform" / "environments" / "prod" / "existing-resources.tf"

class ProductionImportPlanTest(unittest.TestCase):
    def test_production_import_plan_moved_to_canonical_wiki(self):
        text = README.read_text()
        self.assertIn("shaka-wiki", text)
        self.assertIn("engineering/repository-docs/shaka-infrastructure", text)

    def test_terraform_data_scaffold_uses_existing_ids_and_no_rebuild(self):
        text = TF.read_text()
        for name in ["existing_app_instance_id", "existing_app_security_group_id"]:
            self.assertIn(f'variable "{name}"', text)
        self.assertIn('data "aws_instance" "existing_app"', text)
        self.assertIn("instance_id = var.existing_app_instance_id", text)
        self.assertIn('data "aws_subnet" "existing_public"', text)
        self.assertIn("id = data.aws_instance.existing_app.subnet_id", text)
        self.assertNotIn('resource "aws_instance"', text)
        self.assertNotIn('resource "aws_eip"', text)
        self.assertNotIn('resource "aws_vpc"', text)

if __name__ == "__main__":
    unittest.main()

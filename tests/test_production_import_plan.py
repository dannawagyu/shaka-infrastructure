#!/usr/bin/env python3
"""Static checks for issue #4 production import/inventory plan."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOC = ROOT / "docs" / "aws" / "production-import-plan.md"
TF = ROOT / "terraform" / "environments" / "prod" / "existing-resources.tf"

class ProductionImportPlanTest(unittest.TestCase):
    def test_inventory_covers_required_resource_classes(self):
        text = DOC.read_text()
        for phrase in [
            "discover -> import/reference -> plan no-op",
            "EC2 app host",
            "VPC",
            "subnet",
            "route table",
            "internet gateway",
            "app security group",
            "Elastic IP",
            "SSH/HTTP/HTTPS ingress",
            "Route53",
            "Let's Encrypt/Certbot",
            "IAM instance profile",
            "EBS root volume",
            "backup",
            "resource` blocks first",
            "no unexpected replacement",
            "No AWS credentials",
            "Closes #4",
        ]:
            self.assertIn(phrase, text)

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

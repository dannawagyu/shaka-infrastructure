#!/usr/bin/env python3
"""Static guardrail checks for Shaka production Terraform baseline."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROD = ROOT / "terraform" / "environments" / "prod"


def read(path: Path) -> str:
    if not path.exists():
        raise AssertionError(f"Missing required file: {path.relative_to(ROOT)}")
    return path.read_text(encoding="utf-8")


def all_tf() -> str:
    if not PROD.exists():
        raise AssertionError("Missing Terraform production environment path: terraform/environments/prod/")
    files = sorted(PROD.glob("*.tf"))
    if not files:
        raise AssertionError("No .tf files found under terraform/environments/prod/")
    return "\n".join(read(path) for path in files)


def assert_contains(text: str, pattern: str, message: str) -> None:
    if not re.search(pattern, text, flags=re.IGNORECASE | re.MULTILINE | re.DOTALL):
        raise AssertionError(message)


def assert_not_contains(text: str, pattern: str, message: str) -> None:
    if re.search(pattern, text, flags=re.IGNORECASE | re.MULTILINE | re.DOTALL):
        raise AssertionError(message)


def main() -> int:
    tf = all_tf()

    assert_contains(tf, r'resource\s+"aws_instance"\s+"app"', "Terraform-managed EC2 app instance resource is required")
    assert_contains(tf, r'instance_type\s*=\s*var\.app_instance_type', "EC2 instance type must come from the guarded app_instance_type variable")
    assert_contains(tf, r'associate_public_ip_address\s*=\s*true', "EC2 app host must be publicly reachable through 80/443 while app/DB ports stay private")
    assert_contains(tf, r'http_tokens\s*=\s*"required"', "EC2 metadata options must require IMDSv2 tokens")
    assert_contains(tf, r'resource\s+"aws_db_instance"', "RDS DB instance resource is required")
    assert_contains(tf, r'instance_class\s*=\s*var\.db_instance_class', "RDS instance class must come from the guarded db_instance_class variable")
    assert_contains(tf, r'variable\s+"db_instance_class".*default\s*=\s*"db\.t4g\.micro"', "RDS must default to low-cost db.t4g.micro")
    assert_contains(tf, r'contains\(\["db\.t4g\.micro",\s*"db\.t3\.micro"\]', "RDS must document/allow only db.t3.micro as fallback")
    assert_contains(tf, r'^\s*allocated_storage\s*=\s*20\b', "RDS allocated storage must default to 20 GiB")
    assert_contains(tf, r'^\s*max_allocated_storage\s*=\s*100\b', "RDS storage autoscaling must allow growth to 100 GiB")
    assert_contains(tf, r'^\s*engine_version\s*=\s*"8\.0\.35"', "RDS MySQL engine minor version must be pinned")
    assert_contains(tf, r'multi_az\s*=\s*false', "RDS must be Single-AZ (multi_az = false)")
    assert_contains(tf, r'publicly_accessible\s*=\s*false', "RDS must not be publicly accessible")
    assert_contains(tf, r'deletion_protection\s*=\s*true', "Production RDS deletion_protection must be enabled")
    assert_contains(tf, r'prevent_destroy\s*=\s*true', "Production RDS must use prevent_destroy lifecycle guard")

    assert_contains(tf, r'resource\s+"aws_security_group"\s+"app"', "Terraform-managed app security group is required")
    assert_contains(tf, r'resource\s+"aws_security_group_rule"\s+"rds_ingress_from_app_ec2".*source_security_group_id\s*=\s*aws_security_group\.app\.id', "RDS ingress must reference the Terraform-managed app EC2 security group")
    assert_not_contains(tf, r'resource\s+"aws_security_group_rule"\s+"[^"]*rds[^"]*".*cidr_blocks\s*=\s*\[\s*"0\.0\.0\.0/0"\s*\]', "RDS security group must not allow broad ingress to 0.0.0.0/0")
    assert_not_contains(tf, r'resource\s+"aws_(nat_gateway|db_proxy)"', "NAT Gateway and RDS Proxy are out of scope")
    assert_not_contains(tf, r'replicate_source_db|backup_replication|region\s*=\s*"[^"]+"\s*#\s*cross', "Cross-region backup/replication is out of scope")

    outputs = read(PROD / "outputs.tf")
    assert_contains(outputs, r'output\s+"app_instance_id"', "Output app_instance_id is required")
    assert_contains(outputs, r'output\s+"app_public_ip"', "Output app_public_ip is required")
    assert_contains(outputs, r'output\s+"app_security_group_id"', "Output app_security_group_id is required")
    assert_contains(outputs, r'output\s+"rds_endpoint"', "Output rds_endpoint is required")
    assert_contains(outputs, r'output\s+"rds_port"', "Output rds_port is required")
    assert_contains(outputs, r'output\s+"database_name"', "Output database_name is required")
    assert_not_contains(outputs, r'(password|secret|username)', "Outputs must not expose credentials or secrets")

    gitignore = read(ROOT / ".gitignore")
    for pattern in [r'(^|/)\.terraform/', r'terraform\.tfstate\*', r'\*\.tfvars', r'\*\.tfplan', r'\*\.plan']:
        assert_contains(gitignore, pattern, f".gitignore missing required pattern matching {pattern}")

    readme = read(ROOT / "README.md")
    assert_contains(readme, r'Terraform state.*sensitive|sensitive.*Terraform state', "README must warn Terraform state can contain sensitive values")
    assert_contains(readme, r'secrets?', "README must document secrets handling")
    assert_contains(readme, r'EC2.*RDS|RDS.*EC2', "README must document the combined EC2 + RDS production apply path")
    assert_contains(readme, r'import', "README must document existing EC2/VPC import or reference path")
    assert_contains(readme, r'destroy|prevent_destroy|deletion_protection', "README must document guarded destroy/deletion behavior")

    print("Terraform static guardrail checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)

#!/usr/bin/env python3
"""Static guardrail checks for Shaka production Terraform baseline."""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROD = ROOT / "terraform" / "environments" / "prod"
BACKEND = ROOT / "terraform" / "bootstrap" / "backend"


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


def backend_tf() -> str:
    if not BACKEND.exists():
        raise AssertionError("Missing Terraform backend bootstrap path: terraform/bootstrap/backend/")
    files = sorted(BACKEND.glob("*.tf"))
    if not files:
        raise AssertionError("No .tf files found under terraform/bootstrap/backend/")
    return "\n".join(read(path) for path in files)


def assert_contains(text: str, pattern: str, message: str) -> None:
    if not re.search(pattern, text, flags=re.IGNORECASE | re.MULTILINE | re.DOTALL):
        raise AssertionError(message)


def assert_not_contains(text: str, pattern: str, message: str) -> None:
    if re.search(pattern, text, flags=re.IGNORECASE | re.MULTILINE | re.DOTALL):
        raise AssertionError(message)


def regex_group(text: str, pattern: str, message: str) -> str:
    match = re.search(pattern, text, flags=re.IGNORECASE | re.MULTILINE | re.DOTALL)
    if not match:
        raise AssertionError(message)
    return match.group(1)


def hcl_block(text: str, start_pattern: str, message: str) -> str:
    match = re.search(start_pattern, text, flags=re.IGNORECASE | re.MULTILINE)
    if not match:
        raise AssertionError(message)
    start = match.start()
    brace = text.find("{", match.end())
    if brace == -1:
        raise AssertionError(message)
    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    raise AssertionError(message)


def main() -> int:
    tf = all_tf()
    backend = backend_tf()

    backend_bucket = regex_group(tf, r'backend\s+"s3"\s+\{[^}]*bucket\s*=\s*"([^"]+)"', "Production Terraform must use an S3 remote backend bucket")
    backend_lock_table = regex_group(tf, r'backend\s+"s3"\s+\{[^}]*dynamodb_table\s*=\s*"([^"]+)"', "Production Terraform backend must use DynamoDB locking")
    default_bucket = regex_group(backend, r'variable\s+"state_bucket_name"\s+\{.*?default\s*=\s*"([^"]+)"', "Backend bootstrap must define a default state bucket name")
    default_lock_table = regex_group(backend, r'variable\s+"lock_table_name"\s+\{.*?default\s*=\s*"([^"]+)"', "Backend bootstrap must define a default lock table name")
    if backend_bucket != default_bucket:
        raise AssertionError("Production backend bucket must match terraform/bootstrap/backend state_bucket_name default")
    if backend_lock_table != default_lock_table:
        raise AssertionError("Production backend lock table must match terraform/bootstrap/backend lock_table_name default")
    if not re.search(r'shaka.*terraform.*state|terraform.*state.*shaka', backend_bucket, flags=re.IGNORECASE):
        raise AssertionError("Production backend bucket name must be Shaka-specific and Terraform-state-specific")

    assert_contains(tf, r'backend\s+"s3"\s+\{[^}]*key\s*=\s*"prod/terraform\.tfstate"', "Production Terraform backend key must be prod/terraform.tfstate")
    assert_contains(tf, r'backend\s+"s3"\s+\{[^}]*region\s*=\s*"ap-northeast-2"', "Production Terraform backend must use ap-northeast-2")
    assert_contains(tf, rf'backend\s+"s3"\s+\{{[^}}]*dynamodb_table\s*=\s*"{re.escape(default_lock_table)}"', "Production Terraform backend must use the bootstrap DynamoDB lock table")
    assert_contains(tf, r'backend\s+"s3"\s+\{[^}]*encrypt\s*=\s*true', "Production Terraform backend encryption must be enabled")

    assert_contains(backend, r'resource\s+"aws_s3_bucket"\s+"terraform_state"', "Backend bootstrap must create the Terraform state S3 bucket")
    assert_contains(backend, r'resource\s+"aws_s3_bucket_versioning"\s+"terraform_state".*status\s*=\s*"Enabled"', "Backend S3 bucket versioning must be enabled")
    assert_contains(backend, r'resource\s+"aws_s3_bucket_server_side_encryption_configuration"\s+"terraform_state".*sse_algorithm\s*=\s*"AES256"', "Backend S3 bucket encryption must use AES256 unless KMS is explicitly reviewed")
    assert_contains(backend, r'resource\s+"aws_s3_bucket_public_access_block"\s+"terraform_state".*block_public_acls\s*=\s*true.*block_public_policy\s*=\s*true.*ignore_public_acls\s*=\s*true.*restrict_public_buckets\s*=\s*true', "Backend S3 bucket must block all public access paths")
    assert_contains(backend, r'resource\s+"aws_s3_bucket_ownership_controls"\s+"terraform_state".*object_ownership\s*=\s*"BucketOwnerEnforced"', "Backend S3 bucket must enforce bucket-owner object ownership")
    state_lifecycle = hcl_block(backend, r'resource\s+"aws_s3_bucket_lifecycle_configuration"\s+"terraform_state"', "Backend S3 bucket must define lifecycle cost controls")
    assert_contains(state_lifecycle, r'abort_incomplete_multipart_upload\s+\{[^}]*days_after_initiation\s*=\s*7', "Backend S3 lifecycle must abort incomplete multipart uploads after 7 days")
    assert_not_contains(state_lifecycle, r'noncurrent_version_transition|storage_class\s*=\s*"STANDARD_IA"', "Backend S3 lifecycle must not transition small Terraform state files to Standard-IA")
    assert_not_contains(state_lifecycle, r'noncurrent_version_expiration|\n\s*expiration\s+\{', "Backend S3 lifecycle must not expire Terraform state history")
    assert_contains(backend, r'resource\s+"aws_s3_bucket"\s+"terraform_state_logs"', "Backend bootstrap must create a separate S3 access log bucket")
    assert_contains(backend, r'resource\s+"aws_s3_bucket_logging"\s+"terraform_state".*target_bucket\s*=\s*aws_s3_bucket\.terraform_state_logs\.id.*target_prefix\s*=\s*"s3-access-logs/terraform-state/"', "Backend S3 bucket must enable server access logging to the log bucket")
    assert_contains(backend, r'resource\s+"aws_s3_bucket_server_side_encryption_configuration"\s+"terraform_state_logs".*sse_algorithm\s*=\s*"AES256"', "Backend S3 access log bucket encryption must use AES256")
    assert_contains(backend, r'resource\s+"aws_s3_bucket_public_access_block"\s+"terraform_state_logs".*block_public_acls\s*=\s*true.*block_public_policy\s*=\s*true.*ignore_public_acls\s*=\s*true.*restrict_public_buckets\s*=\s*true', "Backend S3 access log bucket must block all public access paths")
    assert_contains(backend, r'AllowS3ServerAccessLogs', "Backend S3 access log bucket policy must allow S3 logging service writes")
    assert_contains(backend, r'resource\s+"aws_s3_bucket_lifecycle_configuration"\s+"terraform_state_logs".*expiration\s+\{[^}]*days\s*=\s*365', "Backend S3 access log bucket must expire current logs after 365 days")
    assert_contains(backend, r'resource\s+"aws_s3_bucket_policy"\s+"terraform_state"', "Backend S3 bucket must have an access-control bucket policy")
    assert_contains(backend, r'depends_on\s*=\s*\[\s*aws_s3_bucket_public_access_block\.terraform_state\s*\]', "Backend S3 bucket policy must wait for public access block settings")
    assert_contains(backend, r'DenyInsecureTransport', "Backend S3 bucket policy must deny non-TLS access")
    assert_contains(backend, r'resource\s+"aws_dynamodb_table"\s+"terraform_locks".*billing_mode\s*=\s*"PAY_PER_REQUEST"', "Backend lock table must use on-demand billing")
    assert_contains(backend, r'hash_key\s*=\s*"LockID"', "Backend lock table hash key must be LockID")
    assert_contains(backend, r'attribute\s+\{[^}]*name\s*=\s*"LockID"[^}]*type\s*=\s*"S"', "Backend lock table LockID attribute must be a string")
    assert_contains(backend, r'server_side_encryption\s+\{[^}]*enabled\s*=\s*true', "Backend lock table server-side encryption must be enabled")
    assert_contains(backend, r'deletion_protection_enabled\s*=\s*true', "Backend lock table deletion protection must be enabled")
    assert_contains(backend, r'prevent_destroy\s*=\s*true', "Backend bucket/table must be guarded with prevent_destroy")

    assert_contains(tf, r'resource\s+"aws_vpc"\s+"shaka"', "Terraform-managed production VPC is required")
    assert_contains(tf, r'enable_dns_hostnames\s*=\s*true', "VPC DNS hostnames must be enabled for EC2/RDS usability")
    assert_contains(tf, r'resource\s+"aws_internet_gateway"\s+"shaka"', "Public app subnet requires an Internet Gateway")
    assert_contains(tf, r'resource\s+"aws_subnet"\s+"app_public"', "Terraform-managed public app subnet is required")
    assert_contains(tf, r'resource\s+"aws_subnet"\s+"rds_private"', "Terraform-managed private RDS subnets are required")
    assert_contains(tf, r'route\s*\{[^}]*cidr_block\s*=\s*"0\.0\.0\.0/0"[^}]*gateway_id\s*=\s*aws_internet_gateway\.shaka\.id', "Only the public route table should route to the Internet Gateway")
    assert_contains(tf, r'resource\s+"aws_instance"\s+"app"', "Terraform-managed EC2 app instance resource is required")
    assert_contains(tf, r'ami\s*=\s*var\.app_ami_id', "EC2 AMI must come from the explicitly pinned app_ami_id variable")
    assert_contains(tf, r'instance_type\s*=\s*var\.app_instance_type', "EC2 instance type must come from the guarded app_instance_type variable")
    assert_contains(tf, r'associate_public_ip_address\s*=\s*true', "EC2 app host must be publicly reachable through 80/443 while app/DB ports stay private")
    assert_contains(tf, r'subnet_id\s*=\s*aws_subnet\.app_public\.id', "EC2 app host must use the Terraform-managed public subnet")
    assert_contains(tf, r'http_tokens\s*=\s*"required"', "EC2 metadata options must require IMDSv2 tokens")
    assert_contains(tf, r'resource\s+"aws_db_instance"', "RDS DB instance resource is required")
    assert_contains(tf, r'instance_class\s*=\s*var\.db_instance_class', "RDS instance class must come from the guarded db_instance_class variable")
    assert_contains(tf, r'variable\s+"db_instance_class".*default\s*=\s*"db\.t4g\.micro"', "RDS must default to low-cost db.t4g.micro")
    assert_contains(tf, r'contains\(\["db\.t4g\.micro",\s*"db\.t3\.micro"\]', "RDS must document/allow only db.t3.micro as fallback")
    assert_contains(tf, r'^\s*allocated_storage\s*=\s*20\b', "RDS allocated storage must default to 20 GiB")
    assert_contains(tf, r'^\s*max_allocated_storage\s*=\s*100\b', "RDS storage autoscaling must allow growth to 100 GiB")
    assert_contains(tf, r'^\s*engine_version\s*=\s*"8\.0\.35"', "RDS MySQL engine minor version must be pinned")
    assert_contains(tf, r'^\s*backup_retention_period\s*=\s*var\.db_backup_retention_period\b', "RDS backup retention must be configurable for account free-tier limits")
    assert_contains(tf, r'variable\s+"db_backup_retention_period".*default\s*=\s*1\b', "RDS backup retention must default to 1 day for the current free-tier account restriction")
    assert_contains(tf, r'var\.db_backup_retention_period\s*>=\s*1\s*&&\s*var\.db_backup_retention_period\s*<=\s*7', "RDS backup retention must stay within the low-cost 1-7 day range")
    assert_contains(tf, r'multi_az\s*=\s*false', "RDS must be Single-AZ (multi_az = false)")
    assert_contains(tf, r'publicly_accessible\s*=\s*false', "RDS must not be publicly accessible")
    assert_contains(tf, r'deletion_protection\s*=\s*true', "Production RDS deletion_protection must be enabled")
    assert_contains(tf, r'prevent_destroy\s*=\s*true', "Production RDS must use prevent_destroy lifecycle guard")

    assert_contains(tf, r'resource\s+"aws_security_group"\s+"app"', "Terraform-managed app security group is required")
    assert_contains(tf, r'resource\s+"aws_security_group_rule"\s+"rds_ingress_from_app_ec2".*source_security_group_id\s*=\s*aws_security_group\.app\.id', "RDS ingress must reference the Terraform-managed app EC2 security group")
    assert_contains(tf, r'db_subnet_group_name\s*=\s*aws_db_subnet_group\.shaka\.name', "RDS must use the private DB subnet group")
    assert_contains(tf, r'subnet_ids\s*=\s*aws_subnet\.rds_private\[\*\]\.id', "RDS subnet group must use Terraform-managed private subnets")
    assert_not_contains(tf, r'resource\s+"aws_security_group_rule"\s+"[^"]*rds[^"]*".*cidr_blocks\s*=\s*\[\s*"0\.0\.0\.0/0"\s*\]', "RDS security group must not allow broad ingress to 0.0.0.0/0")
    assert_not_contains(tf, r'resource\s+"aws_(nat_gateway|db_proxy)"', "NAT Gateway and RDS Proxy are out of scope")
    assert_not_contains(tf, r'replicate_source_db|backup_replication|region\s*=\s*"[^"]+"\s*#\s*cross', "Cross-region backup/replication is out of scope")

    outputs = read(PROD / "outputs.tf")
    assert_contains(outputs, r'output\s+"vpc_id"', "Output vpc_id is required")
    assert_contains(outputs, r'output\s+"public_subnet_id"', "Output public_subnet_id is required")
    assert_contains(outputs, r'output\s+"private_subnet_ids"', "Output private_subnet_ids is required")
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
    assert_contains(readme, r'terraform/bootstrap/backend', "README must document the backend bootstrap root")
    assert_contains(readme, r'dannawagyu-shaka-prod-terraform-state', "README must document the production backend bucket")
    assert_contains(readme, r'shaka-prod-terraform-locks', "README must document the production backend lock table")
    assert_contains(readme, r'terraform init -reconfigure', "README must document remote backend reconfiguration")
    assert_contains(readme, r'lifecycle cost controls', "README must document backend lifecycle cost controls")
    assert_contains(readme, r'S3 server access logging|access logging', "README must document state bucket access logging")
    assert_contains(readme, r'deletion protection', "README must document backend lock table deletion protection")
    assert_contains(readme, r'Auden.*approv|approv.*Auden', "README must keep production apply behind explicit Auden approval")
    assert_contains(readme, r'VPC.*EC2.*RDS|EC2.*RDS.*VPC', "README must document the combined VPC + EC2 + RDS production apply path")
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

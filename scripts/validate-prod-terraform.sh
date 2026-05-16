#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROD_DIR="$ROOT/terraform/environments/prod"
BACKEND_DIR="$ROOT/terraform/bootstrap/backend"

python3 "$ROOT/tests/terraform_static_checks.py"

if ! command -v terraform >/dev/null 2>&1; then
  echo "FAIL: terraform binary is required for fmt/validate checks" >&2
  exit 1
fi

cd "$BACKEND_DIR"
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate

cd "$PROD_DIR"
terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate

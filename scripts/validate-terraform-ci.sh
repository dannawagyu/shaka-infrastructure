#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-true}"
export TF_IN_AUTOMATION="${TF_IN_AUTOMATION:-true}"
export TF_INPUT="false"

python3 -m unittest discover -s "$ROOT/tests" -v

if ! command -v terraform >/dev/null 2>&1; then
  echo "FAIL: terraform binary is required for fmt/validate checks" >&2
  exit 1
fi

terraform -chdir="$ROOT" fmt -check -recursive

roots=(
  "terraform/environments/prod"
  "terraform/observability/grafana"
)

for root in "${roots[@]}"; do
  if [[ ! -d "$ROOT/$root" ]]; then
    echo "FAIL: missing Terraform root: $root" >&2
    exit 1
  fi

  echo "==> terraform init/validate: $root"
  terraform -chdir="$ROOT/$root" init -backend=false -input=false
  terraform -chdir="$ROOT/$root" validate
done

#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-plan}"
if [[ "$MODE" != "plan" && "$MODE" != "apply" ]]; then
  echo "usage: $0 plan|apply" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROD="$ROOT/terraform/environments/prod"
cd "$PROD"

log() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

state_attr() {
  local address="$1" attr="$2"
  terraform state show -no-color "$address" 2>/dev/null \
    | awk -v attr="$attr" '$1 == attr && $2 == "=" {gsub(/"/, "", $3); print $3; exit}'
}

state_id() {
  state_attr "$1" "id"
}

state_rm_if_present() {
  local address="$1"
  if terraform state list | grep -Fxq "$address"; then
    if [[ "$MODE" == "apply" ]]; then
      terraform state rm "$address" >/dev/null
      log "removed state: $address"
    else
      log "would remove state: $address"
    fi
  fi
}

aws_try() {
  if [[ "$MODE" == "apply" ]]; then
    "$@" || warn "ignored failure: $*"
  else
    log "would run: $*"
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    exit 1
  fi
}

require_env TF_VAR_existing_app_instance_id
require_env TF_VAR_existing_app_security_group_id

existing_instance_id="$TF_VAR_existing_app_instance_id"
existing_sg_id="$TF_VAR_existing_app_security_group_id"
existing_subnet_id="$(aws ec2 describe-instances \
  --instance-ids "$existing_instance_id" \
  --query 'Reservations[0].Instances[0].SubnetId' \
  --output text)"
existing_vpc_id="$(aws ec2 describe-subnets \
  --subnet-ids "$existing_subnet_id" \
  --query 'Subnets[0].VpcId' \
  --output text)"

accidental_instance_id="$(state_id aws_instance.app || true)"
accidental_vpc_id="$(state_id aws_vpc.shaka || true)"
accidental_vpc_id="${accidental_vpc_id:-${SHAKA_ACCIDENTAL_VPC_ID:-}}"
accidental_igw_id="$(state_id aws_internet_gateway.shaka || true)"
accidental_app_sg_id="$(state_id aws_security_group.app || true)"
accidental_rds_sg_id="$(state_id aws_security_group.rds || true)"
accidental_public_subnet_id="$(state_id aws_subnet.app_public || true)"
accidental_rds_subnet_0_id="$(state_id 'aws_subnet.rds_private[0]' || true)"
accidental_rds_subnet_1_id="$(state_id 'aws_subnet.rds_private[1]' || true)"
accidental_public_rt_id="$(state_id aws_route_table.public || true)"
accidental_private_rt_id="$(state_id aws_route_table.private || true)"
accidental_db_identifier="$(state_attr aws_db_instance.shaka identifier || true)"
accidental_db_subnet_group="$(state_id aws_db_subnet_group.shaka || true)"

if [[ -n "$accidental_vpc_id" ]]; then
  if [[ -z "$accidental_igw_id" ]]; then
    accidental_igw_id="$(aws ec2 describe-internet-gateways \
      --filters "Name=attachment.vpc-id,Values=$accidental_vpc_id" \
      --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null | sed 's/^None$//' || true)"
  fi
  if [[ -z "$accidental_app_sg_id" ]]; then
    accidental_app_sg_id="$(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$accidental_vpc_id" "Name=group-name,Values=shaka-prod-app" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | sed 's/^None$//' || true)"
  fi
  if [[ -z "$accidental_rds_sg_id" ]]; then
    accidental_rds_sg_id="$(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$accidental_vpc_id" "Name=group-name,Values=shaka-prod-rds" \
      --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | sed 's/^None$//' || true)"
  fi
  if [[ -z "$accidental_public_subnet_id" ]]; then
    accidental_public_subnet_id="$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$accidental_vpc_id" "Name=tag:Name,Values=shaka-prod-public-app" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null | sed 's/^None$//' || true)"
  fi
  if [[ -z "$accidental_rds_subnet_0_id" ]]; then
    accidental_rds_subnet_0_id="$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$accidental_vpc_id" "Name=tag:Name,Values=shaka-prod-private-rds-1" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null | sed 's/^None$//' || true)"
  fi
  if [[ -z "$accidental_rds_subnet_1_id" ]]; then
    accidental_rds_subnet_1_id="$(aws ec2 describe-subnets \
      --filters "Name=vpc-id,Values=$accidental_vpc_id" "Name=tag:Name,Values=shaka-prod-private-rds-2" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null | sed 's/^None$//' || true)"
  fi
  if [[ -z "$accidental_public_rt_id" ]]; then
    accidental_public_rt_id="$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$accidental_vpc_id" "Name=tag:Name,Values=shaka-prod-public" \
      --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null | sed 's/^None$//' || true)"
  fi
  if [[ -z "$accidental_private_rt_id" ]]; then
    accidental_private_rt_id="$(aws ec2 describe-route-tables \
      --filters "Name=vpc-id,Values=$accidental_vpc_id" "Name=tag:Name,Values=shaka-prod-private" \
      --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null | sed 's/^None$//' || true)"
  fi
fi

log "existing app instance: $existing_instance_id"
log "existing app subnet:   $existing_subnet_id"
log "existing app VPC:      $existing_vpc_id"
log "existing app SG:       $existing_sg_id"
log "accidental VPC:        ${accidental_vpc_id:-<none>}"
log "accidental EC2:        ${accidental_instance_id:-<none>}"
log "accidental RDS:        ${accidental_db_identifier:-<none>}"

if [[ -n "$accidental_instance_id" && "$accidental_instance_id" == "$existing_instance_id" ]]; then
  echo "Refusing cleanup: Terraform aws_instance.app matches the existing canonical app instance." >&2
  exit 1
fi
if [[ -n "$accidental_app_sg_id" && "$accidental_app_sg_id" == "$existing_sg_id" ]]; then
  echo "Refusing cleanup: Terraform aws_security_group.app matches the existing canonical app security group." >&2
  exit 1
fi
if [[ -n "$accidental_vpc_id" && "$accidental_vpc_id" == "$existing_vpc_id" ]]; then
  echo "Refusing cleanup: Terraform aws_vpc.shaka matches the existing canonical app VPC." >&2
  exit 1
fi

if [[ "$MODE" == "plan" ]]; then
  log "cleanup mode: plan only; no resources will be changed"
else
  log "cleanup mode: apply; deleting accidental resources only after canonical-resource checks"
fi

# Delete accidental RDS if it lives in the accidental VPC. It blocks DB subnet/VPC cleanup and cannot be moved across VPCs.
if [[ -n "$accidental_db_identifier" && -n "$accidental_vpc_id" ]]; then
  db_vpc_id="$(aws rds describe-db-instances \
    --db-instance-identifier "$accidental_db_identifier" \
    --query 'DBInstances[0].DBSubnetGroup.VpcId' \
    --output text 2>/dev/null || true)"
  if [[ "$db_vpc_id" == "$accidental_vpc_id" ]]; then
    final_snapshot="${accidental_db_identifier}-final-accidental-$(date -u +%Y%m%d%H%M%S)"
    if [[ "$MODE" == "apply" ]]; then
      log "disabling deletion protection on accidental RDS: $accidental_db_identifier"
      aws rds modify-db-instance \
        --db-instance-identifier "$accidental_db_identifier" \
        --no-deletion-protection \
        --apply-immediately >/dev/null
      aws rds wait db-instance-available --db-instance-identifier "$accidental_db_identifier"
      log "deleting accidental RDS with final snapshot: $final_snapshot"
      aws rds delete-db-instance \
        --db-instance-identifier "$accidental_db_identifier" \
        --final-db-snapshot-identifier "$final_snapshot" >/dev/null
      aws rds wait db-instance-deleted --db-instance-identifier "$accidental_db_identifier"
    else
      log "would delete accidental RDS $accidental_db_identifier in VPC $db_vpc_id with final snapshot $final_snapshot"
    fi
  else
    log "keeping RDS $accidental_db_identifier because DB subnet VPC ($db_vpc_id) is not the accidental VPC ($accidental_vpc_id)"
  fi
fi

if [[ -n "$accidental_instance_id" ]]; then
  if [[ "$MODE" == "apply" ]]; then
    log "terminating accidental EC2: $accidental_instance_id"
    aws ec2 terminate-instances --instance-ids "$accidental_instance_id" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "$accidental_instance_id"
  else
    log "would terminate accidental EC2: $accidental_instance_id"
  fi
fi

for rule_addr in \
  aws_security_group_rule.app_ingress_ssh \
  aws_security_group_rule.app_ingress_http \
  aws_security_group_rule.app_ingress_https \
  aws_security_group_rule.app_egress_all \
  aws_security_group_rule.rds_ingress_from_app_ec2; do
  rule_id="$(state_id "$rule_addr" || true)"
  if [[ -n "$rule_id" ]]; then
    aws_try aws ec2 revoke-security-group-ingress --security-group-rule-ids "$rule_id"
    aws_try aws ec2 revoke-security-group-egress --security-group-rule-ids "$rule_id"
  fi
done

for sg_id in "$accidental_rds_sg_id" "$accidental_app_sg_id"; do
  if [[ -n "$sg_id" ]]; then
    aws_try aws ec2 delete-security-group --group-id "$sg_id"
  fi
done

if [[ -n "$accidental_db_subnet_group" ]]; then
  aws_try aws rds delete-db-subnet-group --db-subnet-group-name "$accidental_db_subnet_group"
fi

for assoc_addr in aws_route_table_association.app_public 'aws_route_table_association.rds_private[0]' 'aws_route_table_association.rds_private[1]'; do
  assoc_id="$(state_id "$assoc_addr" || true)"
  if [[ -n "$assoc_id" ]]; then
    aws_try aws ec2 disassociate-route-table --association-id "$assoc_id"
  fi
done

for rt_id in "$accidental_public_rt_id" "$accidental_private_rt_id"; do
  if [[ -n "$rt_id" ]]; then
    aws_try aws ec2 delete-route-table --route-table-id "$rt_id"
  fi
done

if [[ -n "$accidental_igw_id" && -n "$accidental_vpc_id" ]]; then
  aws_try aws ec2 detach-internet-gateway --internet-gateway-id "$accidental_igw_id" --vpc-id "$accidental_vpc_id"
  aws_try aws ec2 delete-internet-gateway --internet-gateway-id "$accidental_igw_id"
fi

for subnet_id in "$accidental_public_subnet_id" "$accidental_rds_subnet_0_id" "$accidental_rds_subnet_1_id"; do
  if [[ -n "$subnet_id" ]]; then
    aws_try aws ec2 delete-subnet --subnet-id "$subnet_id"
  fi
done

if [[ -n "$accidental_vpc_id" ]]; then
  aws_try aws ec2 delete-vpc --vpc-id "$accidental_vpc_id"
fi

for address in \
  aws_instance.app \
  aws_security_group_rule.app_ingress_ssh \
  aws_security_group_rule.app_ingress_http \
  aws_security_group_rule.app_ingress_https \
  aws_security_group_rule.app_egress_all \
  aws_security_group_rule.rds_ingress_from_app_ec2 \
  aws_security_group.app \
  aws_security_group.rds \
  aws_db_instance.shaka \
  aws_db_subnet_group.shaka \
  aws_route_table_association.app_public \
  'aws_route_table_association.rds_private[0]' \
  'aws_route_table_association.rds_private[1]' \
  aws_route_table.public \
  aws_route_table.private \
  aws_internet_gateway.shaka \
  aws_subnet.app_public \
  'aws_subnet.rds_private[0]' \
  'aws_subnet.rds_private[1]' \
  aws_vpc.shaka; do
  state_rm_if_present "$address"
done

log "cleanup complete ($MODE)"

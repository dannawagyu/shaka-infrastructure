# Shaka production import/reference plan

Closes #4

This follow-up to the RDS baseline keeps production safe by documenting current resources before Terraform manages or imports them. The safe sequence is **discover -> import/reference -> plan no-op -> only then allow incremental changes**.

## Current inventory template

Fill in real IDs from AWS Console/CLI during the discovery step. Do not commit live secrets or credentials.

| Resource class | Required inventory | Terraform treatment | Notes |
|---|---|---|---|
| EC2 app host | EC2 app host instance ID, AMI, type, AZ, tags | `data` first; later `terraform import aws_instance...` only after no-op review | No rebuild/replacement in this ticket |
| Networking | VPC, subnet, route table, internet gateway | `data` first, import later if stable | Capture public/private subnet intent |
| App security group | app security group ID and SSH/HTTP/HTTPS ingress | `data` first, import later | SSH restricted to operator IP; 80/443 public as needed; app/actuator/DB ports not public |
| Public IPv4 | Elastic IP or public IPv4 allocation | document/reference | Track public IPv4 hourly cost and ownership |
| DNS/TLS | Route53 records if used, external DNS if not, Let's Encrypt/Certbot ownership | manual/external unless later ADR moves it | Certbot files remain server-local |
| IAM | IAM instance profile, role, attached policies | import or data after policy review | No credential material in Git |
| Storage | EBS root volume, snapshots/backups, backup S3 paths if any | data/import after no-op plan | Do not replace root volume |
| Operations | systemd, Nginx, `/etc/shaka/env`, Grafana Alloy, Sentry/UptimeRobot | host-local/external | Not Terraform-managed in this ticket |

## Discovery commands

Run from an operator shell with AWS credentials already configured. Do not paste secrets into issues or PR comments.

```bash
aws ec2 describe-instances --filters 'Name=tag:Project,Values=shaka' 'Name=instance-state-name,Values=running'
aws ec2 describe-security-groups --group-ids <app-security-group-id>
aws ec2 describe-vpcs --vpc-ids <vpc-id>
aws ec2 describe-subnets --filters 'Name=vpc-id,Values=<vpc-id>'
aws ec2 describe-route-tables --filters 'Name=vpc-id,Values=<vpc-id>'
aws ec2 describe-internet-gateways --filters 'Name=attachment.vpc-id,Values=<vpc-id>'
aws ec2 describe-addresses --filters 'Name=instance-id,Values=<instance-id>'
aws iam get-instance-profile --instance-profile-name <profile-name>
aws ec2 describe-volumes --filters 'Name=attachment.instance-id,Values=<instance-id>'
```

## Terraform import/reference path

1. Set only non-secret IDs in local uncommitted `*.tfvars` or `TF_VAR_*` env vars.
2. Run `terraform plan` with `data` references only.
3. Confirm there is no unexpected replacement or destructive change.
4. If importing, add one import at a time and rerun `terraform plan` after each import.

Example commands to adapt after exact resource addresses are chosen:

```bash
terraform import 'aws_instance.app[0]' '<instance-id>'
terraform import 'aws_security_group.app[0]' '<app-security-group-id>'
terraform import 'aws_vpc.main[0]' '<vpc-id>'
terraform import 'aws_subnet.public[0]' '<subnet-id>'
```

Do not import by manually editing Terraform state. Do not run `terraform apply` until a plan no-op is reviewed.

## Safety rules

- No AWS credentials, SSH private keys, DB passwords, Grafana tokens, Sentry tokens, or Discord webhook URLs are committed.
- Existing production EC2, DNS/TLS, IAM, and storage must not be recreated by this ticket.
- A production `terraform plan` after import/reference must show no unexpected replacement or destructive changes before incremental changes are allowed.
- If a resource remains manual/external, record why and how operators should reason about drift.

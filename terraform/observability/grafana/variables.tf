variable "grafana_cloud_url" {
  description = "Grafana Cloud stack URL, for example https://example.grafana.net. Pass via TF_VAR_grafana_cloud_url."
  type        = string
  sensitive   = true
}

variable "grafana_auth" {
  description = "Grafana Cloud service account token with alerting write permissions. Pass via TF_VAR_grafana_auth."
  type        = string
  sensitive   = true
}

variable "prometheus_datasource_uid" {
  description = "Grafana datasource UID for the Grafana Cloud Prometheus/Mimir datasource receiving Shaka metrics."
  type        = string
}

variable "cloudwatch_datasource_uid" {
  description = "Grafana datasource UID for the Grafana CloudWatch datasource used by the imported Amazon RDS dashboard. This is a datasource UID, not an AWS key, token, or endpoint."
  type        = string
}

variable "cloudwatch_region" {
  description = "AWS region used by the Grafana CloudWatch datasource for the RDS dashboard and Phase 1 migration-window alerts. Pass the production AWS_REGION so CloudWatch queries do not fall back to the datasource default region."
  type        = string
  default     = "ap-southeast-2"
}

variable "phase1_rds_db_instance_identifier" {
  description = "RDS DBInstanceIdentifier used by Phase 1 migration-window alerts. Pass each environment's intended DB instance explicitly so missing configuration fails closed."
  type        = string

  validation {
    condition     = length(trimspace(var.phase1_rds_db_instance_identifier)) > 0 && trimspace(var.phase1_rds_db_instance_identifier) != "*"
    error_message = "phase1_rds_db_instance_identifier must be a specific RDS DBInstanceIdentifier, not empty or '*'."
  }
}

variable "loki_datasource_uid" {
  description = "Grafana datasource UID for the Grafana Cloud Loki datasource used by dashboard log panels. This is a datasource UID, not a token or endpoint."
  type        = string
}

variable "tempo_datasource_uid" {
  description = "Grafana datasource UID for the Grafana Cloud Tempo datasource used by dashboard trace panels. This is a datasource UID, not a token or endpoint."
  type        = string
}

variable "notification_contact_point_name" {
  description = "Existing Grafana contact point name used by alert notification_settings. Discord webhook/contact point is managed manually to avoid storing webhook secrets in Terraform state."
  type        = string
  default     = "discord-shaka-alerts"
}

variable "alert_evaluation_interval_seconds" {
  description = "Evaluation interval for the Shaka RFC-0010 alert rule group."
  type        = number
  default     = 60
}

variable "alert_folder_title" {
  description = "Grafana folder title for Shaka managed alert rules."
  type        = string
  default     = "Shaka Observability"
}

variable "runbook_base_url" {
  description = "Runbook URL attached to managed alert rule annotations."
  type        = string
  default     = "https://github.com/WagyuShark/shaka-wiki/blob/main/projects/shaka/engineering/repository-docs/shaka-infrastructure/docs/observability/grafana-alerting.md"
}

variable "environment" {
  description = "Environment label attached to managed alert rules."
  type        = string
  default     = "prod"
}

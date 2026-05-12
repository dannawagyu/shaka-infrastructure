variable "prometheus_remote_write_endpoint" {
  description = "Grafana Cloud Prometheus remote_write endpoint placeholder. Provide via operator environment only."
  type        = string
  sensitive   = true
  default     = null
}

variable "prometheus_remote_write_user" {
  description = "Grafana Cloud Prometheus remote_write user/instance ID placeholder. Provide via operator environment only."
  type        = string
  sensitive   = true
  default     = null
}

variable "prometheus_remote_write_token" {
  description = "Grafana Cloud Prometheus remote_write token placeholder. Never commit real values."
  type        = string
  sensitive   = true
  default     = null
}

variable "loki_endpoint" {
  description = "Grafana Cloud Loki endpoint placeholder for a future server-side Alloy log pipeline."
  type        = string
  sensitive   = true
  default     = null
}

variable "loki_user" {
  description = "Grafana Cloud Loki user/instance ID placeholder."
  type        = string
  sensitive   = true
  default     = null
}

variable "loki_token" {
  description = "Grafana Cloud Loki token placeholder. Never commit real values."
  type        = string
  sensitive   = true
  default     = null
}

variable "enable_loki_ingestion" {
  description = "Stage Loki ingestion behind a later apply after privacy/cardinality review and server-side Alloy pipeline changes."
  type        = bool
  default     = false
}

locals {
  observability_stack_labels = merge(local.shaka_alert_labels, {
    metrics_backend = "grafana-cloud-prometheus"
    logs_backend    = var.enable_loki_ingestion ? "grafana-cloud-loki" : "staged"
  })
}

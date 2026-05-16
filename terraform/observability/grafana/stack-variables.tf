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

variable "tempo_endpoint" {
  description = "Grafana Cloud Tempo OTLP endpoint placeholder for a future server-side Alloy tracing pipeline."
  type        = string
  sensitive   = true
  default     = null
}

variable "tempo_user" {
  description = "Grafana Cloud Tempo user/instance ID placeholder."
  type        = string
  sensitive   = true
  default     = null
}

variable "tempo_token" {
  description = "Grafana Cloud Tempo token placeholder. Never commit real values."
  type        = string
  sensitive   = true
  default     = null
}

variable "enable_tempo_tracing" {
  description = "Stage Tempo tracing behind a later apply after overhead, privacy, sampling, and rollback review."
  type        = bool
  default     = false
}

variable "tempo_sampling_rate" {
  description = "Conservative initial Tempo trace sampling rate for a later approved rollout. Keep between 0% and 5%."
  type        = number
  default     = 0.01

  validation {
    condition     = var.tempo_sampling_rate >= 0 && var.tempo_sampling_rate <= 0.05
    error_message = "tempo_sampling_rate must be between 0.0 and 0.05 for the staged Shaka production tracing design."
  }
}

locals {
  observability_stack_labels = merge(local.shaka_alert_labels, {
    metrics_backend = "grafana-cloud-prometheus"
    logs_backend    = var.enable_loki_ingestion ? "grafana-cloud-loki" : "staged"
    traces_backend  = var.enable_tempo_tracing ? "grafana-cloud-tempo" : "staged"
  })
}

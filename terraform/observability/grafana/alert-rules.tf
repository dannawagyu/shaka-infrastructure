resource "grafana_folder" "shaka_observability" {
  title = var.alert_folder_title
}

locals {
  shaka_alert_labels = {
    service_name           = "shaka-server"
    deployment_environment = var.environment
    managed_by             = "terraform"
  }
}

resource "grafana_rule_group" "shaka_rfc_0010" {
  name             = "Shaka RFC-0010 production alerts"
  folder_uid       = grafana_folder.shaka_observability.uid
  interval_seconds = var.alert_evaluation_interval_seconds

  dynamic "rule" {
    for_each = {
      app_scrape_down = {
        title     = "Shaka app OTLP metrics missing"
        condition = "absent_over_time(target_info{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\"}[10m]) or vector(0)"
        summary   = "OpenTelemetry app metrics from shaka-server are missing. Check the app, Java agent, and local Alloy OTLP receiver/exporter."
      }
      http_5xx = {
        title     = "Shaka HTTP 5xx rate high"
        condition = "((sum(rate(http_server_request_duration_seconds_count{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\",http_response_status_code=~\"5..\"}[5m])) or vector(0)) / clamp_min((sum(rate(http_server_request_duration_seconds_count{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\"}[5m])) or vector(0)), 1)) > 0.05"
        summary   = "Backend is returning elevated 5xx responses."
      }
      jvm_heap_high = {
        title     = "Shaka JVM heap pressure"
        condition = "sum(jvm_memory_used_bytes{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\",jvm_memory_type=\"heap\"}) / sum(jvm_memory_limit_bytes{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\",jvm_memory_type=\"heap\"}) > 0.85"
        summary   = "JVM heap usage is above 85%."
      }
      root_disk_warn = {
        title     = "Shaka root disk warning"
        condition = "max(system_filesystem_utilization_ratio{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\",mountpoint=\"/\",type!~\"tmpfs|overlay\"}) > 0.80"
        summary   = "Root disk usage is above 80%."
      }
      root_disk_critical = {
        title     = "Shaka root disk critical"
        condition = "max(system_filesystem_utilization_ratio{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\",mountpoint=\"/\",type!~\"tmpfs|overlay\"}) > 0.90"
        summary   = "Root disk usage is above 90%."
      }
      memory_pressure = {
        title     = "Shaka host memory pressure"
        condition = "max(system_memory_utilization_ratio{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\",state=\"used\"}) > 0.90"
        summary   = "Host available memory is below 10% (usage above 90%)."
      }
      cpu_saturation = {
        title     = "Shaka host CPU saturation"
        condition = "1 - avg(rate(system_cpu_time_seconds{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\",state=\"idle\"}[5m])) > 0.90"
        summary   = "Host CPU usage is above 90%."
      }
      alloy_down = {
        title     = "Shaka Alloy OTLP pipeline missing"
        condition = "absent_over_time(system_cpu_time_seconds{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\"}[10m]) or vector(0)"
        summary   = "Alloy host metrics heartbeat is missing; verify the Alloy service and Grafana Cloud OTLP exporter."
      }
    }
    content {
      uid            = rule.key
      name           = rule.value.title
      condition      = "C"
      for            = "5m"
      no_data_state  = "OK"
      exec_err_state = "Error"
      labels         = local.shaka_alert_labels

      annotations = {
        summary     = rule.value.summary
        runbook_url = var.runbook_base_url
      }

      data {
        ref_id = "A"

        relative_time_range {
          from = 600
          to   = 0
        }

        datasource_uid = var.prometheus_datasource_uid
        model = jsonencode({
          datasource = {
            type = "prometheus"
            uid  = var.prometheus_datasource_uid
          }
          expr          = rule.value.condition
          intervalMs    = 15000
          maxDataPoints = 43200
          refId         = "A"
        })
      }

      data {
        ref_id = "B"

        relative_time_range {
          from = 600
          to   = 0
        }

        datasource_uid = "__expr__"
        model = jsonencode({
          type       = "reduce"
          expression = "A"
          reducer    = "last"
          refId      = "B"
        })
      }

      data {
        ref_id = "C"

        relative_time_range {
          from = 600
          to   = 0
        }

        datasource_uid = "__expr__"
        model = jsonencode({
          type       = "threshold"
          expression = "B"
          conditions = [{
            evaluator = { type = "gt", params = [0] }
            operator  = { type = "and" }
            query     = { params = ["B"] }
            reducer   = { type = "last" }
            type      = "query"
          }]
          refId = "C"
        })
      }

      notification_settings {
        contact_point = var.notification_contact_point_name
      }
    }
  }
}

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
        title     = "Shaka app scrape down"
        condition = "up{job=\"shaka-server\"} == 0"
        summary   = "Spring Boot /actuator/prometheus scrape is down."
      }
      host_scrape_down = {
        title     = "Shaka host scrape down"
        condition = "up{job=\"shaka-host\"} == 0"
        summary   = "Host metrics scrape through Alloy is down."
      }
      http_5xx = {
        title     = "Shaka HTTP 5xx rate high"
        condition = "sum by (instance, job) (rate(http_server_requests_seconds_count{status=~\"5..\"}[5m])) / sum by (instance, job) (rate(http_server_requests_seconds_count[5m])) > 0.05"
        summary   = "Backend is returning elevated 5xx responses."
      }
      jvm_heap_high = {
        title     = "Shaka JVM heap pressure"
        condition = "sum by (instance, job) (jvm_memory_used_bytes{area=\"heap\"}) / sum by (instance, job) (jvm_memory_max_bytes{area=\"heap\"}) > 0.85"
        summary   = "JVM heap usage is above 85%."
      }
      root_disk_warn = {
        title     = "Shaka root disk warning"
        condition = "1 - (node_filesystem_avail_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"}) > 0.80"
        summary   = "Root disk usage is above 80%."
      }
      root_disk_critical = {
        title     = "Shaka root disk critical"
        condition = "1 - (node_filesystem_avail_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{mountpoint=\"/\",fstype!~\"tmpfs|overlay\"}) > 0.90"
        summary   = "Root disk usage is above 90%."
      }
      memory_pressure = {
        title     = "Shaka host memory pressure"
        condition = "1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.90"
        summary   = "Host available memory is below 10% (usage above 90%)."
      }
      cpu_saturation = {
        title     = "Shaka host CPU saturation"
        condition = "1 - avg by (instance, job) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) > 0.90"
        summary   = "Host CPU usage is above 90%."
      }
      core_systemd_service_down = {
        title     = "Shaka core systemd service down"
        condition = "node_systemd_unit_state{name=~\"(shaka-server|nginx)\\.service\",state=\"active\"} == 0"
        summary   = "One or more core services are inactive or failed."
      }
      alloy_down = {
        title     = "Shaka Alloy service down"
        condition = "node_systemd_unit_state{name=\"alloy.service\",state=\"active\"} == 0"
        summary   = "Grafana Alloy collector service is inactive or failed."
      }
    }

    content {
      uid       = rule.key
      name      = rule.value.title
      condition = "C"
      for       = "5m"
      labels    = local.shaka_alert_labels

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

resource "grafana_folder" "shaka_observability" {
  title = var.alert_folder_title
}

locals {
  shaka_alert_labels = {
    service_name           = "shaka-server"
    deployment_environment = var.environment
    managed_by             = "terraform"
  }

  shaka_phase1_rds_alert_labels = {
    service_name           = "shaka-rds"
    deployment_environment = var.environment
    managed_by             = "terraform"
    rollout_phase          = "phase1-membership-migration"
  }
}

resource "grafana_rule_group" "shaka_rfc_0010" {
  name             = "Shaka RFC-0010 production alerts"
  folder_uid       = grafana_folder.shaka_observability.uid
  interval_seconds = var.alert_evaluation_interval_seconds

  dynamic "rule" {
    for_each = {
      app_scrape_down = {
        uid       = "app_scrape_down"
        title     = "Shaka app OTLP metrics missing"
        condition = "absent_over_time(target_info{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\"}[10m]) or vector(0)"
        summary   = "OpenTelemetry app metrics from shaka-server are missing. Check the app, Java agent, and local Alloy OTLP receiver/exporter."
      }
      http_5xx = {
        uid       = "http_5xx"
        title     = "Shaka HTTP 5xx rate high"
        condition = "(sum(rate(http_server_request_duration_seconds_count{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\",http_response_status_code=~\"5..\"}[5m])) / sum(rate(http_server_request_duration_seconds_count{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\"}[5m])) > 0.05) and (sum(rate(http_server_request_duration_seconds_count{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\"}[5m])) > 0)"
        summary   = "Backend is returning elevated 5xx responses."
      }
      jvm_heap_high = {
        uid       = "jvm_heap_high"
        title     = "Shaka JVM heap pressure"
        condition = "sum by (service_instance_id) (jvm_memory_used_bytes{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\",jvm_memory_type=\"heap\"}) / sum by (service_instance_id) (jvm_memory_limit_bytes{service_name=\"shaka-server\",deployment_environment=\"${var.environment}\",jvm_memory_type=\"heap\"}) > 0.85"
        summary   = "JVM heap usage is above 85%."
      }
      root_disk_warn = {
        uid       = "root_disk_warn"
        title     = "Shaka root disk warning"
        condition = "sum by (service_instance_id, mountpoint) (system_filesystem_usage_bytes{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\",mountpoint=\"/\",type!~\"tmpfs|overlay\",state=\"used\"}) / sum by (service_instance_id, mountpoint) (system_filesystem_limit_bytes{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\",mountpoint=\"/\",type!~\"tmpfs|overlay\"}) > 0.80"
        summary   = "Root disk usage is above 80%."
      }
      root_disk_critical = {
        uid       = "root_disk_critical"
        title     = "Shaka root disk critical"
        condition = "sum by (service_instance_id, mountpoint) (system_filesystem_usage_bytes{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\",mountpoint=\"/\",type!~\"tmpfs|overlay\",state=\"used\"}) / sum by (service_instance_id, mountpoint) (system_filesystem_limit_bytes{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\",mountpoint=\"/\",type!~\"tmpfs|overlay\"}) > 0.90"
        summary   = "Root disk usage is above 90%."
      }
      memory_pressure = {
        uid       = "memory_pressure"
        title     = "Shaka host memory pressure"
        condition = "sum by (service_instance_id) (system_memory_usage_bytes{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\",state=\"used\"}) / sum by (service_instance_id) (system_memory_usage_bytes{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\"}) > 0.90"
        summary   = "Host available memory is below 10% (usage above 90%)."
      }
      cpu_saturation = {
        uid       = "cpu_saturation"
        title     = "Shaka host CPU saturation"
        condition = "1 - avg by (service_instance_id) (rate(system_cpu_time_seconds_total{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\",state=\"idle\"}[5m])) > 0.90"
        summary   = "Host CPU usage is above 90%."
      }
      core_systemd_service_down = {
        uid       = "core_systemd_service_down"
        title     = "Shaka core systemd service down"
        condition = "node_systemd_unit_state{name=~\"(shaka-server|nginx)[.]service\",state=\"active\"} == 0"
        summary   = "One or more core services are inactive or failed when systemd metrics are available."
      }
      alloy_down = {
        uid       = "alloy_down"
        title     = "Shaka Alloy OTLP pipeline missing"
        condition = "absent_over_time(system_cpu_time_seconds_total{service_name=\"shaka-host\",deployment_environment=\"${var.environment}\"}[10m]) or vector(0)"
        summary   = "Alloy host metrics heartbeat is missing; verify the Alloy service and Grafana Cloud OTLP exporter."
      }
    }
    content {
      uid            = rule.value.uid
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

resource "grafana_rule_group" "shaka_phase1_rds_migration_window" {
  name             = "Shaka Phase 1 RDS migration window alerts"
  folder_uid       = grafana_folder.shaka_observability.uid
  interval_seconds = var.alert_evaluation_interval_seconds

  dynamic "rule" {
    for_each = {
      phase1_rds_cpu_high = {
        uid        = "phase1_rds_cpu_high"
        title      = "Shaka Phase 1 RDS CPU high"
        metric     = "CPUUtilization"
        statistic  = "Average"
        evaluator  = "gt"
        threshold  = 80
        unit       = "Percent"
        summary    = "RDS CPU is high during the Phase 1 group_member migration window."
        expression = "CPUUtilization average is above 80%."
      }
      phase1_rds_connections_high = {
        uid        = "phase1_rds_connections_high"
        title      = "Shaka Phase 1 RDS connections high"
        metric     = "DatabaseConnections"
        statistic  = "Average"
        evaluator  = "gt"
        threshold  = 80
        unit       = "Count"
        summary    = "RDS database connections are elevated during the Phase 1 group_member migration window."
        expression = "DatabaseConnections average is above 80."
      }
      phase1_rds_storage_low = {
        uid        = "phase1_rds_storage_low"
        title      = "Shaka Phase 1 RDS free storage low"
        metric     = "FreeStorageSpace"
        statistic  = "Minimum"
        evaluator  = "lt"
        threshold  = 10737418240
        unit       = "Bytes"
        summary    = "RDS free storage is below 10 GiB during the Phase 1 group_member migration window."
        expression = "FreeStorageSpace minimum is below 10 GiB."
      }
      phase1_rds_write_latency_high = {
        uid        = "phase1_rds_write_latency_high"
        title      = "Shaka Phase 1 RDS write latency high"
        metric     = "WriteLatency"
        statistic  = "Average"
        evaluator  = "gt"
        threshold  = 0.1
        unit       = "Seconds"
        summary    = "RDS write latency is high during the Phase 1 group_member migration window."
        expression = "WriteLatency average is above 100 ms."
      }
    }
    content {
      uid            = rule.value.uid
      name           = rule.value.title
      condition      = "C"
      for            = "5m"
      no_data_state  = "Alerting"
      exec_err_state = "Error"
      labels         = local.shaka_phase1_rds_alert_labels

      annotations = {
        summary     = rule.value.summary
        description = rule.value.expression
        runbook_url = var.runbook_base_url
      }

      data {
        ref_id = "A"

        relative_time_range {
          from = 600
          to   = 0
        }

        datasource_uid = var.cloudwatch_datasource_uid
        model = jsonencode({
          datasource = {
            type = "cloudwatch"
            uid  = var.cloudwatch_datasource_uid
          }
          # Grafana CloudWatch Metric Search supports wildcard dimension values;
          # keep Match Exact explicit so RDS migration alerts track every metric
          # with the single DBInstanceIdentifier dimension instead of silently
          # depending on a datasource default or a dashboard template variable.
          dimensions = {
            DBInstanceIdentifier = "*"
          }
          expression    = ""
          id            = "A"
          matchExact    = true
          intervalMs    = 60000
          maxDataPoints = 43200
          metricName    = rule.value.metric
          namespace     = "AWS/RDS"
          period        = "60"
          queryMode     = "Metrics"
          refId         = "A"
          region        = var.cloudwatch_region
          statistic     = rule.value.statistic
          unit          = rule.value.unit
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
            evaluator = { type = rule.value.evaluator, params = [rule.value.threshold] }
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

resource "grafana_dashboard" "shaka_prod_overview" {
  folder = grafana_folder.shaka_observability.uid
  config_json = templatefile("${path.module}/dashboards/shaka-prod-overview.json.tftpl", {
    prometheus_datasource_uid = var.prometheus_datasource_uid
    loki_datasource_uid       = var.loki_datasource_uid
    tempo_datasource_uid      = var.tempo_datasource_uid
    environment               = var.environment
    environment_title         = title(var.environment)
  })
  overwrite = true
}

resource "grafana_dashboard" "shaka_amazon_rds" {
  folder = grafana_folder.shaka_observability.uid
  config_json = templatefile("${path.module}/dashboards/amazon-rds.json.tftpl", {
    cloudwatch_datasource_uid = var.cloudwatch_datasource_uid
    cloudwatch_region         = var.cloudwatch_region
  })
  overwrite = true
}


resource "grafana_dashboard" "shaka_alb_cloudwatch" {
  folder = grafana_folder.shaka_observability.uid
  config_json = templatefile("${path.module}/dashboards/shaka-alb-cloudwatch.json.tftpl", {
    cloudwatch_datasource_uid    = var.cloudwatch_datasource_uid
    cloudwatch_region            = var.cloudwatch_region
    environment                  = var.environment
    alb_load_balancer_arn_suffix = var.alb_load_balancer_arn_suffix
    alb_target_group_arn_suffix  = var.alb_target_group_arn_suffix
    environment_title            = title(var.environment)
  })
  overwrite = true
}

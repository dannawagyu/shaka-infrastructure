resource "grafana_dashboard" "shaka_prod_overview" {
  folder = grafana_folder.shaka_observability.uid
  config_json = templatefile("${path.module}/dashboards/shaka-prod-overview.json.tftpl", {
    prometheus_datasource_uid = var.prometheus_datasource_uid
    environment               = var.environment
  })
  overwrite = true
}

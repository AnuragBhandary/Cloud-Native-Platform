# Grafana and Prometheus through the gateway: http://grafana.localhost:8088,
# http://prometheus.localhost:8088. A chart rather than kubernetes_manifest, because the HTTPRoute
# kind does not exist until the Gateway API CRDs are applied, so it can't be planned beforehand.
resource "helm_release" "ui_routes" {
  name       = "ui-routes"
  namespace  = "monitoring"
  chart      = "${path.module}/../../../charts/routes"
  depends_on = [helm_release.traefik, helm_release.monitoring]
}

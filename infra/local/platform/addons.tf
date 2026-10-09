# Cluster add-ons, each pinned to a chart version.

resource "helm_release" "cnpg" {
  name             = "cnpg"
  namespace        = "cnpg-system"
  create_namespace = true
  repository       = "https://cloudnative-pg.github.io/charts"
  chart            = "cloudnative-pg"
  version          = "0.29.1"
  wait             = true
}

resource "helm_release" "keda" {
  name             = "keda"
  namespace        = "keda"
  create_namespace = true
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.21.0"
  wait             = true
  # On a fresh cluster the operator restarts a few times while it issues the webhook's
  # certificates; the default 5-minute wait is not always enough.
  timeout = 600
}

resource "helm_release" "monitoring" {
  name             = "monitoring"
  namespace        = "monitoring"
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "92.2.0"
  wait             = true
  timeout          = 600
  values           = [templatefile("${path.module}/values/monitoring.yaml", { grafana_password = var.grafana_password })]
}

# Gateway API CRDs (Gateway, HTTPRoute, ...), from the official v1.6.3 release file vendored in
# crds/. Too large for a Helm release secret, so they are applied as individual manifests.
locals {
  gateway_api_docs = [
    for doc in split("\n---\n", file("${path.module}/crds/gateway-api-v1.6.3-standard.yaml")) :
    yamldecode(doc) if can(yamldecode(doc)) && try(yamldecode(doc).kind, null) != null
  ]
}

resource "kubernetes_manifest" "gateway_api" {
  for_each = { for d in local.gateway_api_docs : "${d.kind}/${d.metadata.name}" => d }
  manifest = each.value
  field_manager {
    force_conflicts = true
  }
}

resource "helm_release" "traefik" {
  name             = "traefik"
  namespace        = "traefik"
  create_namespace = true
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = "41.7.0"
  wait             = true
  values           = [file("${path.module}/values/traefik.yaml"), yamlencode({ service = local.traefik_service })]
  depends_on       = [kubernetes_manifest.gateway_api]
}

# Resource metrics for CPU-based autoscaling (the API's HPA). kind's kubelets use self-signed
# serving certificates, hence --kubelet-insecure-tls (local cluster only).
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.14.0"
  set_list   = [{ name = "args", value = local.metrics_server_args }]
}

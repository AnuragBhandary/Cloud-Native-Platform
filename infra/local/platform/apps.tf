# The jobq task scheduler, from the chart in this repository. Its image is built from the
# Distributed-Job-Scheduler repo and loaded into the nodes by the cluster stage.
resource "helm_release" "jobq" {
  name             = "jobq"
  namespace        = "jobq"
  create_namespace = true
  chart            = "${path.module}/../../../charts/jobq"
  wait             = true
  timeout          = 600
  set = [
    { name = "image.repository", value = var.jobq_image_repository },
    { name = "image.tag", value = var.jobq_image_tag },
  ]

  depends_on = [
    helm_release.cnpg,
    helm_release.keda,
    helm_release.monitoring,
    helm_release.traefik,
    kubernetes_storage_class_v1.gp3,
  ]
}

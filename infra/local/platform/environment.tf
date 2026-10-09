# What differs between the local kind cluster and EKS.
locals {
  aws = var.environment == "aws"
  # kind: the gateway is a NodePort that kind publishes on localhost. EKS: an AWS load balancer.
  traefik_service = local.aws ? {
    spec        = { type = "LoadBalancer" }
    annotations = { "service.beta.kubernetes.io/aws-load-balancer-type" = "nlb" }
  } : { spec = { type = "NodePort" } }
  # kind's kubelets have self-signed serving certificates; EKS's are properly signed.
  metrics_server_args = local.aws ? [] : ["--kubelet-insecure-tls"]
}

# EKS has no default StorageClass; PostgreSQL and Redis claim volumes, so make gp3 the default.
resource "kubernetes_storage_class_v1" "gp3" {
  count = local.aws ? 1 : 0
  metadata {
    name        = "gp3"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters             = { type = "gp3", encrypted = "true" }
}

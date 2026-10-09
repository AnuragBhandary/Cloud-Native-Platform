# A five-node Kubernetes cluster in Docker, laid out like a production cluster's node pools:
#   control-plane
#   2 x pool=system  API, schedulers, PostgreSQL, Redis, gateway, monitoring
#   2 x pool=jobs    workers only (tainted), so a jobs node can fail without taking anything else
# Port 30080 (the gateway's NodePort) of the first system node is published as localhost:8088.
resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
    }
    node {
      role   = "worker"
      labels = { pool = "system", ingress-ready = "true" }
      extra_port_mappings {
        container_port = 30080
        host_port      = var.http_port
      }
    }
    node {
      role   = "worker"
      labels = { pool = "system" }
    }
    node {
      role   = "worker"
      labels = { pool = "jobs" }
      # Tainted: only pods that tolerate dedicated=jobs (the workers) are scheduled here.
      kubeadm_config_patches = [<<-YAML
        kind: JoinConfiguration
        nodeRegistration:
          taints:
            - key: dedicated
              value: jobs
              effect: NoSchedule
      YAML
      ]
    }
    node {
      role   = "worker"
      labels = { pool = "jobs" }
      # Tainted: only pods that tolerate dedicated=jobs (the workers) are scheduled here.
      kubeadm_config_patches = [<<-YAML
        kind: JoinConfiguration
        nodeRegistration:
          taints:
            - key: dedicated
              value: jobs
              effect: NoSchedule
      YAML
      ]
    }
  }
}

# kind nodes can't pull an image that only exists in the local Docker daemon, so the jobq image
# (built by `make image` from the scheduler repo) is copied into every node.
resource "terraform_data" "jobq_image" {
  triggers_replace = [kind_cluster.this.id, var.jobq_image_tag]
  provisioner "local-exec" {
    command = "kind load docker-image jobq:${var.jobq_image_tag} --name ${var.cluster_name}"
  }
}

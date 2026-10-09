output "kubeconfig_path" {
  description = "Kubeconfig the platform stage connects with."
  value       = kind_cluster.this.kubeconfig_path
}

output "context" {
  value = "kind-${var.cluster_name}"
}

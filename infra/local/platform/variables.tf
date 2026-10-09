variable "kubeconfig_path" {
  description = "Kubeconfig written by the cluster stage (terraform -chdir=../cluster output -raw kubeconfig_path)."
  type        = string
}

variable "kube_context" {
  type    = string
  default = "kind-platform"
}

variable "grafana_password" {
  description = "Grafana admin password (local cluster only)."
  type        = string
  default     = "admin-local-only"
  sensitive   = true
}

variable "jobq_image_tag" {
  description = "Tag of the jobq image (loaded into the nodes by the cluster stage)."
  type        = string
  default     = "8b7941f"
}

variable "environment" {
  description = "local (kind) or aws (EKS from ../../aws). Switches the few settings that differ."
  type        = string
  default     = "local"
  validation {
    condition     = contains(["local", "aws"], var.environment)
    error_message = "environment must be local or aws."
  }
}

variable "jobq_image_repository" {
  description = "jobq image repository: the image loaded into kind locally, the ECR repository on AWS."
  type        = string
  default     = "jobq"
}

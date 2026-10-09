variable "region" {
  type    = string
  default = "ap-south-1" # Mumbai
}

variable "cluster_name" {
  type    = string
  default = "platform"
}

variable "kubernetes_version" {
  type    = string
  default = "1.34"
}

variable "system_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "jobs_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "jobs_max_nodes" {
  description = "Upper bound for the jobs node group (workers only)."
  type        = number
  default     = 3
}

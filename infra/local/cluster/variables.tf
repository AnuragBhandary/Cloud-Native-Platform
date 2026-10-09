variable "cluster_name" {
  type    = string
  default = "platform"
}

variable "http_port" {
  description = "Host port that reaches the cluster's gateway."
  type        = number
  default     = 8088
}

variable "jobq_image_tag" {
  description = "Tag of the locally built jobq image to load into the nodes (the scheduler repo's commit)."
  type        = string
  default     = "8b7941f"
}

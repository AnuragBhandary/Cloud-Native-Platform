terraform {
  required_version = ">= 1.9"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # For a shared or long-lived cluster, keep state in S3 with locking, e.g.:
  # backend "s3" { bucket = "<state-bucket>", key = "platform/aws.tfstate", region = "ap-south-1", use_lockfile = true }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "cloud-native-platform", ManagedBy = "terraform" }
  }
}

# The same platform on AWS: VPC, EKS with the two node pools used locally, EBS storage for
# PostgreSQL, and an ECR repository for the jobq image. The add-ons and jobq are then installed by
# ../local/platform pointed at this cluster's kubeconfig (see docs/AWS.md).
#
# Cost: this runs a paid control plane, three t3.medium nodes, a NAT gateway and a load balancer.
# Create it for a test, then `terraform destroy`.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name            = var.cluster_name
  cidr            = "10.40.0.0/16"
  azs             = local.azs
  private_subnets = ["10.40.1.0/24", "10.40.2.0/24"]
  public_subnets  = ["10.40.101.0/24", "10.40.102.0/24"]

  # One NAT gateway instead of one per AZ: cheaper, and acceptable for a test cluster.
  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                   = var.cluster_name
  kubernetes_version     = var.kubernetes_version
  vpc_id                 = module.vpc.vpc_id
  subnet_ids             = module.vpc.private_subnets
  endpoint_public_access = true

  # The identity running Terraform gets cluster-admin, so kubectl and the platform stage work.
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true }
    aws-ebs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  eks_managed_node_groups = {
    # API, schedulers, PostgreSQL, Redis, gateway, monitoring.
    system = {
      instance_types = [var.system_instance_type]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      labels         = { pool = "system" }
    }
    # Workers only: the taint keeps everything else off, as in the local cluster.
    jobs = {
      instance_types = [var.jobs_instance_type]
      min_size       = 1
      max_size       = var.jobs_max_nodes
      desired_size   = 1
      labels         = { pool = "jobs" }
      taints = {
        dedicated = { key = "dedicated", value = "jobs", effect = "NO_SCHEDULE" }
      }
    }
  }
}

# The EBS CSI driver needs permission to create and attach volumes (PostgreSQL and Redis PVCs).
resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_ecr_repository" "jobq" {
  name                 = "jobq"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "jobq" {
  repository = aws_ecr_repository.jobq.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 20 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

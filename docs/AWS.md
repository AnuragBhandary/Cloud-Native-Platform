# Running it on AWS (EKS)

`infra/aws` creates the same shape on AWS: a VPC (two AZs, one NAT gateway), an EKS cluster with a
`system` node group and a tainted `jobs` node group, the EBS CSI driver (via EKS Pod Identity) for
PostgreSQL and Redis volumes, and an ECR repository for the jobq image. It is validated in CI
(`terraform validate`) but **has not been applied**: running it costs money, so it is a deliberate,
short test run when wanted.

## Cost

A control plane, three t3.medium nodes, one NAT gateway and one network load balancer. At
on-demand prices that is roughly **US$0.30 an hour, about ₹25-30 an hour**, plus small charges for
EBS volumes and data. A two-to-three-hour test run is about ₹75-100. Check the current
[EKS](https://aws.amazon.com/eks/pricing/) and [EC2](https://aws.amazon.com/ec2/pricing/on-demand/)
pricing for ap-south-1 before running it. New AWS accounts get promotional credits, which may cover
it. **Always destroy the cluster afterwards.**

## Steps

```bash
# 0. AWS CLI configured for your account (aws configure / SSO). Region: ap-south-1 by default.
terraform -chdir=infra/aws init
terraform -chdir=infra/aws apply                       # about 15 minutes

# 1. Push the jobq image to ECR.
REPO=$(terraform -chdir=infra/aws output -raw ecr_repository_url)
aws ecr get-login-password | docker login --username AWS --password-stdin ${REPO%%/*}
TAG=$(git -C ../Distributed-Job-Scheduler rev-parse --short HEAD)
docker build --platform linux/amd64 -t $REPO:$TAG ../Distributed-Job-Scheduler && docker push $REPO:$TAG

# 2. Install the platform with the same stage as locally.
$(terraform -chdir=infra/aws output -raw kubeconfig_command)
terraform -chdir=infra/local/platform workspace new aws      # separate state from the local cluster
terraform -chdir=infra/local/platform apply \
  -var environment=aws -var kubeconfig_path=$HOME/.kube/config \
  -var kube_context=$(kubectl config current-context) \
  -var jobq_image_repository=$REPO -var jobq_image_tag=$TAG

# 3. The gateway is an AWS network load balancer:
kubectl -n traefik get svc traefik          # EXTERNAL-IP; send Host: jobq.localhost or change gateway.host

# 4. Tear down (platform first, so the load balancer and volumes are released).
terraform -chdir=infra/local/platform destroy -var environment=aws ...
terraform -chdir=infra/aws destroy
```

With `environment=aws` the platform stage swaps the NodePort for a LoadBalancer service (NLB),
drops metrics-server's `--kubelet-insecure-tls`, and makes gp3 the default storage class.

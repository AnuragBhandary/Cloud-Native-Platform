# Local platform: a five-node kind cluster with everything installed by Terraform.
SCHEDULER_REPO ?= ../Distributed-Job-Scheduler
JOBQ_TAG       ?= $(shell git -C $(SCHEDULER_REPO) rev-parse --short HEAD)
TF_CLUSTER      = terraform -chdir=infra/local/cluster
TF_PLATFORM     = terraform -chdir=infra/local/platform

.PHONY: up image cluster platform down status load chaos-node chaos-db

up: image cluster platform   ## build the jobq image, create the cluster, install everything

image:                       ## build jobq from the scheduler repo, tagged with its commit
	docker build -q -t jobq:$(JOBQ_TAG) $(SCHEDULER_REPO)

cluster:                     ## stage 1: the kind cluster (and load the jobq image into it)
	$(TF_CLUSTER) init -input=false -upgrade=false >/dev/null
	$(TF_CLUSTER) apply -input=false -auto-approve -var jobq_image_tag=$(JOBQ_TAG)

platform:                    ## stage 2: add-ons, monitoring, gateway, jobq
	$(TF_PLATFORM) init -input=false -upgrade=false >/dev/null
	$(TF_PLATFORM) apply -input=false -auto-approve -var jobq_image_tag=$(JOBQ_TAG) \
		-var kubeconfig_path=$$($(TF_CLUSTER) output -raw kubeconfig_path)

down:                        ## delete the cluster (and with it everything in it)
	$(TF_CLUSTER) destroy -input=false -auto-approve -var jobq_image_tag=$(JOBQ_TAG)
	rm -f infra/local/platform/terraform.tfstate*

status:
	kubectl --context kind-platform get nodes -L pool
	kubectl --context kind-platform -n jobq get pods -o wide

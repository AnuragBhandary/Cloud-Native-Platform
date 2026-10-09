# Interview guide

How to learn this repository and defend it in a DevOps, SRE, platform or backend interview. I
(Claude) wrote it; the point of this guide is that you can explain and change any part of it
yourself. Numbers: [BENCHMARKS.md](BENCHMARKS.md). Reasoning: [DESIGN.md](DESIGN.md).

## 1. Learning path

| # | File | Be able to explain afterwards |
|---|---|---|
| 1 | `Makefile`, `infra/local/cluster/main.tf` | The two stages; node pools; why the jobs nodes are tainted; loading a local image into kind |
| 2 | `infra/local/platform/addons.tf`, `values/*.yaml` | What each add-on does; why every chart is pinned; why the Gateway API CRDs are manifests |
| 3 | `charts/jobq/values.yaml`, `templates/_helpers.tpl` | Every value; the shared env; `enableServiceLinks`; why migrations bypass PgBouncer |
| 4 | `charts/jobq/templates/worker.yaml` | Tolerations (taint + node failure), grace period, the KEDA ScaledObject and its HPA behaviour |
| 5 | `charts/jobq/templates/postgres.yaml` | CloudNativePG Cluster, failover, the Pooler and transaction pooling |
| 6 | `charts/jobq/templates/monitoring.yaml` | ServiceMonitor vs PodMonitor; the SLO recording rules; burn-rate maths |
| 7 | `load/experiment.py`, `load/enqueue.py` | Open-loop load; the audit query; what "exactly once" means here |
| 8 | `infra/aws/main.tf`, `docs/AWS.md` | VPC layout, EKS node groups, Pod Identity for the EBS driver, what it costs |
| 9 | `.github/workflows/ci.yml` | What CI proves on every push |

**Kubernetes basics to be solid on:** Pod, Deployment, StatefulSet, Service (ClusterIP, NodePort,
LoadBalancer), PersistentVolumeClaim and StorageClass, ConfigMap and Secret, probes (readiness vs
liveness), requests vs limits (and what OOMKilled / exit 137 means), taints and tolerations vs
nodeSelector vs affinity, PodDisruptionBudget, HPA, operators and CRDs, Gateway API vs Ingress.

**Do these by hand before an interview** (no AI):
1. Add a `deploy` Make target that bumps the chart version and runs the platform stage.
2. Change the pickup SLO to 99.5% within 10 s. Which recording rule and which alert thresholds
   change, and to what? (Budget 0.5%: page at 14.4 × 0.005 = 0.072.)
3. Kill the PostgreSQL primary pod during a load run (`kubectl delete pod`) and find, in Grafana
   and in the audit, what happened.

## 2. The 60-second pitch

> "I took my distributed job queue and built the platform to run it in production style. Terraform
> creates a five-node Kubernetes cluster with separate system and job node pools and installs
> everything on it: the CloudNativePG operator for a highly available Postgres behind PgBouncer,
> KEDA, Prometheus and Grafana, and a Gateway API gateway. The app is a Helm chart. Workers autoscale
> with KEDA on the Redis stream's consumer-group lag, which is exactly the work no worker has room
> for. I defined two SLOs with multi-window burn-rate alerts. Then I load-tested it: 20,000 jobs at
> 400 a second scaled workers from 1 to 10, and killing a worker node mid-run lost nothing; 117 jobs
> were taken over and every job's side effect was committed exactly once. The first version of
> that test OOM-killed the database. The autoscaled workers opened too many connections, so I added
> PgBouncer, and connections now stay flat however many workers run."

## 3. Questions you'll get

**Why KEDA and not a CPU-based HPA for workers?**
Workers mostly wait on I/O and sleep in tasks; CPU doesn't track the backlog. The stream lag does,
and because workers only read what they can run, lag means "nobody has room for this".

**What happens when a node dies?**
Kubernetes takes about 50 s to mark it NotReady, then the 15 s toleration evicts its pods. jobq
doesn't wait for that. Each running job has a 10 s lease that its worker heartbeats; when the
heartbeats stop, the scheduler's reaper re-queues the job. If the dead worker somehow wrote later,
its fencing token would be stale and the write rejected. Measured: 117 jobs taken over, 0 duplicates.

**Why did the database crash and why PgBouncer?**
Connections scale with replicas: 10 workers × a pool of 20, plus the rest, passed 100 backends,
each costing memory, and the primary was OOM-killed. A pooler puts a fixed number of server
connections behind any number of clients. Transaction mode is safe for jobq because nothing uses
session state; migrations, which use a session advisory lock, connect directly.

**What did failover look like?**
CloudNativePG promoted the replica by itself; the app's connections failed, its pools reconnected
through the Service that now points at the new primary, and clients retried with idempotency keys.
Of 18,832 accepted jobs, none was lost or duplicated.

**Explain your SLO alerts.**
Error budget 1% for a 99% SLO. A burn rate of 14.4 spends 2% of a 30-day budget in an hour, so page
when both the 1 h and the 5 m windows exceed 14.4 × 1%. The 5 m window stops the page soon after
recovery. Ticket at 6× over 6 h and 30 m. And I fixed a bug where an idle window counted as 100%
errors.

**Why two Terraform stages?**
The Kubernetes and Helm providers need a cluster to plan against. Configured from a cluster
created in the same apply, they can't plan when that cluster must be replaced. Separate state
also matches how teams split infrastructure and platform ownership.

**Why Gateway API and not Ingress?**
It's the successor to Ingress, with roles split between platform and app teams (Gateway vs
HTTPRoute), and it's portable across implementations. ingress-nginx has been retired.

**How would this run on AWS?**
`infra/aws`: VPC with private subnets and one NAT gateway, EKS with the same two node groups (the
jobs one tainted), EBS CSI via Pod Identity, ECR. The same platform stage installs on it with
`environment=aws`. Next would be Karpenter for node autoscaling and OIDC-based deploys from CI.

**What would you change for production?**
GitOps (Argo CD) for the app layer, Karpenter, PostgreSQL backups to S3 (CloudNativePG supports it),
more than one Redis or a managed one, OpenTelemetry tracing, alert routing to a pager.

## 4. Stories (STAR)

- **Dive Deep / Earn Trust:** the load test OOM-killed the database. I didn't just raise the memory
  limit. I found the cause in Prometheus (backends past 100 at 10 workers), verified that failover
  lost no jobs, and fixed the root cause with a pooler.
- **Insist on the Highest Standards:** the SLO alert kept firing after the test ended. I traced it
  to idle windows counting as total failure and fixed the rule so no traffic means no data.
- **Bias for Action / Ownership:** "every jobq pod fails to start" turned out to be Kubernetes service
  links overriding the app's own config (`JOBQ_API_PORT=tcp://...`). Found from the error message,
  fixed with one setting, and documented.

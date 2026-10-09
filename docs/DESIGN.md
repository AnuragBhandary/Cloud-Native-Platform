# Design

## 1. Goals

Run jobq, a job queue whose guarantees were already tested in Docker Compose, the way a production
team would: reproducible infrastructure, autoscaling, high availability, monitoring with SLOs. Then
prove the guarantees still hold when the infrastructure fails underneath it.

## 2. Two Terraform stages

`infra/local/cluster` creates the kind cluster. `infra/local/platform` installs everything inside
it, connecting with the kubeconfig the first stage writes. They are separate applies because a
provider (Helm, Kubernetes) configured from a resource in the *same* configuration can't plan once
that resource must be replaced: changing the node layout failed with "Failed to get RESTMapper
client". HashiCorp's guidance is to split them, and the Makefile runs them in order.

Inside the platform stage, anything whose *kind* doesn't exist before the apply (HTTPRoutes,
before the Gateway API CRDs are installed) goes in a Helm chart rather than `kubernetes_manifest`,
because `kubernetes_manifest` needs the kind to exist at plan time. The Gateway API CRDs themselves
are vendored at a pinned version (v1.6.3) and applied as manifests: as a Helm release they exceeded
the 1 MB limit on Helm's release secret.

Every chart is pinned to an exact version. The local chart's version is bumped on every change,
because the Helm provider only notices a local chart change when its version changes.

## 3. Node pools

| Pool | Nodes | Runs |
|---|---|---|
| system | 2 | API, schedulers, PostgreSQL primary + replica, PgBouncer, Redis, gateway, monitoring, operators |
| jobs | 2, tainted `dedicated=jobs:NoSchedule` | workers only (they tolerate the taint) |

The taint, rather than a nodeSelector on everything else, keeps every chart (operators, monitoring)
off the jobs nodes without editing each one. So the failure experiment can kill a jobs node and
lose only workers. Workers tolerate `not-ready`/`unreachable` for 15 s instead of the default
5 minutes, so their pods are replaced sooner. In practice jobq recovers the work even sooner, through
its own leases (see BENCHMARKS.md).

## 4. Autoscaling

- **Workers: KEDA on the Redis stream's consumer-group lag.** jobq workers read with `XREADGROUP
  COUNT <free slots> NOACK`, so the stream's lag is precisely work no worker has room for. One
  replica per 32 waiting jobs (a worker's concurrency), 1 to 10 replicas. Scale up at up to 100%
  every 15 s with no stabilisation window; scale down 2 pods every 30 s after 60 s stable, so a
  brief lull doesn't throw away capacity.
- **Why not CPU?** Workers spend their time waiting on I/O; CPU says nothing about the backlog.
- **Why not Prometheus as the trigger?** It works, but adds the scrape interval (15 s) and rule
  evaluation to the reaction time and makes scaling depend on the monitoring stack. KEDA reads Redis
  directly every 5 s.
- **API: HPA on CPU** (2 to 4 replicas), which needs metrics-server (kind doesn't ship it).

## 5. PostgreSQL: CloudNativePG and PgBouncer

CloudNativePG runs a primary and a streaming replica, on different nodes by pod anti-affinity, and
promotes the replica if the primary dies. The app reads its credentials from the secret the
operator generates.

**The connection fan-out.** The first autoscaling test OOM-killed the primary. Each jobq process
has a connection pool of up to 20; with KEDA at 10 workers plus the API and schedulers, PostgreSQL
passed 100 backends and its 768 MiB limit. Raising the limit only moves the cliff, because each extra
worker can add 20 more connections. So the app now connects through a CloudNativePG `Pooler`:
PgBouncer in **transaction** mode, two instances, 25 server connections each. However many workers
run, PostgreSQL sees a fixed pool (67 backends at peak, including replication and the operator's
own), and memory stays well inside a 1 GiB limit.

Transaction pooling is safe for jobq because every query is a single statement or an explicit
transaction; nothing relies on session state. The two exceptions were handled:
- **Prepared statements:** asyncpg uses named prepared statements, which PgBouncer supports across
  server connections with `max_prepared_statements` set.
- **Migrations** hold a session-level advisory lock, which transaction pooling can't keep, so the
  migrate init containers connect to the primary directly.

## 6. Monitoring and SLOs

kube-prometheus-stack, with selectors opened so it picks up every ServiceMonitor, PodMonitor and
PrometheusRule in the cluster. The chart ships monitors for the API, schedulers, workers, PostgreSQL
and PgBouncer.

| SLO | Indicator | Objective |
|---|---|---|
| Pickup | job claimed by a worker within 5 s of becoming due (`jobq_queue_delay_seconds`) | 99% |
| Enqueue | API accepts a job within 100 ms (`jobq_enqueue_seconds`) | 99% |

Error ratios are recorded over 5 m, 30 m, 1 h and 6 h windows. Alerts follow the Google SRE
workbook's multi-window, multi-burn-rate method: **page** when both the 1 h and 5 m windows burn the
budget at 14.4× (2% of a 30-day budget in an hour), **ticket** at 6× over 6 h and 30 m. The short
window makes alerts stop soon after the problem does.

**A bug the tests caught:** the first recording rules computed `1 - good / max(total, ε)`, so an
idle queue (no jobs in the window) became a 100% error ratio and kept paging after the load test
ended. They now compute `(total - good) / (total > 0)`: no traffic gives no data, not total failure.
Also alerted: dead letters, workers pinned at the maximum, and a backlog growing for 10 minutes.

## 7. Security and hardening in the chart

Non-root containers with a read-only root filesystem, all capabilities dropped and the
`RuntimeDefault` seccomp profile; `enableServiceLinks: false` (see §8); PodDisruptionBudget for the
API; graceful shutdown (workers finish or release their jobs on SIGTERM within 25 s, and the pod
gives them 40 s). Secrets come from the operator, not from values files. The dev API key in
values.yaml is for the local cluster only.

## 8. Things that went wrong, and why

| Symptom | Cause | Fix |
|---|---|---|
| Every jobq pod failed: `api_port: unable to parse 'tcp://10.96...:8000'` | Kubernetes injects Docker-style variables for every Service; the `jobq-api` Service became `JOBQ_API_PORT`, which jobq reads as its own setting | `enableServiceLinks: false` |
| PostgreSQL primary OOM-killed under load | connection fan-out from autoscaled workers | PgBouncer (transaction pooling), 1 GiB limit |
| Traefik release "failed" although it ran | service type was `LoadBalancer` (wrong values key), and Helm waited for an external IP kind never assigns | `service.spec.type: NodePort` |
| KEDA release failed on a fresh cluster | the operator restarts while issuing webhook certificates, longer than Helm's 5-minute wait | 10-minute timeout |
| Monitoring pods failing with "no space left on device" | Docker VM disk full | pruned caches; Colima disk 40 GB → 80 GB |
| SLO alert firing on an idle system | idle window treated as 100% errors | see §6 |
| Load generator hung after the database crash | requests on dead connections outlived httpx's timeout | hard per-attempt deadline |

## 9. Next steps

- Apply the AWS stage for a short test run (docs/AWS.md), then add GitHub Actions deploying to it
  via OIDC (no stored AWS keys).
- GitOps with Argo CD instead of `terraform apply` for the application layer.
- Cluster autoscaling (Karpenter on EKS), so KEDA's extra workers get nodes when the jobs pool is
  full.
- OpenTelemetry traces from enqueue to completion.

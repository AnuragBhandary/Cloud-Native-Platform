# Benchmarks

## Environment

| | |
|---|---|
| Machine | MacBook Pro, Apple M5 Pro, 24 GB RAM; Docker in a Colima VM (12 vCPU, 12 GiB) |
| Cluster | kind, Kubernetes 1.35: control plane, 2 system nodes, 2 tainted jobs nodes |
| jobq | 2 API replicas, 2 schedulers, workers 1 to 10 (32 concurrent jobs each, 10 s leases) |
| Database | CloudNativePG: primary + replica (1 GiB limit), 2 PgBouncer instances (transaction mode) |

Everything, the load generator included, shares one laptop.

## Method

`load/experiment.py` runs `load/enqueue.py` inside the cluster as a Kubernetes Job on a system node.
It sends N `examples.ledger` jobs **open loop** at a fixed rate, each with an Idempotency-Key, and
retries through errors. Each job sleeps for its work time, then writes one row to `example_ledger`
in the same transaction as its fenced completion. Every 5 s the runner records the backlog, worker
replicas, jobs in flight, PostgreSQL connections and memory from Prometheus. For failure runs, it
`docker stop`s the jobs node running the most workers: the node simply vanishes, with no drain.

When every job has finished, it audits PostgreSQL: each job must have succeeded and have **exactly
one** ledger row, however many times it ran. Raw timelines and summaries are in `load/results/`.

## Results

| | Autoscaling | Node failure |
|---|---|---|
| Run | `r1009-180602-autoscale` | `r1009-181022-node-kill` |
| Load | 20,000 jobs, 400/s for 50 s, 500 ms each | same |
| Failure | none | `platform-worker3` stopped at 42 s (4 of 8 workers on it), back at 131 s |
| Accepted / retries | 20,000 / 0 | 20,000 / 0 |
| Enqueue latency (client) | p50 1.8 ms, p95 4.5 ms, p99 12.2 ms | p50 2.0 ms, p95 6.4 ms, p99 24.8 ms |
| Workers | 1 → 10 (first scale-out at ~26 s) → 1 after 250 s | 1 → 10 → 1 after 261 s |
| Backlog drained | 67.7 s | 84.0 s |
| Succeeded, one side effect each | **20,000** | **20,000** |
| Ran more than once (taken over) | 0 | **117** |
| Lost / duplicated effects | **0 / 0** | **0 / 0** |
| PostgreSQL connections (peak) | 67 | 67 |
| PostgreSQL memory (peak) | 505 MiB | 654 MiB |

**What the node failure shows.** Kubernetes reported the dead node's four workers as ready until
about 94 s, some 50 s after the node vanished, because that's how long it takes to declare a node
NotReady. jobq didn't need to wait: those workers' 10-second leases lapsed, the scheduler's reaper
re-queued their 117 jobs, and the surviving workers finished the backlog at 84 s, 16 s later than
without the failure. Writes the dead workers attempted afterwards were fenced (rejected), which
shows on the dashboard's throughput panel as a small "fenced" series. No job's side effect was
committed twice.

**Throughput ceiling.** Ten workers peaked at about 270 completed jobs/s, below the 400/s offered,
so the backlog kept growing until the arrivals stopped. Ten workers of 32 slots at 500 ms each
could in theory do 640/s; on this laptop they share 12 vCPUs with the database, the pooler, the
monitoring stack and the load generator.

**SLOs during the tests.** These runs deliberately offer 6× one worker's capacity, so jobs wait for
scale-out and the pickup SLO (99% within 5 s) is violated. Its fast-burn alert fired (page) and the
slow-burn alert fired (ticket), as designed. The enqueue SLO held: 99.87% of enqueues in the hour
under 100 ms.

## The run that crashed the database

The first 20,000-job run (before PgBouncer) passed 100 PostgreSQL connections at 10 workers. The
primary was **OOM-killed** (exit 137) at its 768 MiB limit. CloudNativePG promoted the replica on its
own, and the old primary rejoined as a replica.

| Audit of the jobs accepted before the crash | |
|---|---|
| Jobs accepted | 18,832 |
| Succeeded | 18,832 |
| Ran more than once | 271 |
| Lost / duplicated effects | **0 / 0** |

The load generator itself hung after the crash: requests on connections that died mid-failover
outlived httpx's timeout. That's why only 18,832 of 20,000 were sent. It now has a hard per-attempt
deadline, and the database has a connection pooler (DESIGN.md §5).

## Building from nothing

`make down && make up` on the laptop above: cluster, Gateway API CRDs, CloudNativePG,
metrics-server, kube-prometheus-stack, KEDA, Traefik, routes and jobq, with no manual steps, in
**598 s**, after which an enqueue through the gateway succeeded. Docker images were already cached
locally; a cold machine also downloads them.

## CI

On every push, CI builds the whole platform on a GitHub runner, runs 4,000 jobs at 150/s with a
jobs node killed at 25 s, and fails if the audit finds any lost, failed or duplicated job. The same
run locally: 4,000/4,000 succeeded, 22 taken over, 0 duplicates.

## Reproduce

```bash
make up
python3 load/experiment.py --jobs 20000 --rate 400 --work-ms 500 --label autoscale
python3 load/experiment.py --jobs 20000 --rate 400 --work-ms 500 --kill-node-at 40 --restore-node-at 130 --label node-kill
```

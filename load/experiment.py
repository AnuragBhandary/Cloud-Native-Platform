"""Autoscaling + node-failure experiment against the local platform.

    python3 load/experiment.py --jobs 20000 --rate 400 --work-ms 500 --kill-node-at 60 --restore-node-at 150

1. Runs load/enqueue.py inside the cluster (a Kubernetes Job pinned to a system node).
2. Every 5 s records queued jobs, worker replicas and jobs in flight (from Prometheus) to a
   timeline, and which jobs node runs how many workers (from the API server).
3. At --kill-node-at seconds, stops the jobs node running the most workers (docker stop: the
   node vanishes, no graceful drain); starts it again at --restore-node-at.
4. When every job has finished, audits PostgreSQL: each job must have succeeded and have
   exactly one example_ledger row (its side effect), however often it ran.
5. Waits for KEDA to scale workers back down, then writes load/results/<run>.json and .csv.
"""

import argparse
import csv
import json
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path

CTX = "kind-platform"
NS = "jobq"
PROM = "http://prometheus.localhost:8088"
HERE = Path(__file__).resolve().parent


def sh(*args: str, input: str | None = None) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True, input=input).stdout.strip()


def kubectl(*args: str, input: str | None = None) -> str:
    return sh("kubectl", "--context", CTX, "-n", NS, *args, input=input)


def prom(query: str) -> float | None:
    url = f"{PROM}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    try:
        result = json.load(urllib.request.urlopen(url, timeout=5))["data"]["result"]
        return float(result[0]["value"][1]) if result else 0.0
    except Exception:
        return None


def sql(query: str) -> str:
    primary = kubectl("get", "pod", "-l", "cnpg.io/cluster=jobq-db,cnpg.io/instanceRole=primary", "-o", "name")
    return kubectl("exec", primary, "-c", "postgres", "--", "psql", "-U", "postgres", "-d", "jobq", "-tAF,", "-c", query)


def workers_per_node() -> dict[str, int]:
    out = kubectl("get", "pods", "-l", "app.kubernetes.io/name=jobq-worker", "--field-selector=status.phase=Running",
                  "-o", "jsonpath={range .items[*]}{.spec.nodeName}{'\\n'}{end}")
    counts: dict[str, int] = {}
    for node in filter(None, out.splitlines()):
        counts[node] = counts.get(node, 0) + 1
    return counts


def job_manifest(run_id: str, args: argparse.Namespace, image: str) -> str:
    return json.dumps({
        "apiVersion": "batch/v1", "kind": "Job",
        "metadata": {"name": f"load-{run_id}", "labels": {"app": "load"}},
        "spec": {"backoffLimit": 0, "template": {"spec": {
            "restartPolicy": "Never", "enableServiceLinks": False,
            "nodeSelector": {"pool": "system"},
            "containers": [{
                "name": "load", "image": image, "command": ["python", "/load/enqueue.py"],
                "env": [{"name": k, "value": str(v)} for k, v in {
                    "API_KEY": "jq_0000000000de_local-dev-key-not-for-production", "N": args.jobs,
                    "RATE": args.rate, "WORK_MS": args.work_ms, "RUN_ID": run_id}.items()],
                "volumeMounts": [{"name": "script", "mountPath": "/load"}],
            }],
            "volumes": [{"name": "script", "configMap": {"name": "load-script"}}],
        }}},
    })


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--jobs", type=int, default=20000)
    p.add_argument("--rate", type=float, default=400)
    p.add_argument("--work-ms", type=float, default=500)
    p.add_argument("--kill-node-at", type=float, default=None, help="seconds after start; omit for no chaos")
    p.add_argument("--restore-node-at", type=float, default=None)
    p.add_argument("--label", default="")
    p.add_argument("--max-seconds", type=float, default=1800)
    args = p.parse_args()

    run_id = time.strftime("r%m%d-%H%M%S")
    image = kubectl("get", "deploy", "jobq-api", "-o", "jsonpath={.spec.template.spec.containers[0].image}")
    kubectl("create", "configmap", "load-script", f"--from-file=enqueue.py={HERE / 'enqueue.py'}",
            "--dry-run=client", "-o", "yaml")  # validate
    sh("sh", "-c", f"kubectl --context {CTX} -n {NS} create configmap load-script --from-file=enqueue.py={HERE / 'enqueue.py'} "
                   f"--dry-run=client -o yaml | kubectl --context {CTX} -n {NS} apply -f -")
    kubectl("apply", "-f", "-", input=job_manifest(run_id, args, image))
    start = time.time()
    print(f"run {run_id}: {args.jobs} jobs at {args.rate}/s, {args.work_ms} ms each")

    timeline, events = [], []
    killed = None
    finished_at = None
    while True:
        t = round(time.time() - start, 1)
        if args.kill_node_at is not None and killed is None and t >= args.kill_node_at:
            per_node = {n: c for n, c in workers_per_node().items() if n.startswith("platform-worker")}
            killed = max(per_node, key=per_node.get)
            sh("docker", "stop", "-t", "0", killed)
            events.append({"t": t, "event": f"stopped node {killed} (running {per_node[killed]} of {sum(per_node.values())} workers)"})
            print(events[-1])
        if killed and args.restore_node_at is not None and t >= args.restore_node_at and not any(e["event"].startswith("restored") for e in events):
            sh("docker", "start", killed)
            events.append({"t": t, "event": f"restored node {killed}"})
            print(events[-1])
        row = {
            "t": t,
            "queued": prom('sum(jobq_jobs{status="queued"})'),
            "running": prom('sum(jobq_jobs{status="running"})'),
            "succeeded_total": prom('sum(jobq_jobs{status="succeeded"})'),
            "worker_replicas": prom('kube_deployment_status_replicas{deployment="jobq-worker"}'),
            "workers_ready": prom('kube_deployment_status_replicas_ready{deployment="jobq-worker"}'),
            "inflight": prom("sum(jobq_worker_inflight)"),
            "db_backends": prom('max(sum by (pod) (cnpg_backends_total{namespace="jobq"}))'),
            "db_memory_mib": prom('max(container_memory_working_set_bytes{namespace="jobq",container="postgres"}) / 1048576'),
        }
        row["per_node"] = json.dumps(workers_per_node())
        timeline.append(row)
        try:
            done = sql(f"SELECT count(*) FILTER (WHERE status IN ('succeeded','dead')) FROM jobs WHERE idempotency_key LIKE '{run_id}-%'")
        except subprocess.CalledProcessError:
            done = "0"  # e.g. the primary is restarting or failing over; try again next tick
        if finished_at is None and int(done or 0) >= args.jobs:
            finished_at = t
            print(f"all jobs finished at {t}s")
        if finished_at is not None and (row["worker_replicas"] or 0) <= 1 and t - finished_at > 30:
            break
        if t > args.max_seconds:
            print("timed out")
            break
        time.sleep(5)

    if killed and not any(e["event"].startswith("restored") for e in events):
        sh("docker", "start", killed)
    for _ in range(120):  # the load job prints its summary when every send has finished
        if kubectl("get", "job", f"load-{run_id}", "-o", "jsonpath={.status.succeeded}") == "1":
            break
        time.sleep(5)
    load = json.loads(kubectl("logs", f"job/load-{run_id}").splitlines()[-1])
    audit_row = sql(f"""
        WITH j AS (SELECT id, status, attempts FROM jobs WHERE idempotency_key LIKE '{run_id}-%'),
             l AS (SELECT job_id, count(*) AS n FROM example_ledger WHERE job_id IN (SELECT id FROM j) GROUP BY job_id)
        SELECT (SELECT count(*) FROM j),
               (SELECT count(*) FROM j WHERE status = 'succeeded'),
               (SELECT count(*) FROM j WHERE status = 'dead'),
               (SELECT count(*) FROM j WHERE attempts > 1),
               (SELECT coalesce(sum(n), 0) FROM l),
               (SELECT count(*) FROM j WHERE id NOT IN (SELECT job_id FROM l)),
               (SELECT count(*) FROM l WHERE n > 1)""").split(",")
    keys = ["jobs", "succeeded", "dead", "ran_more_than_once", "ledger_rows", "jobs_without_effect", "jobs_with_duplicate_effects"]
    audit = dict(zip(keys, map(int, audit_row)))
    replicas = [r["worker_replicas"] for r in timeline if r["worker_replicas"] is not None]
    backends = [r["db_backends"] for r in timeline if r["db_backends"] is not None]
    memory = [r["db_memory_mib"] for r in timeline if r["db_memory_mib"] is not None]
    first_scale = next((r["t"] for r in timeline if (r["worker_replicas"] or 0) > 1), None)
    result = {
        "run_id": run_id, "label": args.label, "params": vars(args), "load": load, "audit": audit, "events": events,
        "drained_seconds": finished_at, "peak_worker_replicas": max(replicas, default=None),
        "first_scale_up_seconds": first_scale,
        "peak_db_backends": max(backends, default=None),
        "peak_db_memory_mib": round(max(memory, default=0), 1),
        "scaled_back_to_min_seconds": timeline[-1]["t"],
    }
    out = HERE / "results" / f"{run_id}{'-' + args.label if args.label else ''}"
    out.with_suffix(".json").write_text(json.dumps(result, indent=2) + "\n")
    with out.with_suffix(".csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(timeline[0]))
        w.writeheader()
        w.writerows(timeline)
    kubectl("delete", "job", f"load-{run_id}", "--wait=false")
    ok = (audit["jobs"] == args.jobs and audit["succeeded"] == args.jobs and audit["dead"] == 0
          and audit["jobs_without_effect"] == 0 and audit["jobs_with_duplicate_effects"] == 0)
    result["audit_passed"] = ok
    out.with_suffix(".json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ("load", "audit", "events", "drained_seconds", "peak_worker_replicas",
                                               "first_scale_up_seconds", "peak_db_backends", "peak_db_memory_mib",
                                               "scaled_back_to_min_seconds", "audit_passed")}, indent=2))
    if not ok:
        raise SystemExit("audit failed: some jobs were lost, failed or committed twice")


if __name__ == "__main__":
    main()

"""Generates charts/jobq/dashboards/jobq.json (the Grafana dashboard the chart provisions).

    python3 dashboards/build_jobq_dashboard.py
"""

import json
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "charts" / "jobq" / "dashboards" / "jobq.json"
PROM = {"type": "prometheus", "uid": "prometheus"}

panels = []


def panel(title, targets, x, y, w=12, h=8, kind="timeseries", unit=None, **extra):
    p = {
        "id": len(panels) + 1, "type": kind, "title": title, "datasource": PROM,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [{"refId": chr(65 + i), "expr": e, "legendFormat": l, "datasource": PROM} for i, (e, l) in enumerate(targets)],
        "fieldConfig": {"defaults": {"unit": unit} if unit else {}, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom"}},
    }
    p.update(extra)
    panels.append(p)


def stat(title, expr, x, unit="percentunit", thresholds=None):
    panel(title, [(expr, "")], x, 0, w=6, h=4, kind="stat", unit=unit,
          options={"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
          fieldConfig={"defaults": {"unit": unit, "decimals": 2, "thresholds": {"mode": "absolute", "steps": thresholds or []}}, "overrides": []})


green_above = lambda t: [{"color": "red", "value": None}, {"color": "green", "value": t}]
stat("Pickup SLO, last hour (target 99% within 5 s)", "1 - jobq:slo_pickup_errors:ratio_rate1h", 0, thresholds=green_above(0.99))
stat("Enqueue SLO, last hour (target 99% under 100 ms)", "1 - jobq:slo_enqueue_errors:ratio_rate1h", 6, thresholds=green_above(0.99))
stat("Queued jobs", 'sum(jobq_jobs{status="queued"})', 12, unit="short")
stat("Worker replicas", 'sum(kube_deployment_status_replicas{deployment=~".*-worker"})', 18, unit="short")

panel("Jobs by status", [('sum by (status) (jobq_jobs)', "{{status}}")], 0, 4, unit="short")
panel("Throughput (attempts/s by outcome)", [('sum by (outcome) (rate(jobq_jobs_finished_total[1m]))', "{{outcome}}")], 12, 4, unit="ops")
panel("Pickup delay (due -> claimed)", [
    (f'histogram_quantile({q}, sum by (le) (rate(jobq_queue_delay_seconds_bucket[2m])))', f"p{int(q * 100)}")
    for q in (0.5, 0.95, 0.99)], 0, 12, unit="s")
panel("Enqueue latency", [
    (f'histogram_quantile({q}, sum by (le) (rate(jobq_enqueue_seconds_bucket[2m])))', f"p{int(q * 100)}")
    for q in (0.5, 0.95, 0.99)], 12, 12, unit="s")
panel("Workers vs in-flight jobs", [
    ('sum(kube_deployment_status_replicas{deployment=~".*-worker"})', "worker replicas"),
    ('sum(jobq_worker_inflight)', "jobs running"),
], 0, 20, unit="short")
panel("Error-budget burn rate (1 h window; 14.4 pages)", [
    ("jobq:slo_pickup_errors:ratio_rate1h / 0.01", "pickup"),
    ("jobq:slo_enqueue_errors:ratio_rate1h / 0.01", "enqueue"),
], 12, 20, unit="short")
panel("Recoveries", [
    ('sum by (outcome) (rate(jobq_reaped_total[2m]))', "reaped {{outcome}}"),
    ('sum(rate(jobq_redispatched_total[2m]))', "re-dispatched"),
    ('sum(rate(jobq_leases_lost_total[2m]))', "leases lost"),
], 0, 28, unit="ops")
panel("PostgreSQL connections (CloudNativePG)", [('sum by (pod) (cnpg_backends_total)', "{{pod}}")], 12, 28, unit="short")

dashboard = {
    "uid": "jobq", "title": "jobq: queue, workers and SLOs", "schemaVersion": 39, "version": 1,
    "time": {"from": "now-30m", "to": "now"}, "refresh": "10s", "tags": ["jobq"], "panels": panels,
}
OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"wrote {OUT} ({len(panels)} panels)")

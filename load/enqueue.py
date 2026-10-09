"""Open-loop load generator, run inside the cluster as a Kubernetes Job (see experiment.py).

Sends N `examples.ledger` jobs at a fixed RATE regardless of how fast the API answers (open
loop, so a slow server can't slow the test down and hide its own latency). Every job carries an
Idempotency-Key, so retries through failures can never create a second job. Prints one JSON line
with the client-side results at the end.
"""

import asyncio
import json
import os
import random
import statistics
import time

import httpx

API = os.environ.get("API", "http://jobq-api.jobq:8000")
KEY = os.environ["API_KEY"]
N = int(os.environ.get("N", "20000"))
RATE = float(os.environ.get("RATE", "400"))
WORK_MS = float(os.environ.get("WORK_MS", "500"))
RUN_ID = os.environ["RUN_ID"]

latencies: list[float] = []
retries = 0
failed = 0


async def send(client: httpx.AsyncClient, i: int) -> None:
    global retries, failed
    body = {"task": "examples.ledger", "args": [i], "kwargs": {"work_ms": WORK_MS}, "max_attempts": 5}
    headers = {"Idempotency-Key": f"{RUN_ID}-{i}"}
    for attempt in range(60):
        start = time.perf_counter()
        try:
            # A hard deadline per attempt: during a database failover, connections can die in a
            # way that leaves an httpx request waiting past its own timeout.
            r = await asyncio.wait_for(client.post("/v1/jobs", json=body, headers=headers), 15)
            if r.status_code in (200, 201):
                latencies.append(time.perf_counter() - start)
                return
            if r.status_code < 500 and r.status_code != 429:
                raise RuntimeError(f"job {i}: HTTP {r.status_code} {r.text[:200]}")
        except (httpx.HTTPError, asyncio.TimeoutError):
            pass
        retries += 1
        await asyncio.sleep(min(2.0, 0.1 * 2**attempt) * random.random())
    failed += 1


async def progress(t0: float) -> None:
    while True:
        await asyncio.sleep(5)
        print(json.dumps({"t": round(time.perf_counter() - t0), "accepted": len(latencies), "retries": retries, "failed": failed}), flush=True)


async def main() -> None:
    limits = httpx.Limits(max_connections=200, max_keepalive_connections=200)
    async with httpx.AsyncClient(base_url=API, headers={"X-API-Key": KEY}, timeout=10, limits=limits) as client:
        t0 = time.perf_counter()
        reporter = asyncio.create_task(progress(t0))
        tasks = []
        for i in range(N):
            delay = t0 + i / RATE - time.perf_counter()
            if delay > 0:
                await asyncio.sleep(delay)
            tasks.append(asyncio.create_task(send(client, i)))
        await asyncio.gather(*tasks)
        took = time.perf_counter() - t0
        reporter.cancel()
    q = statistics.quantiles(latencies, n=100) if len(latencies) > 1 else [0] * 99
    print(json.dumps({
        "run_id": RUN_ID, "jobs": N, "accepted": len(latencies), "failed": failed, "retries": retries,
        "target_rate": RATE, "achieved_rate": round(len(latencies) / took, 1), "seconds": round(took, 1),
        "enqueue_ms": {"p50": round(q[49] * 1000, 2), "p95": round(q[94] * 1000, 2), "p99": round(q[98] * 1000, 2)},
    }))


asyncio.run(main())

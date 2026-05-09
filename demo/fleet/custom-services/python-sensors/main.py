"""Tiny FastAPI service — fake home-sensor readings for the fleet demo.

Picked to look like the kind of small Python API a homelab user would write
to expose a Pi-Zero's BME280 over HTTP. /sensors returns deterministically
varying values so screenshots and time-series charts have visible movement.
"""
import math
import random
import time

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, PlainTextResponse

app = FastAPI(title="python-sensors")
START = time.time()
REQS = 0

SENSORS = [
    {"id": "kitchen",     "kind": "BME280"},
    {"id": "garage",      "kind": "DHT22"},
    {"id": "greenhouse",  "kind": "BME280"},
    {"id": "freezer",     "kind": "DS18B20"},
]


def _reading(sensor_id: str) -> dict:
    # Deterministic-but-wavy value so charts have shape; jittered so two
    # readings in a row aren't identical.
    t = time.time()
    base = 18.0 + 4.0 * math.sin(t / 600.0 + hash(sensor_id) % 7)
    return {
        "sensor": sensor_id,
        "temperature_c": round(base + random.uniform(-0.2, 0.2), 2),
        "humidity_pct":  round(45 + 15 * math.sin(t / 900.0 + hash(sensor_id) % 5), 1),
        "ts": int(t),
    }


@app.middleware("http")
async def count(request, call_next):
    global REQS
    REQS += 1
    return await call_next(request)


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    rows = "".join(
        f"<tr><td>{s['id']}</td><td>{s['kind']}</td></tr>" for s in SENSORS
    )
    return (
        "<!doctype html><title>python-sensors</title>"
        "<h1>python-sensors</h1>"
        "<p>FastAPI service exposing fake BME280/DHT22/DS18B20 readings.</p>"
        f"<table border=1 cellpadding=4><tr><th>sensor</th><th>kind</th></tr>{rows}</table>"
        '<p><a href="/sensors">/sensors</a> · '
        '<a href="/health">/health</a> · '
        '<a href="/metrics">/metrics</a></p>'
    )


@app.get("/sensors")
def sensors() -> list[dict]:
    return [_reading(s["id"]) for s in SENSORS]


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "uptime_s": int(time.time() - START)}


@app.get("/metrics", response_class=PlainTextResponse)
def metrics() -> str:
    lines = [
        "# HELP python_sensors_requests_total Requests served",
        "# TYPE python_sensors_requests_total counter",
        f"python_sensors_requests_total {REQS}",
        "# HELP python_sensors_uptime_seconds Process uptime",
        "# TYPE python_sensors_uptime_seconds gauge",
        f"python_sensors_uptime_seconds {int(time.time() - START)}",
    ]
    for s in SENSORS:
        r = _reading(s["id"])
        lines += [
            f'python_sensors_temperature_c{{sensor="{s["id"]}"}} {r["temperature_c"]}',
            f'python_sensors_humidity_pct{{sensor="{s["id"]}"}} {r["humidity_pct"]}',
        ]
    return "\n".join(lines) + "\n"

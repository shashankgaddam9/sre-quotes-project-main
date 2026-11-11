"""
Quotes API - a small service built to practice SRE skills.

Features you will operate:
  - REST API backed by Redis (state lives outside the pod)
  - /healthz  (liveness)  and /readyz (readiness) probes for Kubernetes
  - /metrics  Prometheus metrics (request count, latency histogram, errors)
  - Structured JSON logs (one line per request)
  - Fault injection via env vars so you can practice incidents
"""
import json
import logging
import os
import random
import sys
import time
import uuid

import redis
from flask import Flask, g, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

APP_VERSION = os.getenv("APP_VERSION", "dev")
REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))

# --- Fault injection (used in the incident drills, docs/04-incident-drills.md) ---
FAULT_ERROR_RATE = float(os.getenv("FAULT_ERROR_RATE", "0"))   # 0.0 - 1.0
FAULT_LATENCY_MS = int(os.getenv("FAULT_LATENCY_MS", "0"))     # extra ms per request

# --- Structured logging ---
class JsonFormatter(logging.Formatter):
    def format(self, record):
        payload = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level": record.levelname,
            "msg": record.getMessage(),
            "version": APP_VERSION,
        }
        payload.update(getattr(record, "extra_fields", {}))
        return json.dumps(payload)

handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(JsonFormatter())
log = logging.getLogger("quotes")
log.addHandler(handler)
log.setLevel(logging.INFO)

# --- Metrics (the raw material for your SLIs) ---
REQUESTS = Counter("http_requests_total", "Total HTTP requests", ["method", "endpoint", "status"])
LATENCY = Histogram(
    "http_request_duration_seconds", "Request latency", ["endpoint"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
REDIS_UP = Gauge("redis_up", "1 if Redis is reachable from this pod")
APP_INFO = Gauge("app_info", "App version info", ["version"])
APP_INFO.labels(version=APP_VERSION).set(1)

app = Flask(__name__, static_folder="static", static_url_path="/static")
_redis = None


def get_redis():
    global _redis
    if _redis is None:
        _redis = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, socket_timeout=1,
                             socket_connect_timeout=1, decode_responses=True)
    return _redis


def set_redis_client(client):
    """Used by tests to inject a fake Redis."""
    global _redis
    _redis = client


@app.before_request
def start_timer():
    g.start = time.perf_counter()
    g.request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
    if request.path.startswith("/api") and FAULT_LATENCY_MS:
        time.sleep(FAULT_LATENCY_MS / 1000)
    if request.path.startswith("/api") and random.random() < FAULT_ERROR_RATE:
        return jsonify(error="injected fault"), 500


@app.after_request
def record(response):
    endpoint = request.url_rule.rule if request.url_rule else "unknown"
    if endpoint != "/metrics":
        elapsed = time.perf_counter() - g.start
        REQUESTS.labels(request.method, endpoint, response.status_code).inc()
        LATENCY.labels(endpoint).observe(elapsed)
        log.info("request", extra={"extra_fields": {
            "request_id": g.request_id, "method": request.method, "path": request.path,
            "status": response.status_code, "duration_ms": round(elapsed * 1000, 2),
        }})
    response.headers["X-Request-ID"] = g.request_id
    return response


# ---------------- Website ----------------
@app.get("/")
def home():
    """The web page. Its buttons call the /api endpoints below."""
    return app.send_static_file("index.html")


# ---------------- Probes ----------------
@app.get("/healthz")
def healthz():
    """Liveness: is the process alive? Never check dependencies here."""
    return jsonify(status="ok", version=APP_VERSION)


@app.get("/readyz")
def readyz():
    """Readiness: can this pod serve traffic? Checks Redis."""
    try:
        get_redis().ping()
        REDIS_UP.set(1)
        return jsonify(status="ready")
    except redis.RedisError as exc:
        REDIS_UP.set(0)
        log.warning("not ready", extra={"extra_fields": {"error": str(exc)}})
        return jsonify(status="not ready", error="redis unavailable"), 503


@app.get("/metrics")
def metrics():
    return generate_latest(), 200, {"Content-Type": CONTENT_TYPE_LATEST}


# ---------------- API ----------------
@app.get("/api/quotes")
def list_quotes():
    r = get_redis()
    ids = r.lrange("quotes", 0, -1)
    quotes = [{"id": i, **r.hgetall(f"quote:{i}")} for i in ids]
    return jsonify(quotes=quotes, count=len(quotes))


@app.post("/api/quotes")
def add_quote():
    data = request.get_json(silent=True) or {}
    text, author = data.get("text", "").strip(), data.get("author", "unknown").strip()
    if not text:
        return jsonify(error="'text' is required"), 400
    r = get_redis()
    qid = str(r.incr("quote:next_id"))
    r.hset(f"quote:{qid}", mapping={"text": text, "author": author})
    r.rpush("quotes", qid)
    return jsonify(id=qid, text=text, author=author), 201


@app.get("/api/quotes/random")
def random_quote():
    r = get_redis()
    ids = r.lrange("quotes", 0, -1)
    if not ids:
        return jsonify(error="no quotes yet"), 404
    qid = random.choice(ids)
    return jsonify(id=qid, **r.hgetall(f"quote:{qid}"))


@app.delete("/api/quotes/<qid>")
def delete_quote(qid):
    r = get_redis()
    if not r.exists(f"quote:{qid}"):
        return jsonify(error="not found"), 404
    r.delete(f"quote:{qid}")
    r.lrem("quotes", 0, qid)
    return "", 204


@app.post("/api/simulate-error")
def simulate_error():
    """Practice button on the website: always fails, so you can trace an error in the logs."""
    log.error("simulated error", extra={"extra_fields": {
        "request_id": g.request_id, "error": "user clicked 'Simulate a server error'"}})
    return jsonify(error="simulated server error", request_id=g.request_id), 500


@app.errorhandler(redis.RedisError)
def redis_down(exc):
    REDIS_UP.set(0)
    log.error("redis error", extra={"extra_fields": {
        "request_id": g.get("request_id"), "error": str(exc)}})
    return jsonify(error="backend unavailable"), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)

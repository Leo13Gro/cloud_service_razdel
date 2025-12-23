import os
import json
import uuid
from typing import Any, Dict, Optional, Tuple

import psycopg2
import psycopg2.extras
import redis
from flask import Flask, request, jsonify

# ===== Config from env =====
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
REDIS_STREAM = os.getenv("REDIS_STREAM", "jobs")

DB_DSN = os.getenv("DATABASE_URL")  # required: postgresql://user:pass@host:5432/db

# Optional: consumer group initialization can be done in worker.
# Optional: limit input size to avoid accidental huge payloads.
MAX_TEXT_BYTES = int(os.getenv("MAX_TEXT_BYTES", str(2 * 1024 * 1024)))  # 2MB default
# ==========================

if not DB_DSN:
    raise RuntimeError("DATABASE_URL env var is required")

r = redis.Redis.from_url(REDIS_URL, decode_responses=True)

app = Flask(__name__)


def db_conn():
    return psycopg2.connect(DB_DSN)


def insert_job(job_id: str, text: str) -> None:
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO jobs (id, status, payload_text)
                VALUES (%s, 'queued', %s)
                """,
                (job_id, text),
            )


def get_job_status_and_result(job_id: str) -> Tuple[Optional[str], Optional[str], Optional[Dict[str, Any]]]:
    """
    Returns: (status, error, result_dict)
    """
    with db_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT status, error FROM jobs WHERE id=%s",
                (job_id,),
            )
            job = cur.fetchone()
            if not job:
                return None, None, None

            status = job["status"]
            error = job["error"]

            if status != "done":
                return status, error, None

            cur.execute(
                "SELECT sentences, tokens FROM results WHERE job_id=%s",
                (job_id,),
            )
            res = cur.fetchone()
            if not res:
                # done but no result (shouldn't happen, but be safe)
                return status, error, None

            # psycopg2 maps JSONB to Python objects automatically
            return status, error, {"sentences": res["sentences"], "tokens": res["tokens"]}


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok"})


@app.post("/v1/analyze")
def analyze_async():
    data = request.get_json(force=True, silent=False) or {}
    text = data.get("text", "")
    if not isinstance(text, str) or not text.strip():
        return jsonify({"error": "Field 'text' must be a non-empty string"}), 400

    b = text.encode("utf-8")
    if len(b) > MAX_TEXT_BYTES:
        return jsonify({"error": f"text is too large (>{MAX_TEXT_BYTES} bytes)"}), 413

    job_id = str(uuid.uuid4())

    # 1) persist job
    insert_job(job_id, text)

    # 2) enqueue message to Redis Streams
    payload = json.dumps({"job_id": job_id}, ensure_ascii=False)
    r.xadd(REDIS_STREAM, {"payload": payload})

    return jsonify({"job_id": job_id}), 202


@app.get("/v1/jobs/<job_id>")
def job_status(job_id: str):
    try:
        uuid.UUID(job_id)
    except ValueError:
        return jsonify({"error": "Invalid job_id"}), 400

    status, error, result = get_job_status_and_result(job_id)
    if status is None:
        return jsonify({"error": "Not found"}), 404

    resp: Dict[str, Any] = {"job_id": job_id, "status": status}
    if error:
        resp["error"] = error
    if result is not None:
        resp["result"] = result
    return jsonify(resp)

if __name__ == "__main__":
    app.run(host=os.getenv("HOST", "0.0.0.0"), port=int(os.getenv("PORT", "5000")))

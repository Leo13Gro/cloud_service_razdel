import os
import json
import time
import uuid
from typing import Any, Dict, Optional, Tuple

import psycopg2
import psycopg2.extras
import redis
from flask import Flask, jsonify
from razdel import sentenize, tokenize

# ===== Config =====
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
STREAM = os.getenv("REDIS_STREAM", "jobs")
GROUP = os.getenv("REDIS_GROUP", "razdel_group")
CONSUMER = os.getenv("REDIS_CONSUMER", os.getenv("HOSTNAME", "worker-1"))

DB_DSN = os.getenv("DATABASE_URL")  # required

BLOCK_MS = int(os.getenv("STREAM_BLOCK_MS", "5000"))
CLAIM_IDLE_MS = int(os.getenv("CLAIM_IDLE_MS", "60000"))  # 60s
CLAIM_COUNT = int(os.getenv("CLAIM_COUNT", "10"))
SLEEP_ON_EMPTY = float(os.getenv("SLEEP_ON_EMPTY", "0.2"))
# ==================

if not DB_DSN:
    raise RuntimeError("DATABASE_URL env var is required")

r = redis.Redis.from_url(REDIS_URL, decode_responses=True)

app = Flask(__name__)


def db_conn():
    return psycopg2.connect(DB_DSN)


def ensure_group() -> None:
    """
    Create stream + consumer group if not exist.
    """
    try:
        r.xgroup_create(STREAM, GROUP, id="$", mkstream=True)
    except redis.ResponseError as e:
        if "BUSYGROUP" in str(e):
            return
        raise


def fetch_job_text(job_id: str) -> Optional[str]:
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT payload_text FROM jobs WHERE id=%s", (job_id,))
            row = cur.fetchone()
            return row[0] if row else None


def set_job_running(job_id: str) -> None:
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE jobs
                SET status='running', started_at=COALESCE(started_at, now())
                WHERE id=%s AND status IN ('queued','running')
                """,
                (job_id,),
            )


def set_job_error(job_id: str, err: str) -> None:
    with db_conn() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE jobs
                SET status='error', finished_at=now(), error=%s
                WHERE id=%s
                """,
                (err[:2000], job_id),
            )


def save_result_and_done(job_id: str, sentences: Any, tokens: Any) -> None:
    with db_conn() as conn:
        with conn.cursor() as cur:
            # Upsert result
            cur.execute(
                """
                INSERT INTO results (job_id, sentences, tokens)
                VALUES (%s, %s::jsonb, %s::jsonb)
                ON CONFLICT (job_id)
                DO UPDATE SET sentences=EXCLUDED.sentences, tokens=EXCLUDED.tokens
                """,
                (job_id, json.dumps(sentences, ensure_ascii=False), json.dumps(tokens, ensure_ascii=False)),
            )
            cur.execute(
                """
                UPDATE jobs
                SET status='done', finished_at=now(), error=NULL
                WHERE id=%s
                """,
                (job_id,),
            )


def razdel_process(text: str) -> Tuple[Any, Any]:
    sents = [{"start": s.start, "end": s.stop} for s in sentenize(text)]
    toks = [{"text": t.text, "start": t.start, "end": t.stop} for t in tokenize(text)]
    return sents, toks


def parse_payload(fields: Dict[str, str]) -> str:
    raw = fields.get("payload")
    if not raw:
        raise ValueError("Missing 'payload' field in stream message")
    data = json.loads(raw)
    job_id = data.get("job_id")
    if not job_id:
        raise ValueError("Missing job_id in payload")
    # Validate UUID
    uuid.UUID(job_id)
    return job_id


def claim_stuck() -> None:
    """
    Re-claim messages that were delivered but not acked (stuck workers).
    """
    try:
        pend = r.xpending_range(STREAM, GROUP, min="-", max="+", count=CLAIM_COUNT, consumername=None)
    except redis.ResponseError:
        return

    # pend items have: {'message_id': '...', 'consumer': '...', 'time_since_delivered': ms, 'times_delivered': n}
    stuck_ids = [p["message_id"] for p in pend if p["time_since_delivered"] >= CLAIM_IDLE_MS]
    if not stuck_ids:
        return

    r.xclaim(STREAM, GROUP, CONSUMER, min_idle_time=CLAIM_IDLE_MS, message_ids=stuck_ids)


def worker_loop() -> None:
    ensure_group()

    while True:
        # Occasionally try to reclaim stuck messages
        claim_stuck()

        msgs = r.xreadgroup(
            GROUP,
            CONSUMER,
            streams={STREAM: ">"},
            count=1,
            block=BLOCK_MS,
        )

        if not msgs:
            time.sleep(SLEEP_ON_EMPTY)
            continue

        # msgs: [(stream_name, [(msg_id, {field: val, ...}), ...])]
        _, items = msgs[0]
        for msg_id, fields in items:
            try:
                job_id = parse_payload(fields)

                # Mark running (best effort)
                set_job_running(job_id)

                text = fetch_job_text(job_id)
                if text is None:
                    raise ValueError(f"Job {job_id} not found in DB")

                sentences, tokens = razdel_process(text)
                save_result_and_done(job_id, sentences, tokens)

                # Ack after DB commit
                r.xack(STREAM, GROUP, msg_id)

            except Exception as e:
                # Mark error in DB (message remains pending unless we ack)
                # In учебном варианте можно ack, чтобы не зацикливаться.
                try:
                    # job_id might not parse; ignore
                    if "job_id" in (fields.get("payload") or ""):
                        pass
                except Exception:
                    pass

                # Try to extract job_id for error marking
                try:
                    job_id2 = parse_payload(fields)
                    set_job_error(job_id2, str(e))
                except Exception:
                    # Can't map to job_id -> ignore
                    pass

                # Ack anyway to avoid infinite retries in minimal setup
                r.xack(STREAM, GROUP, msg_id)


@app.get("/healthz")
def healthz():
    return jsonify({"status": "ok", "consumer": CONSUMER, "group": GROUP, "stream": STREAM})


if __name__ == "__main__":
    # Run worker loop in background; Flask just for health
    import threading

    t = threading.Thread(target=worker_loop, daemon=True)
    t.start()

    # Flask dev server is ok for курсовой VM; in production use gunicorn.
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8000")))

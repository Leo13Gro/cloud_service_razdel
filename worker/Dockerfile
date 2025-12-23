FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

COPY worker/worker.py ./worker.py

RUN pip install --no-cache-dir flask redis razdel psycopg2-binary

# По умолчанию health на 8000 (как у тебя)
ENV PORT=8000 \
    REDIS_STREAM=jobs \
    REDIS_GROUP=razdel_group

EXPOSE 8000

CMD ["python", "worker.py"]

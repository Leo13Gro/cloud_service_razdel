FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Системные зависимости для psycopg2 (если вдруг psycopg2-binary будет заменён на psycopg2)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Копируем только папку gateway (и при необходимости общий requirements)
COPY gateway/gateway.py ./gateway.py

# Ставим зависимости (как в твоих sh-скриптах)
RUN pip install --no-cache-dir flask redis psycopg2-binary

# Переменные по умолчанию (переопределяются в compose)
ENV HOST=0.0.0.0 \
    PORT=5000 \
    REDIS_STREAM=jobs

EXPOSE 5000

CMD ["python", "gateway.py"]

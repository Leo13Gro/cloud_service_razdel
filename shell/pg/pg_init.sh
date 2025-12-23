#!/bin/bash
set -euo pipefail

# Требуется: PostgreSQL уже установлен, БД уже существует.
# Запускать от root или пользователя с sudo.

DB_NAME="${DB_NAME:-razdel}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (or use sudo)"
  exit 1
fi

echo "Initializing schema in database: ${DB_NAME}"

sudo -u postgres psql -d "${DB_NAME}" <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'job_status') THEN
    CREATE TYPE job_status AS ENUM ('queued', 'running', 'done', 'error');
  END IF;
END$$;

CREATE TABLE IF NOT EXISTS jobs (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at   TIMESTAMPTZ,
  finished_at  TIMESTAMPTZ,
  status       job_status NOT NULL DEFAULT 'queued',
  payload_text TEXT NOT NULL,
  error        TEXT
);

CREATE TABLE IF NOT EXISTS results (
  job_id    UUID PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
  sentences JSONB NOT NULL,
  tokens    JSONB NOT NULL
);
SQL

echo "Schema init complete."

sudo -u postgres psql -d razdel -c "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE jobs TO razdel_user;"
sudo -u postgres psql -d razdel -c "GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE results TO razdel_user;"

echo "Permissions granted."

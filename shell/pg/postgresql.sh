#!/bin/bash
set -euo pipefail

# Этот скрипт:
# 1) ставит PostgreSQL
# 2) создаёт БД и пользователя
# 3) включает сетевое прослушивание и доступ из подсети
# 4) запускает pg_init_tables.sh

# ===== Настройки =====
DB_NAME="${DB_NAME:-razdel}"
DB_USER="${DB_USER:-razdel_user}"
DB_PASS="${DB_PASS:-}"                 # если пусто — генериться
ALLOW_CIDR="${ALLOW_CIDR:-10.0.1.0/24}" # подсеть, из которой разрешён доступ
# ============================================================

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (or use sudo)"
  exit 1
fi

if [[ -z "${DB_PASS}" ]]; then
  DB_PASS="$(openssl rand -hex 12)"
fi

echo "[1/6] Installing PostgreSQL..."
apt-get update
apt-get install -y postgresql postgresql-contrib openssl

echo "[2/6] Enabling and starting PostgreSQL..."
systemctl enable postgresql
systemctl start postgresql

echo "[3/6] Creating database and user (if not exist)..."
sudo -u postgres psql <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}') THEN
    CREATE DATABASE ${DB_NAME};
  END IF;
END
\$\$;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;

GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

echo "[4/6] Configuring PostgreSQL network access..."
PG_CONF="$(ls -d /etc/postgresql/*/main | head -n 1)"
PG_VERSION_DIR="$(basename "$(dirname "$PG_CONF")")" >/dev/null 2>&1 || true

# listen_addresses = '*'
sed -i "s/^[#]*listen_addresses\s*=.*/listen_addresses = '*'/" "${PG_CONF}/postgresql.conf"

# разрешаем доступ из подсети
# добавим строку, если её ещё нет
HBA_LINE="host    ${DB_NAME}    ${DB_USER}    ${ALLOW_CIDR}    scram-sha-256"
if ! grep -qF "${HBA_LINE}" "${PG_CONF}/pg_hba.conf"; then
  echo "${HBA_LINE}" >> "${PG_CONF}/pg_hba.conf"
fi

echo "[5/6] Restarting PostgreSQL..."
systemctl restart postgresql

echo "[6/6] Running schema init script..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DB_NAME
bash "${SCRIPT_DIR}/pg_init_tables.sh"

# сохраняем креды (удобно скопировать на VM1/VM3)
mkdir -p /opt/razdel
cat > /opt/razdel/postgres.env <<EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
# Для Gateway/Worker сформируй:
# DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@<POSTGRES_PRIVATE_IP>:5432/${DB_NAME}
EOF
chmod 600 /opt/razdel/postgres.env

echo "PostgreSQL node is ready."
echo "Credentials saved to /opt/razdel/postgres.env"

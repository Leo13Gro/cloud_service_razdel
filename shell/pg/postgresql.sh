#!/bin/bash
set -euo pipefail

DB_NAME="${DB_NAME:-razdel}"
DB_USER="${DB_USER:-razdel_user}"
DB_PASS="${DB_PASS:-12345}"
ALLOW_CIDR="${ALLOW_CIDR:-10.0.0.0/24}"

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

echo "[3/6] Creating DB and user (idempotent, without DO CREATE DATABASE)..."

# Создать пользователя, если нет (это можно через DO)
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;
EOF

# Создать базу, если нет (CREATE DATABASE нельзя внутри DO)
DB_EXISTS="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")"
if [[ "${DB_EXISTS}" != "1" ]]; then
  sudo -u postgres createdb "${DB_NAME}"
fi

# Права на БД
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

echo "[4/6] Configuring PostgreSQL network access..."
PG_CONF_DIR="$(ls -d /etc/postgresql/*/main | head -n 1)"

# listen_addresses = '*'
if grep -qE '^[#]*listen_addresses\s*=' "${PG_CONF_DIR}/postgresql.conf"; then
  sed -i "s/^[#]*listen_addresses\s*=.*/listen_addresses = '*'/" "${PG_CONF_DIR}/postgresql.conf"
else
  echo "listen_addresses = '*'" >> "${PG_CONF_DIR}/postgresql.conf"
fi

# pg_hba: разрешаем доступ из подсети к конкретной БД и пользователю
HBA_LINE="host    ${DB_NAME}    ${DB_USER}    ${ALLOW_CIDR}    scram-sha-256"
grep -qF "${HBA_LINE}" "${PG_CONF_DIR}/pg_hba.conf" || echo "${HBA_LINE}" >> "${PG_CONF_DIR}/pg_hba.conf"

echo "[5/6] Restarting PostgreSQL..."
systemctl restart postgresql

echo "[6/6] Running schema init script..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DB_NAME
bash "${SCRIPT_DIR}/pg_init.sh"

mkdir -p /opt/razdel
cat > /opt/razdel/postgres.env <<EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
# DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@<POSTGRES_PRIVATE_IP>:5432/${DB_NAME}
EOF
chmod 600 /opt/razdel/postgres.env

echo "PostgreSQL node is ready."
echo "Credentials saved to /opt/razdel/postgres.env"

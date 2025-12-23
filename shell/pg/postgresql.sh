#!/bin/bash
set -euo pipefail

DB_NAME="${DB_NAME:-razdel}"
DB_USER="${DB_USER:-razdel_user}"
DB_PASS="${DB_PASS:-12345}"

# Подсеть, из которой разрешены подключения к БД (под свои VM)
ALLOW_CIDR="${ALLOW_CIDR:-10.0.0.0/24}"

# IP/host PostgreSQL для формирования DATABASE_URL в env (для 4 VM ставь private ip VM4)
POSTGRES_HOST="${POSTGRES_HOST:-localhost}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (or use sudo)"
  exit 1
fi

apt-get update
apt-get install -y postgresql postgresql-contrib openssl

systemctl enable postgresql
systemctl start postgresql

# Пользователь (можно через DO)
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    CREATE USER ${DB_USER} WITH ENCRYPTED PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;
EOF

# База (CREATE DATABASE нельзя внутри DO)
DB_EXISTS="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")"
if [[ "${DB_EXISTS}" != "1" ]]; then
  sudo -u postgres createdb "${DB_NAME}"
fi

sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOF
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

echo "[*] Configuring PostgreSQL network access..."
PG_CONF_DIR="$(ls -d /etc/postgresql/*/main | head -n 1)"
PG_CONF="${PG_CONF_DIR}/postgresql.conf"
PG_HBA="${PG_CONF_DIR}/pg_hba.conf"

# Backup один раз
if [[ ! -f "${PG_CONF}.bak" ]]; then
  cp -a "$PG_CONF" "${PG_CONF}.bak"
fi
if [[ ! -f "${PG_HBA}.bak" ]]; then
  cp -a "$PG_HBA" "${PG_HBA}.bak"
fi

# listen_addresses = '*'
if grep -qE '^[#]*listen_addresses\s*=' "$PG_CONF"; then
  sed -i "s/^[#]*listen_addresses\s*=.*/listen_addresses = '*'/" "$PG_CONF"
else
  echo "listen_addresses = '*'" >> "$PG_CONF"
fi

# pg_hba: доступ из подсети к конкретной БД и пользователю
HBA_LINE="host    ${DB_NAME}    ${DB_USER}    ${ALLOW_CIDR}    scram-sha-256"
grep -qF "$HBA_LINE" "$PG_HBA" || echo "$HBA_LINE" >> "$PG_HBA"

systemctl restart postgresql

# Инициализация схемы
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DB_NAME
bash "${SCRIPT_DIR}/pg_init.sh"

# ВАЖНО: выдать права на таблицы (иначе gateway словит permission denied) 
sudo -u postgres psql -d "${DB_NAME}" -v ON_ERROR_STOP=1 <<EOF
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE jobs TO ${DB_USER};
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE results TO ${DB_USER};

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO ${DB_USER};
EOF

# Сохранить env
mkdir -p /opt/razdel
cat > /opt/razdel/postgres.env <<EOF
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@${POSTGRES_HOST}:${POSTGRES_PORT}/${DB_NAME}
EOF

# Права: читать сможет группа razdel (gateway/worker), root — владелец
chown root:razdel /opt/razdel/postgres.env || true
chmod 640 /opt/razdel/postgres.env

echo "PostgreSQL node is ready."
echo "Saved env to /opt/razdel/postgres.env"
echo "ALLOW_CIDR=${ALLOW_CIDR}, listen_addresses='*'"

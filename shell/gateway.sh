#!/bin/bash
set -e

APP_DIR=/opt/razdel-gateway
GATEWAY_DIR=$APP_DIR/gateway
VENV_DIR=$GATEWAY_DIR/venv
SERVICE_NAME=razdel-gateway

apt update
apt install -y python3 python3-venv python3-pip git

useradd -r -s /bin/false razdel || true

mkdir -p "$APP_DIR"
# git clone создаст файлы root'ом, поэтому chown делаем ПОСЛЕ clone
if [ ! -d "$APP_DIR/.git" ]; then
  git clone https://github.com/Leo13Gro/cloud_service_razdel.git "$APP_DIR"
else
  # если уже клонировали раньше — просто обновим
  git -C "$APP_DIR" pull
fi

chown -R razdel:razdel "$APP_DIR"

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install -U pip
"$VENV_DIR/bin/pip" install flask redis psycopg2-binary

cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=Razdel API Gateway
After=network.target redis-server.service postgresql.service

[Service]
User=razdel
WorkingDirectory=$GATEWAY_DIR
ExecStart=$VENV_DIR/bin/python $GATEWAY_DIR/gateway.py
Restart=always

# gateway.py читает REDIS_URL и REDIS_STREAM
Environment=REDIS_URL=redis://localhost:6379/0
Environment=REDIS_STREAM=jobs

# в этом файле должен быть DATABASE_URL=postgresql://...
EnvironmentFile=/opt/razdel/postgres.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME

# Удобно сразу увидеть, если упало
systemctl --no-pager --full status $SERVICE_NAME || true

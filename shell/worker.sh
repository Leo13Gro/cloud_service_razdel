#!/bin/bash
set -e

APP_DIR=/opt/razdel-worker
VENV_DIR=$APP_DIR/venv
SERVICE_NAME=razdel-worker

apt install -y python3 python3-venv python3-pip git

useradd -r -s /bin/false razdel || true
mkdir -p $APP_DIR
chown razdel:razdel $APP_DIR

git clone <REPO_URL> $APP_DIR
python3 -m venv $VENV_DIR
$VENV_DIR/bin/pip install flask redis razdel psycopg2-binary

cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=Razdel Analyzer Worker
After=network.target redis-server.service postgresql.service

[Service]
User=razdel
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/python worker.py
Restart=always
Environment=REDIS_HOST=localhost
EnvironmentFile=/opt/razdel_db.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

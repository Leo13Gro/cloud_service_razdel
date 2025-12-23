#!/bin/bash
set -e

APP_DIR=/opt/razdel-worker
WORKER_DIR=$APP_DIR/worker
VENV_DIR=$WORKER_DIR/venv
SERVICE_NAME=razdel-worker

apt install -y python3 python3-venv python3-pip git

useradd -r -s /bin/false razdel || true
mkdir -p $APP_DIR
chown razdel:razdel $APP_DIR

git clone https://github.com/Leo13Gro/cloud_service_razdel.git $APP_DIR
chown -R razdel:razdel $APP_DIR

python3 -m venv $VENV_DIR
$VENV_DIR/bin/pip install flask redis razdel psycopg2-binary

cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=Razdel Analyzer Worker
After=network.target

[Service]
User=razdel
WorkingDirectory=$WORKER_DIR
ExecStart=$VENV_DIR/bin/python $WORKER_DIR/worker.py
Restart=always
Environment=PORT=8000
Environment=REDIS_STREAM=jobs
Environment=REDIS_GROUP=razdel_group
EnvironmentFile=/opt/razdel/razdel.env

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl start $SERVICE_NAME

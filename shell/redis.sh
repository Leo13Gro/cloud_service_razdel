#!/bin/bash
set -e

if [[ $(id -u) -ne 0 ]]; then
  echo "Script must be run as root"
  exit 1
fi

apt update
apt install -y redis-server

systemctl enable redis-server
systemctl start redis-server

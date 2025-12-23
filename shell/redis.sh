#!/bin/bash
set -euo pipefail

# Можно переопределить при запуске:
#   sudo REDIS_BIND_IP=0.0.0.0 bash redis.sh
# Лучше для облака:  sudo REDIS_BIND_IP=<private_ip_vm2> bash redis.sh
REDIS_BIND_IP="${REDIS_BIND_IP:-0.0.0.0}"
REDIS_PORT="${REDIS_PORT:-6379}"
CONF="/etc/redis/redis.conf"

if [[ $(id -u) -ne 0 ]]; then
  echo "Script must be run as root"
  exit 1
fi

apt update
apt install -y redis-server

# Backup конфига один раз
if [[ ! -f "${CONF}.bak" ]]; then
  cp -a "$CONF" "${CONF}.bak"
fi

# bind
if grep -qE '^\s*bind\s+' "$CONF"; then
  # заменяем строку bind ... на bind <ip>
  sed -i -E "s/^\s*bind\s+.*/bind ${REDIS_BIND_IP}/" "$CONF"
else
  echo "bind ${REDIS_BIND_IP}" >> "$CONF"
fi

# protected-mode
if grep -qE '^\s*protected-mode\s+' "$CONF"; then
  sed -i -E "s/^\s*protected-mode\s+.*/protected-mode no/" "$CONF"
else
  echo "protected-mode no" >> "$CONF"
fi

# port
if grep -qE '^\s*port\s+' "$CONF"; then
  sed -i -E "s/^\s*port\s+.*/port ${REDIS_PORT}/" "$CONF"
else
  echo "port ${REDIS_PORT}" >> "$CONF"
fi

# supervised systemd (обычно уже так, но пусть будет)
if grep -qE '^\s*supervised\s+' "$CONF"; then
  sed -i -E "s/^\s*supervised\s+.*/supervised systemd/" "$CONF"
else
  echo "supervised systemd" >> "$CONF"
fi

systemctl enable redis-server
systemctl restart redis-server

echo "Redis node is ready."
echo "Redis is listening on ${REDIS_BIND_IP}:${REDIS_PORT}"

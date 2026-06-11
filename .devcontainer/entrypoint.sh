#!/bin/bash
# Entrypoint wrapper for podman-in-podman DevContainer.
# 1. Remount /proc/sys rw (netavark bridge networking needs this)
# 2. Start healthcheck poller in background (Podman 5.x needs systemd
#    for healthcheck timers, which is absent in DevContainer)
# 3. Exec the original CMD (DevContainer's sleep loop)

sudo mount -o remount,rw /proc/sys 2>/dev/null || true

nohup /usr/local/bin/healthcheck-poller.sh >/dev/null 2>&1 &

exec "$@"

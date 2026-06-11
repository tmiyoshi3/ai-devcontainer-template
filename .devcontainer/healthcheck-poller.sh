#!/usr/bin/env bash
# healthcheck-poller.sh — Workaround for Podman 5.x healthcheck timers
# requiring systemd, which is unavailable in DevContainer (PID 1 = sh).
# Polls all containers in "starting" health state every INTERVAL seconds.
# See: https://github.com/containers/podman/issues/28192
#
# Launched once by entrypoint.sh at container start.

INTERVAL="${1:-10}"

while true; do
  for cid in $(podman ps -q --filter health=starting 2>/dev/null); do
    podman healthcheck run "$cid" >/dev/null 2>&1
  done
  sleep "$INTERVAL"
done

#!/usr/bin/env bash
set -Eeuo pipefail
CONT="${1:-}"
if [ -z "$CONT" ]; then
  CONT=$(docker ps --format '{{.Names}} {{.Image}}' | awk '/ghcr.io\/techroy23\/docker-wipter/ {print $1; exit}')
fi
[ -n "$CONT" ] || { echo "No running docker-wipter container found"; exit 1; }
OUT="wipter-probe-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "container=$CONT" | tee "$OUT/summary.txt"

docker stats --no-stream "$CONT" | tee "$OUT/stats-before.txt" || true
docker inspect "$CONT" > "$OUT/inspect.json" || true
docker exec "$CONT" sh -c 'ps -eo pid,ppid,rss,comm,args --sort=-rss' > "$OUT/ps-before.txt" || true
docker exec "$CONT" sh -c 'ss -lntup 2>/dev/null || netstat -lntup 2>/dev/null || true' > "$OUT/ports.txt" || true
docker exec "$CONT" sh -c 'cat /root/.config/wipter-app/logs/main.log 2>/dev/null | tail -300' > "$OUT/main-log-tail.txt" || true
docker exec "$CONT" sh -c 'cat /opt/Wipter/resources/app-update.yml 2>/dev/null || true; echo; head -80 /opt/Wipter/wipter-app 2>/dev/null || true' > "$OUT/version-wrapper.txt" || true
docker exec "$CONT" sh -c 'strings /opt/Wipter/resources/app.asar 2>/dev/null | grep -E "appVersion|version|registration|publicIP|local_addr|remote_addr" | head -300' > "$OUT/asar-strings.txt" || true
docker exec "$CONT" sh -c 'du -h -d 2 /opt/Wipter /opt/noVNC /root/.config/wipter-app 2>/dev/null | sort -h' > "$OUT/du.txt" || true

if [ "${SLIM_TEST:-false}" = "true" ]; then
  echo "Running safe slim test: kill GUI helpers, not Electron/Xvfb/tunnel"
  docker exec "$CONT" sh -c 'pkill -f "x11vnc|websockify|novnc|openbox|fluxbox|xterm|xte" 2>/dev/null || true' || true
  sleep 10
  docker stats --no-stream "$CONT" | tee "$OUT/stats-after-slim-test.txt" || true
  docker exec "$CONT" sh -c 'ps -eo pid,ppid,rss,comm,args --sort=-rss' > "$OUT/ps-after-slim-test.txt" || true
fi

tar -czf "$OUT.tar.gz" "$OUT"
rm -rf "$OUT"
echo "OK: $OUT.tar.gz"

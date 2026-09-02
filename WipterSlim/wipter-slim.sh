#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

load_env() {
  [ -f config.env ] || { echo "missing config.env"; exit 1; }
  sed -i 's/\r$//' config.env proxies.txt 2>/dev/null || true
  set -a; source config.env; set +a
}
need_docker() { command -v docker >/dev/null || { echo "missing docker"; exit 1; }; docker info >/dev/null || { echo "docker daemon not ready"; exit 1; }; }
proxy_lines() { grep -vE '^\s*(#|$)' proxies.txt || true; }
name_tun() { printf 'ws-tun-%04d' "$1"; }
name_app() { printf 'ws-app-%04d' "$1"; }

pull() { docker pull "$TUN_IMAGE"; docker pull "$WIPTER_IMAGE"; }

start_one() {
  local i="$1" proxy="$2" tun app hn
  tun="$(name_tun "$i")"; app="$(name_app "$i")"; hn="${DEVICE_NAME}${i}"
  docker rm -f "$app" "$tun" >/dev/null 2>&1 || true

  docker run -d --name "$tun" \
    --restart always \
    --memory "${TUN_MEMORY:-64m}" --memory-swap "${TUN_MEMORY:-64m}" --cpus "${TUN_CPUS:-0.10}" \
    --pids-limit 128 --log-driver json-file --log-opt max-size=1m --log-opt max-file=1 \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 \
    --device /dev/net/tun --cap-add=NET_ADMIN --no-healthcheck \
    "$TUN_IMAGE" --dns virtual --proxy "$proxy" --verbosity off >/dev/null

  docker run -d --name "$app" \
    --network "container:$tun" --hostname "$hn" --restart always \
    --memory "${WIPTER_MEMORY:-160m}" --memory-swap "${WIPTER_MEMORY:-160m}" --cpus "${WIPTER_CPUS:-0.25}" \
    --pids-limit "${WIPTER_PIDS_LIMIT:-256}" --security-opt no-new-privileges:true \
    --log-driver json-file --log-opt max-size=1m --log-opt max-file=1 \
    -e WIPTER_EMAIL="$WIPTER_EMAIL" -e WIPTER_PASSWORD="$WIPTER_PASSWORD" \
    "$WIPTER_IMAGE" >/dev/null

  if [ "${KILL_GUI_HELPERS:-true}" = "true" ]; then
    # Không kill electron/Xvfb. Chỉ thử tắt lớp remote desktop/phụ trợ nếu có.
    sleep 8
    docker exec "$app" sh -c 'pkill -f "x11vnc|websockify|novnc|openbox|fluxbox|xterm|xte" 2>/dev/null || true' >/dev/null 2>&1 || true
  fi
  echo "started $app via $tun"
}

start() {
  load_env; need_docker
  [ -n "${WIPTER_EMAIL:-}" ] && [ -n "${WIPTER_PASSWORD:-}" ] || { echo "set WIPTER_EMAIL/WIPTER_PASSWORD in config.env"; exit 1; }
  [ -s proxies.txt ] || { echo "put proxies in proxies.txt"; exit 1; }
  pull
  local i=0 line
  while IFS= read -r line; do
    i=$((i+1)); start_one "$i" "$line"; sleep "${START_DELAY_SEC:-2}"
  done < <(proxy_lines)
  echo "OK started $i nodes"
}

stop() { docker ps -a --format '{{.Names}}' | grep -E '^ws-(app|tun)-[0-9]+' | xargs -r docker rm -f; }
restart() { stop; start; }

stats() {
  docker stats --no-stream $(docker ps --format '{{.Names}}' | grep -E '^ws-(app|tun)-[0-9]+' | tr '\n' ' ') 2>/dev/null || true
}

doctor() {
  printf '%-5s %-14s %-12s %-12s %-8s %-8s %s\n' ID APP_MEM TUN_MEM APP_STATUS TUN_PID APP_PID NOTE
  local app tun id appmem tunmem appst apppid tunpid note
  for app in $(docker ps -a --format '{{.Names}}' | grep -E '^ws-app-[0-9]+' | sort); do
    id="${app##*-}"; tun="ws-tun-$id"
    appmem=$(docker stats --no-stream --format '{{.MemUsage}}' "$app" 2>/dev/null | awk '{print $1}')
    tunmem=$(docker stats --no-stream --format '{{.MemUsage}}' "$tun" 2>/dev/null | awk '{print $1}')
    appst=$(docker inspect -f '{{.State.Status}}' "$app" 2>/dev/null || echo missing)
    apppid=$(docker top "$app" 2>/dev/null | tail -n +2 | wc -l || echo 0)
    tunpid=$(docker top "$tun" 2>/dev/null | tail -n +2 | wc -l || echo 0)
    note=""
    docker logs --tail=50 "$app" 2>&1 | grep -qiE 'error|failed|reject|unsupported' && note="CHECK_LOG"
    printf '%-5s %-14s %-12s %-12s %-8s %-8s %s\n' "$id" "${appmem:-?}" "${tunmem:-?}" "$appst" "$tunpid" "$apppid" "$note"
  done
}

logs() { docker logs --tail=200 -f "${1:-ws-app-0001}"; }
inspect-one() { docker exec "${1:-ws-app-0001}" sh -c 'echo ===ps===; ps auxww; echo ===mem===; cat /proc/meminfo | head; echo ===env===; env | sort | sed -E "s/(PASS|PASSWORD|TOKEN|EMAIL)=.*/\1=***/"' || true; }
slim-gui() { for app in $(docker ps --format '{{.Names}}' | grep -E '^ws-app-[0-9]+'); do docker exec "$app" sh -c 'pkill -f "x11vnc|websockify|novnc|openbox|fluxbox|xterm|xte" 2>/dev/null || true'; done; }

case "${1:-doctor}" in
  start) start;; stop) stop;; restart) restart;; stats) stats;; doctor) doctor;; logs) shift; logs "$@";; inspect-one) shift; inspect-one "$@";; slim-gui) slim-gui;; *) echo "Usage: $0 {start|stop|restart|doctor|stats|logs [container]|inspect-one [container]|slim-gui}";;
esac

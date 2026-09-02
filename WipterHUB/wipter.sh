#!/usr/bin/env bash
# ==============================================================================
# WIPTER STANDALONE HUB - MASTER CONTROLLER (AUTO-ENV & IP-AUTH READY)
# ==============================================================================
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
BUILD_ID="2026-09-02-native-flow-v1"

# 1. Tự cấp quyền & tạo phím tắt toàn hệ thống
chmod +x "$0" 2>/dev/null || true
if [ ! -f "/usr/local/bin/wipter" ] || [ "$(readlink -f /usr/local/bin/wipter 2>/dev/null)" != "$DIR/wipter.sh" ]; then
  ln -sf "$DIR/wipter.sh" /usr/local/bin/wipter 2>/dev/null || true
  ln -sf "$DIR/wipter.sh" /usr/bin/wipter 2>/dev/null || true
fi

# 2. Đọc file config.env an toàn (Chống lỗi dính \r của Windows & thiếu dòng trống)
if [ -f "$DIR/config.env" ]; then
  sed -i 's/\r$//' "$DIR/config.env" 2>/dev/null || true
  while IFS='=' read -r key value || [ -n "$key" ]; do
    [[ "$key" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key//[[:space:]]/}" ]] && continue
    key=$(echo "$key" | tr -d '[:space:]')
    value=$(echo "$value" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//')
    if [ -n "$key" ]; then
      export "$key=$value"
    fi
  done < "$DIR/config.env"
fi

case "${1:-start}" in
  start)
    echo "=================================================================="
    echo "       WIPTER ELASTIC HUB (DYNAMIC PRESSURE GOVERNOR RUNNING)     "
    echo "=================================================================="

    if [ -z "${WIPTER_EMAIL:-}" ] || [ -z "${WIPTER_PASSWORD:-}" ]; then
      echo "[LỖI] Chưa cấu hình WIPTER_EMAIL hoặc WIPTER_PASSWORD trong config.env!"
      exit 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
      echo "[LỖI] Chưa cài Docker hoặc Docker không có trong PATH. Cài Docker trước khi chạy wipter start."
      exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
      echo "[LỖI] Docker daemon chưa chạy hoặc user hiện tại không có quyền dùng Docker."
      exit 1
    fi

    DIAG_PORT="${WIPTER_DIAGNOSTIC_HOST_PORT:-28999}"
    MAX_CONN_GLOBAL="${WIPTER_MAX_CONN_GLOBAL:-2000}"
    MAX_CONN_PER_NODE="${WIPTER_MAX_CONN_PER_NODE:-32}"
    IDLE_TIMEOUT="${WIPTER_IDLE_TIMEOUT_SEC:-120}"
    BLOCK_PRIVATE="${WIPTER_BLOCK_PRIVATE_TARGETS:-true}"
    MEM_ARGS=()
    if [ -n "${WIPTER_MEMORY_LIMIT:-}" ]; then
      MEM_ARGS=(--memory "$WIPTER_MEMORY_LIMIT" --memory-swap "$WIPTER_MEMORY_LIMIT")
    fi

    echo " • Build                           : ${BUILD_ID}"
    echo " • Chế độ IP-Auth                  : Không probe/check IP ra dịch vụ bên ngoài"
    echo " • Network Docker                  : bridge + outbound SNAT qua IPv4 VPS"
    echo " • Diagnostic local                : 127.0.0.1:${DIAG_PORT}"
    echo " • Chặn target private/internal    : ${BLOCK_PRIVATE}"
    echo " • App version                     : ${WIPTER_APP_VERSION:-1.25.988}"
    echo " • Retry terminal registration     : ${WIPTER_RETRY_TERMINAL_REGISTRATION:-false}"
    echo " • Tài khoản Wipter                : $WIPTER_EMAIL"

    # Tự động tìm proxies.txt nếu chưa có
    if [ ! -f "proxies.txt" ]; then
      for candidate in "/root/bandwidth-sharing/proxies.txt" "/root/InternetIncome/proxies.txt" "$HOME/bandwidth-sharing/proxies.txt"; do
        if [ -f "$candidate" ]; then
          ln -sf "$candidate" proxies.txt
          echo " • Tự động liên kết Proxies từ    : $candidate"
          break
        fi
      done
    fi

    if [ ! -f "proxies.txt" ]; then
      echo "[LỖI] Không tìm thấy file proxies.txt!"
      exit 1
    fi

    TOTAL_PROXIES=$(grep -c . proxies.txt || echo 0)
    echo " • Số lượng Proxies nạp vào       : ${TOTAL_PROXIES} IPs"

    touch "$DIR/devices_state.json"
    chmod 600 "$DIR/devices_state.json" 2>/dev/null || true
    ulimit -n 65535 2>/dev/null || true

    echo " • Đang kiểm tra & Build Docker Image..."
    docker build -t wipter-engine:latest "$DIR" >/dev/null

    docker rm -f wipter-standalone-hub 2>/dev/null || true
    
    echo " • Đang khởi chạy Wipter Hub..."
    docker run -d \
      --name wipter-standalone-hub \
      --network bridge \
      -p "127.0.0.1:${DIAG_PORT}:28999" \
      --restart always \
      --cap-drop=ALL \
      --security-opt no-new-privileges:true \
      --pids-limit 4096 \
      --tmpfs /tmp:rw,nosuid,nodev,size=64m \
      "${MEM_ARGS[@]}" \
      --log-driver json-file \
      --log-opt max-size=5m \
      --log-opt max-file=2 \
      --ulimit nofile=65535:65535 \
      -v "$DIR/proxies.txt:/app/proxies.txt:ro" \
      -v "$DIR/devices_state.json:/app/devices_state.json:rw" \
      -e WIPTER_EMAIL="$WIPTER_EMAIL" \
      -e WIPTER_PASSWORD="$WIPTER_PASSWORD" \
      -e WIPTER_APP_VERSION="${WIPTER_APP_VERSION:-1.25.988}" \
      -e WIPTER_PLATFORM_VERSION="${WIPTER_PLATFORM_VERSION:-Debian GNU/Linux 13 (trixie)}" \
      -e WIPTER_REQUIRE_REST_REGISTER="${WIPTER_REQUIRE_REST_REGISTER:-true}" \
      -e WIPTER_DIAGNOSTIC_ADDR="0.0.0.0:28999" \
      -e WIPTER_MAX_CONN_GLOBAL="$MAX_CONN_GLOBAL" \
      -e WIPTER_MAX_CONN_PER_NODE="$MAX_CONN_PER_NODE" \
      -e WIPTER_IDLE_TIMEOUT_SEC="$IDLE_TIMEOUT" \
      -e WIPTER_BLOCK_PRIVATE_TARGETS="$BLOCK_PRIVATE" \
      -e WIPTER_RETRY_TERMINAL_REGISTRATION="${WIPTER_RETRY_TERMINAL_REGISTRATION:-false}" \
      wipter-engine:latest >/dev/null

    echo "=================================================================="
    echo " [OK] HỆ THỐNG WIPTER ĐÃ KHỞI CHẠY VỚI ${TOTAL_PROXIES} NODES!"
    echo " • Bảng chẩn đoán chi tiết:  wipter doctor"
    echo " • Xem logs telemetry     :  wipter logs"
    echo " • Xem mức tiêu thụ RAM   :  wipter stats"
    echo " • Dừng hệ thống          :  wipter stop"
    echo "=================================================================="
    ;;

  doctor|check)
    DIAG_PORT="${WIPTER_DIAGNOSTIC_HOST_PORT:-28999}"
    if ! command -v curl >/dev/null 2>&1; then
      echo "[LỖI] Thiếu curl để gọi diagnostic API. Cài bằng: apt-get update && apt-get install -y curl"
      exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo "[LỖI] Thiếu jq để hiển thị bảng doctor. Cài bằng: apt-get update && apt-get install -y jq"
      exit 1
    fi

    RAW_JSON=$(curl -s -m 2 "http://127.0.0.1:${DIAG_PORT}/status" 2>/dev/null || echo "")
    if [ -z "$RAW_JSON" ]; then
      echo "[LỖI] Không thể kết nối tới Wipter Engine. Hãy chắc chắn container đang chạy (wipter start)."
      exit 1
    fi

    C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_C='\033[1;36m'; C_0='\033[0m'

    TOTAL=$(echo "$RAW_JSON" | jq -r '.total // 0')
    ONLINE=$(echo "$RAW_JSON" | jq -r '.online // 0')
    DEAD=$(echo "$RAW_JSON" | jq -r '.dead_isolated // 0')
    TOTAL_BYTES=$(echo "$RAW_JSON" | jq -r '.total_bytes // 0')
    TOTAL_MB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_BYTES/1048576}")
    HOST_TOTAL=$(echo "$RAW_JSON" | jq -r '.host_total_mb // 0')
    HOST_AVAIL=$(echo "$RAW_JSON" | jq -r '.host_avail_mb // 0')
    ZONE=$(echo "$RAW_JSON" | jq -r '.pressure_zone // "UNKNOWN"')
    ACTIVE_CONN=$(echo "$RAW_JSON" | jq -r '.active_connections // 0')
    MAX_CONN=$(echo "$RAW_JSON" | jq -r '.max_conn_global // 0')
    BLOCK_PRIVATE=$(echo "$RAW_JSON" | jq -r '.block_private_targets // true')
    APP_VERSION=$(echo "$RAW_JSON" | jq -r '.configured_app_version // "unknown"')
    UPTIME=$(echo "$RAW_JSON" | jq -r '.engine_uptime_sec // 0')

    echo -e "\n${C_C}========================= [BẢNG CHẨN ĐOÁN CHI TIẾT TỪNG NODE WIPTER] =========================${C_0}"
    echo -e " [TÌNH TRẠNG RAM VPS] : ${C_G}Trống ${HOST_AVAIL}MB / Tổng ${HOST_TOTAL}MB${C_0} | [VÙNG CO GIÃN]: ${C_Y}${ZONE}${C_0} | Conn: ${ACTIVE_CONN}/${MAX_CONN} | BlockPrivate: ${BLOCK_PRIVATE} | AppVer: ${APP_VERSION} | Uptime: ${UPTIME}s"
    echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
    printf " %-9s %-22s %-14s %-18s %-10s %-7s %-5s %-5s %-22s %s\n" "NODE ID" "PROXY IP:PORT" "HOSTNAME" "STATUS" "RELAY" "CONN" "FAIL" "TUN" "ERR_CODE" "GHI CHÚ"
    echo "------------------------------------------------------------------------------------------------------------------------------------------------------"

    echo "$RAW_JSON" | jq -c '.nodes[]' 2>/dev/null | while IFS= read -r node; do
      id=$(echo "$node" | jq -r '.id')
      host=$(echo "$node" | jq -r '.proxy_host')
      dev=$(echo "$node" | jq -r '.device_name')
      st=$(echo "$node" | jq -r '.status')
      relay_mb=$(echo "$node" | jq -r 'if (.relay_mb // "") == "" then ((.relay_bytes // 0) / 1048576 | tostring) else .relay_mb end')
      relay_mb=$(awk -v mb="$relay_mb" 'BEGIN {printf "%.2f", mb}')
      conn=$(echo "$node" | jq -r '.active_connections // 0')
      fail=$(echo "$node" | jq -r '.fail_count // 0')
      tun=$(echo "$node" | jq -r '.tunnel_restarts // 0')
      code=$(echo "$node" | jq -r '.last_error_code // ""')
      err=$(echo "$node" | jq -r '.last_error // ""')

      if [[ "$st" == "ONLINE" ]]; then
        st_text="${C_G}ONLINE${C_0}"
      elif [[ "$st" == "REG_REJECTED" || "$st" == "DEAD_QUARANTINE" || "$st" == "TUNNEL_CONFIG_ERROR" ]]; then
        st_text="${C_R}${st}${C_0}"
      else
        st_text="${C_Y}${st}${C_0}"
      fi

      printf " Node %03d  %-22s %-14s %-27b %-10s %-7s %-5s %-5s %-22s %s\n" "$id" "$host" "$dev" "$st_text" "${relay_mb}MB" "$conn" "$fail" "$tun" "${code:0:22}" "${err:0:64}"
    done

    echo "------------------------------------------------------------------------------------------------------------------------------------------------------"
    PERCENT="0.0%"
    if (( TOTAL > 0 )); then
      PERCENT=$(awk "BEGIN {printf \"%.1f%%\", ($ONLINE/$TOTAL)*100}")
    fi
    echo -e " ${C_G}TỔNG KẾT: ${ONLINE}/${TOTAL} Nodes ONLINE (${PERCENT})${C_0} | ${C_R}${DEAD} Nodes DEAD (Đang cách ly)${C_0} | Băng thông: ${TOTAL_MB} MB"
    echo " Status counts: $(echo "$RAW_JSON" | jq -c '.status_counts // {}')"
    echo " Error counts : $(echo "$RAW_JSON" | jq -c '.error_counts // {}')"
    echo -e "${C_C}===============================================================================================================${C_0}\n"
    ;;

  version)
    echo "WipterHUB build: ${BUILD_ID}"
    [ -f "$DIR/VERSION" ] && cat "$DIR/VERSION"
    ;;

  json|status-json)
    DIAG_PORT="${WIPTER_DIAGNOSTIC_HOST_PORT:-28999}"
    if ! command -v curl >/dev/null 2>&1; then
      echo "[LỖI] Thiếu curl để gọi diagnostic API. Cài bằng: apt-get update && apt-get install -y curl"
      exit 1
    fi
    if command -v jq >/dev/null 2>&1; then
      curl -s -m 2 "http://127.0.0.1:${DIAG_PORT}/status" | jq .
    else
      curl -s -m 2 "http://127.0.0.1:${DIAG_PORT}/status"
      echo
    fi
    ;;

  health)
    DIAG_PORT="${WIPTER_DIAGNOSTIC_HOST_PORT:-28999}"
    curl -s -m 2 "http://127.0.0.1:${DIAG_PORT}/healthz" || true
    echo
    ;;

  errors)
    DIAG_PORT="${WIPTER_DIAGNOSTIC_HOST_PORT:-28999}"
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
      echo "[LỖI] Cần curl và jq để chạy errors."
      exit 1
    fi
    curl -s -m 2 "http://127.0.0.1:${DIAG_PORT}/status" | jq '{status_counts,error_counts,nodes:[.nodes[] | {id,proxy_host,status,last_error_code,last_error,diagnosis_hint,fail_count,tunnel_restarts,relay_mb,active_connections}]}'
    ;;

  collect|diagnose)
    DIAG_PORT="${WIPTER_DIAGNOSTIC_HOST_PORT:-28999}"
    TS="$(date +%Y%m%d-%H%M%S)"
    OUT_DIR="$DIR/wipter-diagnostics-$TS"
    OUT_TGZ="$DIR/wipter-diagnostics-$TS.tar.gz"
    mkdir -p "$OUT_DIR"

    {
      echo "timestamp=$TS"
      echo "pwd=$DIR"
      echo "kernel=$(uname -a)"
      echo "disk=$(df -h . | tail -1)"
    } > "$OUT_DIR/system.txt" 2>&1 || true

    if command -v docker >/dev/null 2>&1; then
      docker ps -a --filter "name=wipter-standalone-hub" > "$OUT_DIR/docker-ps.txt" 2>&1 || true
      docker inspect wipter-standalone-hub > "$OUT_DIR/docker-inspect.json" 2>&1 || true
      docker stats --no-stream wipter-standalone-hub > "$OUT_DIR/docker-stats.txt" 2>&1 || true
      docker logs --tail=500 wipter-standalone-hub > "$OUT_DIR/docker-logs-tail.txt" 2>&1 || true
      docker image ls wipter-engine > "$OUT_DIR/docker-image.txt" 2>&1 || true
    fi

    if command -v curl >/dev/null 2>&1; then
      curl -s -m 3 "http://127.0.0.1:${DIAG_PORT}/healthz" > "$OUT_DIR/healthz.txt" 2>&1 || true
      curl -s -m 3 "http://127.0.0.1:${DIAG_PORT}/status" > "$OUT_DIR/status.json" 2>&1 || true
    fi

    if command -v jq >/dev/null 2>&1 && [ -s "$OUT_DIR/status.json" ]; then
      jq '{summary:{total,online,dead_isolated,total_mb,avg_mb_per_loaded_node,nodes_with_traffic,status_counts,error_counts,configured_app_version,engine_uptime_sec},nodes:[.nodes[] | {id,proxy_host,status,last_error_code,last_error,diagnosis_hint,fail_count,tunnel_restarts,relay_mb,active_connections,updated_at,status_since}]}' "$OUT_DIR/status.json" > "$OUT_DIR/status-summary.json" 2>/dev/null || true
    fi

    bash "$DIR/wipter.sh" doctor > "$OUT_DIR/doctor.txt" 2>&1 || true

    {
      echo "# sanitized config.env"
      sed -E 's/^(WIPTER_PASSWORD)=.*/\1="***"/; s/^(WIPTER_EMAIL)=.*/\1="***"/' "$DIR/config.env" 2>/dev/null || true
    } > "$OUT_DIR/config-sanitized.env"

    {
      echo "proxy_lines=$(grep -cve '^#' -e '^$' "$DIR/proxies.txt" 2>/dev/null || echo 0)"
      awk 'NF && $0 !~ /^#/ {print NR ":" $0}' "$DIR/proxies.txt" 2>/dev/null | sed -E 's#(socks5h?://)?([^:@/]+):([^@/]+)@#\1***:***@#' | head -200
    } > "$OUT_DIR/proxies-summary.txt"

    tar -czf "$OUT_TGZ" -C "$DIR" "$(basename "$OUT_DIR")"
    rm -rf "$OUT_DIR"
    echo "[OK] Đã tạo gói chẩn đoán: $OUT_TGZ"
    echo "Gửi file này hoặc chạy: tar -tzf $OUT_TGZ"
    ;;

  stop)
    echo "[INFO] Đang dừng Wipter Engine an toàn..."
    docker stop -t 10 wipter-standalone-hub 2>/dev/null || true
    docker rm -f wipter-standalone-hub 2>/dev/null || true
    echo "[OK] Đã dừng hoàn toàn."
    ;;

  restart)
    bash "$DIR/wipter.sh" stop
    sleep 2
    bash "$DIR/wipter.sh" start
    ;;

  logs)
    docker logs -f --tail=100 wipter-standalone-hub
    ;;

  stats)
    docker stats --no-stream wipter-standalone-hub
    ;;

  status)
    docker ps --filter "name=wipter-standalone-hub" --format "table {{.Names}}\t{{.Status}}\t{{.RunningFor}}"
    ;;

  *)
    echo "Cách dùng: wipter {start|stop|restart|logs|stats|doctor|json|errors|health|collect|version}"
    exit 1
    ;;
esac
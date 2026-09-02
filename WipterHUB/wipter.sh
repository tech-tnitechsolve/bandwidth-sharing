#!/usr/bin/env bash
# ==============================================================================
# WIPTER STANDALONE HUB - MASTER CONTROLLER (AUTO-ENV & IP-AUTH READY)
# ==============================================================================
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

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

    HOST_IP=$(curl -s4 -m 3 https://api.ipify.org || curl -s4 -m 3 https://icanhazip.com || echo "Unknown")
    echo " • Public IPv4 (IP-Auth Whitelist) : $HOST_IP"
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
    chmod 666 "$DIR/devices_state.json" 2>/dev/null || true
    ulimit -n 65535 2>/dev/null || true

    echo " • Đang kiểm tra & Build Docker Image..."
    docker build -t wipter-engine:latest "$DIR" >/dev/null

    docker rm -f wipter-standalone-hub 2>/dev/null || true
    
    echo " • Đang khởi chạy Wipter Hub..."
    docker run -d \
      --name wipter-standalone-hub \
      --net=host \
      --restart always \
      --log-driver json-file \
      --log-opt max-size=5m \
      --log-opt max-file=2 \
      --ulimit nofile=65535:65535 \
      -v "$DIR/proxies.txt:/app/proxies.txt:ro" \
      -v "$DIR/devices_state.json:/app/devices_state.json:rw" \
      -e WIPTER_EMAIL="$WIPTER_EMAIL" \
      -e WIPTER_PASSWORD="$WIPTER_PASSWORD" \
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
    RAW_JSON=$(curl -s -m 2 http://127.0.0.1:28999/status 2>/dev/null || echo "")
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

    echo -e "\n${C_C}========================= [BẢNG CHẨN ĐOÁN CHI TIẾT TỪNG NODE WIPTER] =========================${C_0}"
    echo -e " [TÌNH TRẠNG RAM VPS] : ${C_G}Trống ${HOST_AVAIL}MB / Tổng ${HOST_TOTAL}MB${C_0} | [VÙNG CO GIÃN]: ${C_Y}${ZONE}${C_0}"
    echo "---------------------------------------------------------------------------------------------------------------"
    printf " %-9s %-22s %-16s %-18s %-12s %s\n" "NODE ID" "PROXY IP:PORT" "HOSTNAME" "STATUS" "RELAY DATA" "GHI CHÚ / NGUYÊN NHÂN LỖI"
    echo "---------------------------------------------------------------------------------------------------------------"

    echo "$RAW_JSON" | jq -c '.nodes[]' 2>/dev/null | while IFS= read -r node; do
      id=$(echo "$node" | jq -r '.id')
      host=$(echo "$node" | jq -r '.proxy_host')
      dev=$(echo "$node" | jq -r '.device_name')
      st=$(echo "$node" | jq -r '.status')
      bytes=$(echo "$node" | jq -r '.relay_bytes')
      mb=$(awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}")
      err=$(echo "$node" | jq -r '.last_error')

      if [[ "$st" == "ONLINE" ]]; then
        st_text="${C_G}ONLINE (ALIVE)${C_0}"
      elif [[ "$st" == "DEAD_QUARANTINE" ]]; then
        st_text="${C_R}DEAD (ISOLATED)${C_0}"
      else
        st_text="${C_Y}${st}${C_0}"
      fi

      printf " Node %03d  %-22s %-16s %-28b %-12s %s\n" "$id" "$host" "$dev" "$st_text" "$mb" "${err:0:38}"
    done

    echo "---------------------------------------------------------------------------------------------------------------"
    PERCENT="0.0%"
    if (( TOTAL > 0 )); then
      PERCENT=$(awk "BEGIN {printf \"%.1f%%\", ($ONLINE/$TOTAL)*100}")
    fi
    echo -e " ${C_G}TỔNG KẾT: ${ONLINE}/${TOTAL} Nodes ONLINE (${PERCENT})${C_0} | ${C_R}${DEAD} Nodes DEAD (Đang cách ly)${C_0} | Băng thông: ${TOTAL_MB} MB"
    echo -e "${C_C}===============================================================================================================${C_0}\n"
    ;;

  stop)
    echo "[INFO] Đang dừng Wipter Engine an toàn..."
    docker stop -t 10 wipter-standalone-hub 2>/dev/null || true
    docker rm -f wipter-standalone-hub 2>/dev/null || true
    echo "[OK] Đã dừng hoàn toàn."
    ;;

  restart)
    $0 stop
    sleep 2
    $0 start
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
    echo "Cách dùng: wipter {start|stop|restart|logs|stats|doctor}"
    exit 1
    ;;
esac
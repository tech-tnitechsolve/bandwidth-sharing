#!/usr/bin/env bash
# VPS Network Capacity Audit
# Mục đích duy nhất: xác định bandwidth VPS có đủ tải cho các IP/container đang chạy hay không.
# Passive-only: chỉ đọc traffic thật; không tạo benchmark hay gọi endpoint bên ngoài.
# Chạy:
#   sudo bash vps-network-audit.sh              # đo 24 giờ
#   sudo bash vps-network-audit.sh 259200       # đo 72 giờ

set -Eeuo pipefail

DURATION="${1:-86400}"
INTERVAL=60
IFACE="${IFACE:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')}"
PORT_MBPS=200
SAFE_LIMIT_MBPS=160
LOG_DIR="${HOME}/vps-network-audit-$(date +%F-%H%M%S)"

if [[ $EUID -ne 0 ]]; then
  echo "Chạy bằng: sudo bash $0 [SECONDS]"
  exit 1
fi

if [[ -z "${IFACE}" ]]; then
  echo "Không xác định được network interface."
  exit 1
fi

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || (( DURATION < 60 )); then
  echo "SECONDS phải là số >= 60. Ví dụ: sudo bash $0 86400"
  exit 1
fi

# Chỉ giữ log tối đa 7 ngày; không đụng tới thư mục khác.
find "$HOME" -maxdepth 1 -mindepth 1 -type d -name 'vps-network-audit-*' -mtime +7 -exec rm -rf -- {} + 2>/dev/null || true
mkdir -p "$LOG_DIR"

install_missing_packages() {
  local packages=(vnstat sysstat ethtool iproute2 procps)
  local missing=()
  local package

  for package in "${packages[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed'; then
      missing+=("$package")
    fi
  done

  if ((${#missing[@]})); then
    echo "Cài package còn thiếu: ${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  else
    echo "Đã có đủ package cần thiết; bỏ qua apt update/install."
  fi

  systemctl enable --now vnstat >/dev/null 2>&1 || true
  vnstat --add -i "$IFACE" >/dev/null 2>&1 || true
}

cleanup() {
  echo
  echo "Đã dừng đo. Log: $LOG_DIR"
}
trap cleanup EXIT INT TERM

install_missing_packages

# Không sử dụng proxy environment. Script chỉ đọc counter/connection local.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy || true

RAW_LOG="$LOG_DIR/raw.log"
SUMMARY_LOG="$LOG_DIR/summary.csv"

printf 'time,rx_kB_s,tx_kB_s,rx_Mbps,tx_Mbps,established,load1,ram_available_MiB,rx_drop,tx_drop,rx_err,tx_err\n' > "$SUMMARY_LOG"

get_counters() {
  ip -s link show "$IFACE" | awk '
    /RX:/ {getline; rxerr=$3; rxdrop=$4}
    /TX:/ {getline; txerr=$3; txdrop=$4}
    END {printf "%s %s %s %s", rxdrop+0, txdrop+0, rxerr+0, txerr+0}'
}

get_sar_values() {
  sar -n DEV 1 1 2>/dev/null | awk -v iface="$IFACE" '$2==iface {rx=$5; tx=$6} END {printf "%s %s", rx+0, tx+0}'
}

# Passive-only mode: no iperf3/speedtest/ping/curl/wget and no external probes.
# This intentionally measures only live VPS/container traffic so it cannot consume
# bandwidth or CPU needed by the running proxy containers.

START=$(date +%s)
END=$((START + DURATION))
COUNT=0

{
  echo "===== VPS NETWORK CAPACITY AUDIT ====="
  date
  echo "Interface: $IFACE"
  echo "Port advertised: ${PORT_MBPS} Mbps"
  echo "Safe working limit: ${SAFE_LIMIT_MBPS} Mbps"
  echo "Duration: ${DURATION}s"
  echo "Mode: read-only workload monitoring"
  echo
  ip -br addr show "$IFACE"
  ethtool "$IFACE" 2>/dev/null | grep -E 'Speed|Duplex|Link detected' || true
  echo
} | tee "$LOG_DIR/system-info.txt"

while (( $(date +%s) < END )); do
  NOW=$(date '+%F %T')
  SAR_VALUES=$(get_sar_values)
  RX_KB=$(awk '{print $1}' <<< "$SAR_VALUES")
  TX_KB=$(awk '{print $2}' <<< "$SAR_VALUES")
  RX_MBPS=$(awk -v x="$RX_KB" 'BEGIN {printf "%.3f", x*8/1000}')
  TX_MBPS=$(awk -v x="$TX_KB" 'BEGIN {printf "%.3f", x*8/1000}')

  ESTABLISHED=$(ss -Htan state established 2>/dev/null | wc -l)
  LOAD1=$(awk '{print $1}' /proc/loadavg)
  RAM_AVAILABLE=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
  read -r RX_DROP TX_DROP RX_ERR TX_ERR <<< "$(get_counters)"
  CONTAINERS=$(docker ps -q 2>/dev/null | wc -l || true)

  # Snapshot network cumulative per container/proxy. This is read-only and does
  # not create traffic. The container name is used as the proxy identifier.
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    {
      echo "timestamp,container,net_io"
      docker stats --no-stream --format "$(date '+%F %T'),{{.Name}},{{.NetIO}}" 2>/dev/null || true
    } > "$LOG_DIR/container-net-${COUNT}.csv"
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$NOW" "$RX_KB" "$TX_KB" "$RX_MBPS" "$TX_MBPS" "$ESTABLISHED" \
    "$LOAD1" "$RAM_AVAILABLE" "$RX_DROP" "$TX_DROP" "$RX_ERR" "$TX_ERR" >> "$SUMMARY_LOG"

  {
    echo "===== $NOW ====="
    echo "eth0 RX: ${RX_MBPS} Mbps | TX: ${TX_MBPS} Mbps | Total: $(awk -v a="$RX_MBPS" -v b="$TX_MBPS" 'BEGIN {printf "%.3f", a+b}') Mbps"
    echo "Port: ${PORT_MBPS} Mbps | Safe limit: ${SAFE_LIMIT_MBPS} Mbps"
    echo "Established: $ESTABLISHED | Containers: $CONTAINERS | Load: $LOAD1 | RAM available: ${RAM_AVAILABLE} MiB"
    echo "Drops RX/TX: $RX_DROP/$TX_DROP | Errors RX/TX: $RX_ERR/$TX_ERR"
    echo "vnStat: $(vnstat --oneline -i "$IFACE" 2>/dev/null || true)"
    echo
  } | tee -a "$RAW_LOG"

  COUNT=$((COUNT + 1))
  sleep "$INTERVAL"
done

# Tổng hợp số liệu để quyết định có nên thêm IP hay nâng port.
awk -F, -v port="$PORT_MBPS" -v safe="$SAFE_LIMIT_MBPS" '
  NR>1 {
    rx_sum+=$4; tx_sum+=$5; total_sum+=($4+$5); n++
    if ($4>rx_max) rx_max=$4
    if ($5>tx_max) tx_max=$5
    if (($4+$5)>total_max) total_max=($4+$5)
    if ($6>conn_max) conn_max=$6
    if ($9>rx_drop_max) rx_drop_max=$9
    if ($10>tx_drop_max) tx_drop_max=$10
    if ($11>rx_err_max) rx_err_max=$11
    if ($12>tx_err_max) tx_err_max=$12
  }
  END {
    if (n==0) exit 1
    printf "samples=%d\n", n
    printf "average_rx_mbps=%.3f\n", rx_sum/n
    printf "average_tx_mbps=%.3f\n", tx_sum/n
    printf "average_total_mbps=%.3f\n", total_sum/n
    printf "peak_rx_mbps=%.3f\n", rx_max
    printf "peak_tx_mbps=%.3f\n", tx_max
    printf "peak_total_mbps=%.3f\n", total_max
    printf "peak_established=%d\n", conn_max
    printf "max_rx_drop=%d\n", rx_drop_max
    printf "max_tx_drop=%d\n", tx_drop_max
    printf "max_rx_error=%d\n", rx_err_max
    printf "max_tx_error=%d\n", tx_err_max
    printf "port_mbps=%d\n", port
    printf "safe_limit_mbps=%d\n", safe
    if (total_max < safe && rx_drop_max==0 && tx_drop_max==0 && rx_err_max==0 && tx_err_max==0)
      print "verdict=ENOUGH_BANDWIDTH__CAN_CONSIDER_ADDING_IPS"
    else if (total_max < port && rx_drop_max==0 && tx_drop_max==0)
      print "verdict=WORKING__BUT_LIMITED_HEADROOM"
    else
      print "verdict=INSUFFICIENT_OR_NETWORK_ERRORS__DO_NOT_ADD_IPS_YET"
  }
' "$SUMMARY_LOG" | tee "$LOG_DIR/final-verdict.txt"

echo
 echo "===== TRAFFIC HISTORY ====="
vnstat -h -i "$IFACE" | tee "$LOG_DIR/hourly.txt" || true
vnstat -d -i "$IFACE" | tee "$LOG_DIR/daily.txt" || true

echo
echo "Hoàn tất. Kết quả quyết định nằm tại:"
echo "$LOG_DIR/final-verdict.txt"

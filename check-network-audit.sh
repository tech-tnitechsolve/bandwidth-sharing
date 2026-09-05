#!/usr/bin/env bash
# Passive VPS/proxy capacity audit. No speedtest, iperf3, ping, curl or wget.
# It only reads VPS/Docker counters, so it does not create traffic or call proxies.
# Usage: sudo bash check-network-audit.sh [SECONDS]

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Chạy: sudo bash $0 --install"; exit 1; }

MODE="${1:-}"
DURATION="${1:-86400}"
# Đo mỗi 5 phút để giảm tối đa CPU/Docker API overhead trên VPS nhiều container.
INTERVAL=300

if [[ "$MODE" == "--install" ]]; then
  SCRIPT_PATH="$(readlink -f "$0")"
  cat > /etc/systemd/system/check-network-audit.service <<UNIT
[Unit]
Description=Passive VPS Network and Proxy Capacity Audit
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash $SCRIPT_PATH 86400
Restart=always
RestartSec=10
Nice=19
IOSchedulingClass=idle
NoNewPrivileges=false
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now check-network-audit.service
  echo "Đã cài và khởi động check-network-audit.service"
  echo "Xem realtime bằng: sudo journalctl -fu check-network-audit.service"
  exit 0
fi
PORT_MBPS="${PORT_MBPS:-200}"
SAFE_LIMIT_MBPS="${SAFE_LIMIT_MBPS:-160}"
IFACE="${IFACE:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')}"
LOG_ROOT="${LOG_ROOT:-/var/log/check-network-audit}"
RUN_DIR="$LOG_ROOT/$(date +%F-%H%M%S)"

[[ $EUID -eq 0 ]] || { echo "Chạy: sudo bash $0 [SECONDS]"; exit 1; }
[[ "$DURATION" =~ ^[0-9]+$ && "$DURATION" -ge 60 ]] || { echo "SECONDS phải >= 60"; exit 1; }
[[ -n "$IFACE" ]] || { echo "Không xác định được network interface"; exit 1; }

mkdir -p "$LOG_ROOT" "$RUN_DIR"
find "$LOG_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf -- {} + 2>/dev/null || true

install_missing() {
  local p missing=()
  for p in vnstat sysstat ethtool iproute2 procps python3; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  if ((${#missing[@]})); then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
  systemctl enable --now vnstat >/dev/null 2>&1 || true
  vnstat --add -i "$IFACE" >/dev/null 2>&1 || true
}
install_missing

# Kiểm tra Docker một lần, không gọi docker info lặp lại mỗi chu kỳ.
DOCKER_OK=0
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DOCKER_OK=1
fi

# Không dùng proxy environment; toàn bộ phép đo dưới đây là local/read-only.
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy || true

SUMMARY="$RUN_DIR/summary.csv"
PROXY_LOG="$RUN_DIR/proxy-network.csv"
RAW="$RUN_DIR/raw.log"
ALERTS="$RUN_DIR/alerts.log"
STATE="$RUN_DIR/.container-state.tsv"
PREV_COUNTERS="$RUN_DIR/.interface-counters"

printf 'time,rx_kB_s,tx_kB_s,rx_Mbps,tx_Mbps,total_Mbps,established,load1,ram_available_MiB,rx_drop_delta,tx_drop_delta,rx_error_delta,tx_error_delta\n' > "$SUMMARY"
printf 'time,type,details\n' > "$ALERTS"
printf 'time,container,id,rx_bytes_delta,tx_bytes_delta,rx_Mbps,tx_Mbps,total_Mbps,net_io_raw\n' > "$PROXY_LOG"

interface_counters() {
  ip -s link show "$IFACE" | awk '
    /RX:/ {getline; rxdrop=$4; rxerr=$3}
    /TX:/ {getline; txdrop=$4; txerr=$3}
    END {printf "%s %s %s %s\n", rxdrop+0, txdrop+0, rxerr+0, txerr+0}'
}

read -r OLD_RX_DROP OLD_TX_DROP OLD_RX_ERR OLD_TX_ERR < <(interface_counters)

# Parse one docker stats snapshot, calculate deltas and append one compact CSV.
parse_containers() {
  local now="$1" snap="$RUN_DIR/.docker-snapshot"
  if (( DOCKER_OK == 0 )); then
    return 0
  fi
  docker stats --no-stream --format '{{.Name}}|{{.ID}}|{{.NetIO}}' > "$snap" 2>/dev/null || return 0
  python3 - "$snap" "$STATE" "$PROXY_LOG" "$now" "$INTERVAL" <<'PY'
import sys, re, json, time
snap, statefile, out, now, interval = sys.argv[1:]
interval=float(interval)
try:
    with open(statefile) as f: old=json.load(f)
except Exception: old={}

def num(s):
    s=s.strip().replace(',','')
    m=re.match(r'^([0-9.]+)\s*([KMGTPE]?i?B)?$',s,re.I)
    if not m: return 0
    n=float(m.group(1)); u=(m.group(2) or 'B').upper().replace('IB','B')
    mult={'B':1,'KB':1000,'MB':1000**2,'GB':1000**3,'TB':1000**4,'PB':1000**5,'EB':1000**6}.get(u,1)
    return int(n*mult)
new={}
with open(snap, errors='replace') as f, open(out,'a') as w:
    for line in f:
        parts=line.rstrip('\n').split('|',2)
        if len(parts)!=3: continue
        name,cid,net=parts
        sides=net.split('/')
        if len(sides)!=2: continue
        rx,tx=num(sides[0]),num(sides[1])
        new[cid]=[name,rx,tx]
        if cid in old:
            dr=max(0,rx-old[cid][1]); dt=max(0,tx-old[cid][2])
            rm=dr*8/interval/1e6; tm=dt*8/interval/1e6
            w.write(f'{now},{name},{cid},{dr},{dt},{rm:.3f},{tm:.3f},{rm+tm:.3f},{net}\n')
with open(statefile,'w') as f: json.dump(new,f)
PY
}

get_sar() {
  sar -n DEV 1 1 2>/dev/null | awk -v i="$IFACE" '$2==i {rx=$5;tx=$6} END{printf "%.3f %.3f\n",rx+0,tx+0}'
}

START=$(date +%s); END=$((START+DURATION)); COUNT=0
{
  echo "===== PASSIVE VPS/PROXY CAPACITY AUDIT ====="
  date
  echo "Interface: $IFACE | Port: ${PORT_MBPS} Mbps | Safe limit: ${SAFE_LIMIT_MBPS} Mbps"
  echo "Mode: local counters only; no external traffic"
  ip -br addr show "$IFACE"
  ethtool "$IFACE" 2>/dev/null | grep -E 'Speed|Duplex|Link detected' || true
} | tee "$RUN_DIR/system-info.txt"

while (( $(date +%s) < END )); do
  NOW=$(date '+%F %T')
  read -r RX_KB TX_KB < <(get_sar)
  RX_MBPS=$(awk -v x="$RX_KB" 'BEGIN{printf "%.3f",x*8/1000}')
  TX_MBPS=$(awk -v x="$TX_KB" 'BEGIN{printf "%.3f",x*8/1000}')
  TOTAL_MBPS=$(awk -v a="$RX_MBPS" -v b="$TX_MBPS" 'BEGIN{printf "%.3f",a+b}')
  EST=$(ss -Htan state established 2>/dev/null | wc -l)
  LOAD=$(awk '{print $1}' /proc/loadavg)
  RAM=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo)
  read -r RD TD RE TE < <(interface_counters)
  DR=$((RD-OLD_RX_DROP)); DT=$((TD-OLD_TX_DROP)); DE=$((RE-OLD_RX_ERR)); DF=$((TE-OLD_TX_ERR))
  ((DR<0)) && DR=0; ((DT<0)) && DT=0; ((DE<0)) && DE=0; ((DF<0)) && DF=0
  OLD_RX_DROP=$RD; OLD_TX_DROP=$TD; OLD_RX_ERR=$RE; OLD_TX_ERR=$TE
  parse_containers "$NOW"
  CONTAINERS=0
  (( DOCKER_OK == 1 )) && CONTAINERS=$(docker ps -q 2>/dev/null | wc -l || true)
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$NOW" "$RX_KB" "$TX_KB" "$RX_MBPS" "$TX_MBPS" "$TOTAL_MBPS" "$EST" "$LOAD" "$RAM" "$DR" "$DT" "$DE" "$DF" >> "$SUMMARY"
  printf '%s RX=%s Mbps TX=%s Mbps Total=%s Mbps EST=%s Containers=%s Drops=%s/%s Errors=%s/%s Load=%s RAM=%sMiB\n' "$NOW" "$RX_MBPS" "$TX_MBPS" "$TOTAL_MBPS" "$EST" "$CONTAINERS" "$DR" "$DT" "$DE" "$DF" "$LOAD" "$RAM" | tee -a "$RAW"
  if awk -v x="$TOTAL_MBPS" -v lim="$SAFE_LIMIT_MBPS" 'BEGIN{exit !(x>=lim)}'; then
    printf '%s,BANDWIDTH_NEAR_LIMIT,total=%sMbps safe_limit=%sMbps\n' "$NOW" "$TOTAL_MBPS" "$SAFE_LIMIT_MBPS" | tee -a "$ALERTS"
  fi
  if ((DR>0 || DT>0 || DE>0 || DF>0)); then
    printf '%s,NETWORK_ERRORS,drops_rx=%s drops_tx=%s errors_rx=%s errors_tx=%s\n' "$NOW" "$DR" "$DT" "$DE" "$DF" | tee -a "$ALERTS"
  fi
  COUNT=$((COUNT+1)); sleep "$INTERVAL"
done

awk -F, -v port="$PORT_MBPS" -v safe="$SAFE_LIMIT_MBPS" '
NR>1 {n++; ar+=$4;at+=$5;aa+=$6; if($4>mr)mr=$4;if($5>mt)mt=$5;if($6>ma)ma=$6;if($10>rd)rd=$10;if($11>td)td=$11;if($12>re)re=$12;if($13>te)te=$13;if($7>ec)ec=$7}
END {if(!n)exit 1; printf "samples=%d\naverage_rx_mbps=%.3f\naverage_tx_mbps=%.3f\naverage_total_mbps=%.3f\npeak_rx_mbps=%.3f\npeak_tx_mbps=%.3f\npeak_total_mbps=%.3f\npeak_established=%d\nmax_rx_drop_delta=%d\nmax_tx_drop_delta=%d\nmax_rx_error_delta=%d\nmax_tx_error_delta=%d\nport_mbps=%d\nsafe_limit_mbps=%d\n",n,ar/n,at/n,aa/n,mr,mt,ma,ec,rd,td,re,te,port,safe; if(ma<safe&&rd==0&&td==0&&re==0&&te==0)print "verdict=VPS_CAPACITY_OK__CAN_CONSIDER_MORE_PROXIES"; else if(ma<port&&rd==0&&td==0)print "verdict=VPS_WORKING__LIMITED_HEADROOM"; else print "verdict=VPS_BOTTLENECK_OR_NETWORK_ERRORS__DO_NOT_ADD_PROXIES"}' "$SUMMARY" | tee "$RUN_DIR/final-verdict.txt"

printf '\nLogs: %s\nProxy/container deltas: %s\n' "$RUN_DIR" "$PROXY_LOG"

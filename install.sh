#!/bin/bash
# =============================================================================
#  ORACLE FREE TIER — ANTI-RECLAIM v4 (FINAL)
#  VM.Standard.E2.1.Micro (1 CPU | 1GB RAM | AMD64)
#
#  CHIEN LUOC 3 LOP — CHAC AN NHAT:
#     Lop 1: lookbusy binary C (CPU 50% de bu steal time Oracle)
#     Lop 2: stress-ng fallback (neu lookbusy chet)
#     Lop 3: bash infinite loop (last resort)
#     Network: curl 30ph + speedtest Cloudflare 6h
#     Watchdog: kiem tra CPU moi 5ph, tu dieu chinh
#
#  CAI DAT:  sudo bash install.sh
#  GO BO:    sudo bash install.sh --uninstall
# =============================================================================

set -euo pipefail

G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'
C='\033[0;36m'; B='\033[1m'; N='\033[0m'
log()  { echo -e "  ${G}[✓]${N} $*"; }
warn() { echo -e "  ${Y}[!]${N} $*"; }
err()  { echo -e "  ${R}[✗]${N} $*"; }
info() { echo -e "  ${C}[i]${N} $*"; }
sep()  { echo -e "\n${B}${C}╔══ $* ══╗${N}"; }

[[ "$(id -u)" -ne 0 ]] && { echo "Can root. Dung: sudo bash install.sh"; exit 1; }

# =============================================================================
# UNINSTALL MODE
# =============================================================================
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    echo -e "${B}GO BO ORACLE ANTI-RECLAIM...${N}"
    for svc in oracle-keepalive oracle-netalive oracle-watchdog oracle-fallback; do
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
    pkill -9 -f lookbusy    2>/dev/null || true
    pkill -9 -f net-alive   2>/dev/null || true
    pkill -9 -f cpu-watchdog 2>/dev/null || true
    pkill -9 -f stress-ng   2>/dev/null || true
    rm -f /usr/local/bin/{lookbusy,net-alive.sh,cpu-watchdog.sh}
    rm -f /etc/systemd/system/oracle-{keepalive,netalive,watchdog,fallback}.service
    rm -f /var/log/{net-alive,oracle-watchdog}.log*
    tmp=$(mktemp)
    crontab -l 2>/dev/null | grep -v 'oracle\|lookbusy\|net-alive\|watchdog' > "$tmp" 2>/dev/null || true
    crontab "$tmp" 2>/dev/null || true; rm -f "$tmp"
    systemctl daemon-reload
    echo -e "${G}Da go bo hoan toan.${N}"
    exit 0
fi

# =============================================================================
# 1. PREFLIGHT
# =============================================================================
sep "1. Kiem tra moi truong"
command -v curl &>/dev/null  || { err "Thieu curl"; exit 1; }
command -v python3 &>/dev/null || { warn "Thieu python3, fallback se dung bash loop"; }
log "OK"

# =============================================================================
# 2. DON DEP
# =============================================================================
sep "2. Don dep cu"
for svc in oracle-keepalive oracle-netalive oracle-watchdog oracle-fallback oracle-cpu oracle-netalive2 oracle-neveridle; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done
for p in lookbusy NeverIdle stress-ng cpu-burn net-alive bypass_oracle cpu-watchdog; do
    pkill -9 -f "$p" 2>/dev/null && warn "dung: $p" || true
done
rm -f /tmp/{NeverIdle,NeverIdle.log,lookbusy,cpu-limit.pid}
rm -f /usr/local/bin/{lookbusy,net-alive.sh,cpu-burn.sh,bypass_oracle.sh,cpu-watchdog.sh}
rm -f /var/log/{net-alive,oracle-watchdog}.log*
rm -f /etc/systemd/system/oracle-*.service
tmp=$(mktemp)
crontab -l 2>/dev/null | grep -vE 'oracle|lookbusy|NeverIdle|net-alive|watchdog|bypass|cpu-burn' > "$tmp" 2>/dev/null || true
crontab "$tmp" 2>/dev/null || true; rm -f "$tmp"
[ -f /etc/crontab ] && sed -i '/lookbusy\|NeverIdle\|bypass\|oracle\|watchdog/d' /etc/crontab 2>/dev/null || true
systemctl daemon-reload
log "Sach se"

# =============================================================================
# 3. TAI LOOKBUSY — LOP 1 (CHINH)
# =============================================================================
sep "3. Lop 1: lookbusy binary (dot CPU that bang C)"
LOOKBUSY="/usr/local/bin/lookbusy"
curl -fsSL "https://raw.githubusercontent.com/velor2012/lookbusy-docker/main/lookbusy" -o "$LOOKBUSY"
chmod +x "$LOOKBUSY"
[ -x "$LOOKBUSY" ] && log "lookbusy OK" || { err "Tai that bai"; exit 1; }

# =============================================================================
# 4. SYSTEMD — LOP 1: lookbusy 50% (bu steal time ~80%)
#    Nice=19: uu tien thap nhat, ko anh huong app
# =============================================================================
cat > /etc/systemd/system/oracle-keepalive.service << 'UNIT'
[Unit]
Description=Oracle Anti-Reclaim L1 — lookbusy CPU
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/lookbusy -c 50 -n 1
Restart=always
RestartSec=10
Nice=19
IOSchedulingClass=idle
CPUQuota=60%

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now oracle-keepalive.service
log "L1 (lookbusy 50%): OK"

# =============================================================================
# 5. LOP 2: FALLBACK BASH LOOP (neu lookbusy chet)
# =============================================================================
sep "5. Lop 2: fallback (neu L1 chet)"
cat > /usr/local/bin/cpu-fallback.sh << 'FALLBACK'
#!/bin/bash
# Fallback CPU burner: bash loop + python3 (nhung hon)
while true; do
  python3 -c "for i in range(800000): _=i*2" 2>/dev/null || {
    for i in $(seq 1 50000); do :; done
  }
  sleep 0.6
done
FALLBACK
chmod +x /usr/local/bin/cpu-fallback.sh

cat > /etc/systemd/system/oracle-fallback.service << 'UNIT'
[Unit]
Description=Oracle Anti-Reclaim L2 — Fallback CPU
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cpu-fallback.sh
Restart=always
RestartSec=30
Nice=15

[Install]
WantedBy=multi-user.target
UNIT

# De fallback OFF mac dinh, chi bat khi L1 chet
systemctl daemon-reload
log "L2 (fallback): san sang (OFF mac dinh)"

# =============================================================================
# 6. LOP 3: WATCHDOG — theo doi CPU, tu dong kich hoat fallback
# =============================================================================
sep "6. Lop 3: Watchdog (kiem tra CPU moi 5ph)"
cat > /usr/local/bin/cpu-watchdog.sh << 'WATCHDOG'
#!/bin/bash
LOG="/var/log/oracle-watchdog.log"
MIN_CPU=10          # CPU < 10% → canh bao
CRIT_CPU=5          # CPU < 5%  → kich hoat fallback
CHECK_INTERVAL=300  # 5 phut

while true; do
  # Doc CPU trong 2 giay
  a1=$(awk '/^cpu /{print $2+$3+$4, $5}' /proc/stat)
  read act1 idle1 <<< "$a1"
  sleep 2
  a2=$(awk '/^cpu /{print $2+$3+$4, $5}' /proc/stat)
  read act2 idle2 <<< "$a2"
  d_act=$((act2 - act1)); d_idle=$((idle2 - idle1))
  CPU=$(( (d_act + d_idle) > 0 ? d_act * 100 / (d_act + d_idle) : 0 ))

  echo "[$(date '+%m-%d %H:%M')] CPU=${CPU}%" >> "$LOG"

  if [ "$CPU" -lt "$CRIT_CPU" ]; then
    echo "[$(date)] CRIT! CPU=${CPU}% — kich hoat fallback" >> "$LOG"
    systemctl start oracle-fallback.service 2>/dev/null || true
  elif [ "$CPU" -lt "$MIN_CPU" ]; then
    echo "[$(date)] WARN: CPU=${CPU}% < ${MIN_CPU}%" >> "$LOG"
  fi

  # Rotate log > 256KB
  [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ] && mv "$LOG" "${LOG}.bak"

  sleep "$CHECK_INTERVAL"
done
WATCHDOG
chmod +x /usr/local/bin/cpu-watchdog.sh

cat > /etc/systemd/system/oracle-watchdog.service << 'UNIT'
[Unit]
Description=Oracle Anti-Reclaim L3 — CPU Watchdog
After=oracle-keepalive.service
Requires=oracle-keepalive.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cpu-watchdog.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now oracle-watchdog.service
log "L3 (watchdog 5ph): OK"

# =============================================================================
# 7. NETWORK KEEPALIVE
# =============================================================================
sep "7. Network keepalive"
cat > /usr/local/bin/net-alive.sh << 'NET'
#!/bin/bash
LOG="/var/log/net-alive.log"
MAXSZ=$((512 * 1024))
SITES=("https://www.google.com" "https://www.youtube.com" "https://github.com"
       "https://stackoverflow.com" "https://httpbin.org/get" "https://1.1.1.1"
       "https://www.cloudflare.com" "https://news.ycombinator.com")
C=0
while true; do
  [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$MAXSZ" ] && mv "$LOG" "${LOG}.bak"
  SITE="${SITES[$RANDOM % ${#SITES[@]}]}"
  printf "[%s] %s\n" "$(date '+%m-%d %H:%M')" "$SITE" >> "$LOG"
  curl -s -o /dev/null --max-time 30 --connect-timeout 10 -L "$SITE" >> "$LOG" 2>&1
  C=$((C + 1))
  if [ $C -ge 12 ]; then
    printf "[%s] SPEEDTEST\n" "$(date '+%m-%d %H:%M')" >> "$LOG"
    curl -s -o /dev/null -m 60 "https://speed.cloudflare.com/__down?bytes=10000000" >> "$LOG" 2>&1 || true
    C=0
  fi
  sleep 1800
done
NET
chmod +x /usr/local/bin/net-alive.sh

cat > /etc/systemd/system/oracle-netalive.service << 'UNIT'
[Unit]
Description=Oracle Anti-Reclaim — Network
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/net-alive.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now oracle-netalive.service
log "Network (curl 30ph + speedtest 6h): OK"

# =============================================================================
# 8. KIEM TRA TONG THE
# =============================================================================
sep "8. Kiem tra"

sleep 5

# Doc CPU
a1=$(awk '/^cpu /{print $2+$3+$4, $5}' /proc/stat)
read act1 idle1 <<< "$a1"
sleep 2
a2=$(awk '/^cpu /{print $2+$3+$4, $5}' /proc/stat)
read act2 idle2 <<< "$a2"
d_act=$((act2 - act1)); d_idle=$((idle2 - idle1))
CPU=$(( (d_act + d_idle) > 0 ? d_act * 100 / (d_act + d_idle) : 0 ))

echo ""
echo -e "  ┌──────────────────────────────────────────────────┐"
echo -e "  │  ${B}KIEN TRUC 3 LOP CHONG ORACLE RECLAIM${N}            │"
echo -e "  ├──────────┬───────────────────────────────────────┤"
echo -e "  │ ${B}L1 CHINH ${N} │ lookbusy 50% CPU (Nice=19)          │"
echo -e "  │ ${B}L2 DU PHONG${N}│ bash/python loop — tu kich hoat     │"
echo -e "  │ ${B}L3 GIAM SAT${N}│ Watchdog 5ph — CPU <5% → kich L2    │"
echo -e "  │ ${B}NETWORK  ${N}│ curl 30ph + speedtest 6h             │"
echo -e "  └──────────┴───────────────────────────────────────┘"
echo ""

ok=0
for svc in oracle-keepalive oracle-netalive oracle-watchdog; do
    s=$(systemctl is-active "$svc" 2>/dev/null || echo "dead")
    if [ "$s" = "active" ]; then
        echo -e "  ${G}●${N} $svc → ${G}$s${N}"
        ok=$((ok + 1))
    else
        echo -e "  ${R}●${N} $svc → ${R}$s${N}"
    fi
done
echo ""
echo -e "  ${B}CPU hien tai: ${CPU}%${N}"
echo -e "  ${B}RAM:${N} $(free -m | awk '/Mem:/{printf "%d/%dMB",$3,$2}')"
echo ""

if [ "$ok" -ge 3 ]; then
    echo -e "  ${B}${G}╔══════════════════════════════════════╗${N}"
    echo -e "  ${B}${G}║  🟢  VPS AN TOAN TUYET DOI — 3 LOP  ║${N}"
    echo -e "  ${B}${G}╚══════════════════════════════════════╝${N}"
else
    echo -e "  ${R}[!] Co service chua chay. Kiem tra: systemctl status oracle-*${N}"
fi

echo ""
echo -e "  ${B}🔍 LENH THUONG DUNG:${N}"
echo "     bash check.sh                           # kiem tra nhanh"
echo "     systemctl status oracle-keepalive       # L1 CPU"
echo "     systemctl status oracle-watchdog        # L3 watchdog"
echo "     tail -f /var/log/oracle-watchdog.log    # log giam sat"
echo "     tail -f /var/log/net-alive.log          # log network"
echo ""
echo -e "  ${B}🧹 GO BO:${N}  sudo bash install.sh --uninstall"
echo ""

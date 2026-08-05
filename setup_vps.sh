#!/usr/bin/env bash
#============================================================================
#  setup_vps.sh - SETUP VPS CHAY 24/7 CHO INTERNETINCOME (NHANH test)
#
#  DAC DIEM:
#   - KHONG tu tai source: ban tu copy folder InternetIncome vao VPS
#     (toi uu cho chay NHIEU folder InternetIncome tren 1 VPS).
#   - Swap 50% RAM, toi uu kernel/Docker cho hang tram container proxy.
#   - (Tuy chon) cron restart hang ngay cho TAT CA folder trong 1 thu muc cha.
#
#  CACH DUNG:
#   sudo bash setup_vps.sh                         # se hoi thu muc cha de cai cron
#   sudo bash setup_vps.sh --base-dir /opt/ii      # cai cron luon, khong hoi
#   sudo bash setup_vps.sh --no-cron               # bo qua cron
#   sudo bash setup_vps.sh --no-pull               # bo qua pre-pull image docker
#   sudo bash setup_vps.sh --base-dir /opt/ii --no-pull
#============================================================================
set -Eeuo pipefail

#--------------------------------- MAU & LOG ---------------------------------
if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
log()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!!]${C_0} $*"; }
die()  { echo -e "${C_R}[XX]${C_0} $*"; exit 1; }

#--------------------------------- THAM SO -----------------------------------
BASE_DIR=""
DO_CRON=1
DO_PULL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-dir)   BASE_DIR="${2:-}"; shift 2 ;;
    --base-dir=*) BASE_DIR="${1#*=}"; shift ;;
    --no-cron)    DO_CRON=0; shift ;;
    --no-pull)    DO_PULL=0; shift ;;
    -h|--help)    grep '^#' "$0" | head -n 25; exit 0 ;;
    *) die "Tham so khong hop le: $1 (xem: bash $0 --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Can chay bang quyen root: sudo bash $0"
command -v apt-get >/dev/null 2>&1 || die "Script ho tro Debian/Ubuntu (apt-get)"

has_systemd() { command -v systemctl >/dev/null 2>/dev/null && [[ -d /run/systemd/system ]]; }

#------------------------------- THONG TIN HE THONG --------------------------
VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
IS_CONTAINER=0
case "$VIRT" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1 ;; esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)

SWAP_MB=$(( MEM_MB / 2 ))
if (( SWAP_MB < 1024 )); then SWAP_MB=1024; fi
if (( SWAP_MB > 8192 )); then SWAP_MB=8192; fi

if (( CPU <= 2 )); then
  CONCURRENT_DOWNLOADS=3; SYN_BACKLOG=8192
elif (( CPU <= 4 )); then
  CONCURRENT_DOWNLOADS=5; SYN_BACKLOG=16384
else
  CONCURRENT_DOWNLOADS=8; SYN_BACKLOG=32768
fi

echo "=============================================================="
echo "  VPS $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU | ao hoa: ${VIRT}"
echo "  swap=${SWAP_MB}MB | docker parallel downloads=${CONCURRENT_DOWNLOADS}"
echo "=============================================================="

#----------------------------------- 1. SWAP ---------------------------------
if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
  log "Da co swap -> bo qua"
elif (( IS_CONTAINER == 1 )); then
  warn "May ${VIRT} (container) thuong KHONG tao duoc swap -> bo qua"
else
  if ! fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
  fi
  chmod 600 /swapfile
  if mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Tao swap ${SWAP_MB}MB thanh cong"
  else
    rm -f /swapfile
    warn "Kernel khong cho tao swap -> bo qua (van chay duoc)"
  fi
fi

#------------------------------ 2. APT KHONG HOI -----------------------------
export DEBIAN_FRONTEND=noninteractive
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

log "apt update + upgrade..."
apt-get update -y -qq
apt-get upgrade -y -qq || true
apt-get install -y -qq --no-install-recommends \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools
log "Da cai goi co ban (curl/wget/git/jq/bc/cron/logrotate...)"

#--------------------------------- 3. DNS SACH -------------------------------
if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
fi
rm -f /etc/resolv.conf
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
log "resolv.conf -> 8.8.8.8 + 1.1.1.1 (khong chattr, de linh hoat)"

#------------------------------- 4. KERNEL TUNING ----------------------------
modprobe nf_conntrack 2>/dev/null || true
SYSCTL_FILE=/etc/sysctl.d/99-internetincome.conf
cat > "$SYSCTL_FILE" <<EOF
#--- InternetIncome tuning (nhieu container SOCKS5/UDP) ---
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576

net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0

net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

vm.swappiness = 10
vm.vfs_cache_pressure = 50

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue
  sysctl -w "$line" >/dev/null 2>&1 || true
done < "$SYSCTL_FILE"
log "Kernel tuning xong ($SYSCTL_FILE - dong khong ho tro tu bo qua)"

mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/99-nofile.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-ii-limit.conf <<'EOF'
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=20M
EOF
if has_systemd; then systemctl restart systemd-journald 2>/dev/null || true; fi
log "Gioi han journald 50MB + nofile 1048576"

#---------------------------------- 5. DOCKER --------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Cai dat Docker..."
  curl -fsSL https://get.docker.com | sh
else
  log "Docker da co san: $(docker --version 2>/dev/null || echo '?')"
fi

mkdir -p /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
  cp -f /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
fi
cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "dns": ["8.8.8.8", "1.1.1.1"],
  "max-concurrent-downloads": ${CONCURRENT_DOWNLOADS},
  "live-restore": true,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 }
  }
}
EOF

if has_systemd; then
  systemctl enable --now docker >/dev/null 2>&1 || true
  systemctl restart docker
else
  service docker start >/dev/null 2>&1 || service docker restart || true
fi
docker info >/dev/null 2>&1 || die "Docker khong chay duoc - kiem tra ao hoa/kernel"
log "Docker OK (log 10MBx3 | DNS 8.8.8.8+1.1.1.1 | live-restore on)"

#------------------------------- 6. PRE-PULL IMAGE ---------------------------
if (( DO_PULL == 1 )); then
  for img in "traffmonetizer/cli_v2:latest" "xjasonlyu/tun2socks:latest"; do
    if docker pull "$img" >/dev/null 2>&1; then
      log "pull OK: $img"
    else
      warn "pull loi: $img (se tu pull lai luc --start)"
    fi
  done
  if docker pull ghcr.io/xjasonlyu/tun2socks:latest >/dev/null 2>&1; then
    log "pull OK: ghcr.io/xjasonlyu/tun2socks (du phong)"
  fi
else
  log "Bo qua pre-pull (--no-pull)"
fi

#---------------------- 7. CRON RESTART NHIEU FOLDER -------------------------
install_cron_stack() {
  mkdir -p "$BASE_DIR"
  cat > /usr/local/bin/ii-restart-all.sh <<'EOS'
#!/usr/bin/env bash
# Restart TAT CA folder InternetIncome trong thu muc cha (folder co internetIncome.sh)
BASE_DIR="__BASE_DIR__"
LOG=/var/log/ii-restart.log
ts() { date '+%F %T'; }

{
  echo "[$(ts)] ============== ii-restart-all (base: ${BASE_DIR}) =============="
  found=0
  shopt -s nullglob
  for d in "${BASE_DIR}"/*/; do
    [[ -f "${d}internetIncome.sh" ]] || continue
    found=1
    echo "[$(ts)] >>> ${d}"
    if [[ -f "${d}restart.sh" ]]; then
      ( cd "$d" && bash restart.sh ) 2>&1
    else
      echo "[$(ts)] !! ${d} khong co restart.sh - bo qua"
    fi
    sleep 20
  done
  if (( found == 0 )); then
    echo "[$(ts)] Khong thay folder InternetIncome nao trong ${BASE_DIR}"
  fi
  echo "[$(ts)] ============================ xong ============================"
} >> "$LOG" 2>&1
EOS
  sed -i "s|__BASE_DIR__|${BASE_DIR}|g" /usr/local/bin/ii-restart-all.sh
  chmod +x /usr/local/bin/ii-restart-all.sh

  cat > /etc/logrotate.d/ii-logs <<'EOF'
/var/log/ii-*.log {
    weekly
    rotate 4
    size 10M
    missingok
    notifempty
    copytruncate
}
EOF

  cat > /etc/cron.d/internetincome <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 04:15 hang ngay: restart lan luot tat ca folder InternetIncome (chong giat, refresh ket noi)
15 4 * * * root /usr/local/bin/ii-restart-all.sh
# 05:30 chu nhat: don image docker dang (<none>)
30 5 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/internetincome

  if has_systemd; then
    systemctl enable --now cron >/dev/null 2>&1 || true
  else
    service cron start >/dev/null 2>&1 || true
  fi
  log "Cron: 04:15 hang ngay restart cac folder trong ${BASE_DIR} (log: /var/log/ii-restart.log)"
}

if (( DO_CRON == 1 )) && [[ -z "$BASE_DIR" ]] && [[ -t 0 ]]; then
  echo
  echo -e "${C_B}Muon cron tu restart tat ca folder luc 04:15 moi ngay?${C_0}"
  echo    "  Nhap THU MUC CHA chua cac folder InternetIncome (vd: /opt/ii , /root/ii)"
  read -r -p "  (de trong = bo qua cron): " BASE_DIR || true
fi

if [[ -n "$BASE_DIR" ]]; then
  install_cron_stack
elif [[ -f /etc/cron.d/internetincome ]]; then
  warn "Lan nay khong cai cron moi, nhung cron CU van dang chay:"
  warn "  xem       : cat /etc/cron.d/internetincome"
  warn "  doi folder: sua BASE_DIR trong /usr/local/bin/ii-restart-all.sh"
  warn "  go bo han : sudo rm /etc/cron.d/internetincome"
else
  warn "Bo qua cron restart (chay lai: sudo bash $0 --base-dir /opt/ii neu can)"
fi

#--------------------------------- TONG KET ----------------------------------
SW_DESC=$(swapon --show=SIZE --noheadings 2>/dev/null | paste -sd' ' -)
if [[ -z "$SW_DESC" ]]; then SW_DESC="khong co"; fi
if [[ -f /etc/cron.d/internetincome ]]; then
  CRON_DESC="DA CAI: restart 04:15 hang ngay + prune CN (xem /etc/cron.d/internetincome)"
else
  CRON_DESC="khong cai"
fi

echo
echo "============================= SETUP XONG =============================="
echo "  Docker : $(docker --version 2>/dev/null || echo 'loi')"
echo "  Swap   : ${SW_DESC}"
echo "  Cron   : ${CRON_DESC}"
echo
echo "  CAC BUOC TIEP THEO (ban tu kiem soat source, nhieu folder):"
echo "  1) Copy folder InternetIncome (nhanh test) len VPS, vao thu muc cha:"
echo "       rsync -a --exclude .git InternetIncome-test/ root@IP_VPS:/opt/ii/f1/"
echo "  2) cp properties-template.conf -> f1/properties.conf roi dien token"
echo "     !! DEVICE_NAME phai KHAC NHAU tung folder: vps01-f1, vps01-f2 ..."
echo "  3) cp proxies.txt vao f1/  (NEN la list da loc UDP)"
echo "  4) cd /opt/ii/f1 && sudo bash internetIncome.sh --start"
echo "  5) Kiem chung 24-48h (bat tam ENABLE_LOGS=true):"
echo "       docker ps --format '{{.Names}}' | head"
echo "       docker logs <container> 2>&1 | tail -20"
echo "     -> khong thay 'i/o timeout' lap lai la on; xong thi tat log lai"
echo "  6) Theo doi MB/ngay tren dashboard TraffMonetizer 7-14 ngay roi moi scale"
echo "======================================================================"

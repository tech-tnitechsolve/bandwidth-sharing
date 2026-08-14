cat << 'MASTER_EOF' > ~/setup_vps.sh
#!/usr/bin/env bash
#============================================================================
#  setup_vps.sh (DYNAMIC TIER MATRIX 2026 - ULTRA ANTI-BAN EDITION)
#============================================================================
set -Eeuo pipefail

ulimit -n 1048576 2>/dev/null || true
sysctl -w fs.inotify.max_user_watches=2097152 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_instances=65536 >/dev/null 2>&1 || true

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
log()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!!]${C_0} $*"; }
die()  { echo -e "${C_R}[XX]${C_0} $*"; exit 1; }

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

has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

if [[ -n "$BASE_DIR" ]]; then
  if [[ -d "$BASE_DIR" ]]; then
    log "Quet them thu muc: ${BASE_DIR}"
  else
    warn "--base-dir '${BASE_DIR}' KHONG ton tai -> bo qua."
    BASE_DIR=""
  fi
fi

VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
IS_CONTAINER=0
case "$VIRT" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1 ;; esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)

# --- PHÂN BỔ DYNAMIC TIER THEO ĐÚNG YÊU CẦU ---
TIER_NAME=""
if (( MEM_MB <= 2500 )); then
  TIER_NAME="TIER 1 (1-2 CPU / 2GB RAM - LIGHTWEIGHT PROXIES)"
  CONTAINER_MEM_LIMIT="35m"; CONTAINER_SWAP_LIMIT="90m"; TARGET_SWAP_MB=2048
elif (( MEM_MB <= 5000 )); then
  TIER_NAME="TIER 2 (2 CPU / 4GB RAM - BALANCED PROXIES)"
  CONTAINER_MEM_LIMIT="50m"; CONTAINER_SWAP_LIMIT="128m"; TARGET_SWAP_MB=3072
elif (( MEM_MB <= 9000 )); then
  TIER_NAME="TIER 3 (2 CPU / 8GB RAM - HIGH DENSITY PROXIES)"
  CONTAINER_MEM_LIMIT="70m"; CONTAINER_SWAP_LIMIT="160m"; TARGET_SWAP_MB=4096
else
  TIER_NAME="TIER 4 (2+ CPU / 12GB+ RAM - DEDICATED WIPTER / HEAVY APPS)"
  CONTAINER_MEM_LIMIT="100m"; CONTAINER_SWAP_LIMIT="256m"; TARGET_SWAP_MB=4096
fi

TIER_IDX=1
if   (( MEM_MB <= 2500 )); then TIER_IDX=1
elif (( MEM_MB <= 5000 )); then TIER_IDX=2
elif (( MEM_MB <= 9000 )); then TIER_IDX=3
else                            TIER_IDX=4
fi

clear_apt_locks() {
  log "Giai phong khoa APT Lock..."
  if has_systemd; then
    systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
    systemctl disable apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
  fi
  pkill -9 -f "apt|dpkg|unattended-upgrades" 2>/dev/null || true
  rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null || true
  dpkg --configure -a 2>/dev/null || true
}
clear_apt_locks

export DEBIAN_FRONTEND=noninteractive
log "apt update & install cac goi phu thuoc..."
apt-get update -y -qq || { clear_apt_locks; apt-get update -y -qq; }
apt-get install -y -qq --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools \
  iptables-persistent netfilter-persistent systemd-timesyncd vnstat nload speedtest-cli dnsutils || true

if ! command -v docker >/dev/null 2>&1; then
  log "VPS MOI: Dang tu dong cai dat Docker official..."
  curl -fsSL https://get.docker.com | sh || apt-get install -y -qq docker.io
  log "Cai dat Docker cho VPS moi thanh cong!"
else
  log "Docker da co san: $(docker --version 2>/dev/null || echo '?')"
fi

if has_systemd; then
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf <<'EOF_DOCKER_SVC'
[Service]
Restart=always
RestartSec=3s
EOF_DOCKER_SVC
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now docker >/dev/null 2>&1 || true
fi

log "Kich hoat KSM (Kernel Samepage Merging) gop RAM ngam..."
if [[ -f /sys/kernel/mm/ksm/run ]]; then
  echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
  echo 300 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
  echo 1250 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
  log "Da kich hoat KSM toi uu cao thanh cong!"
fi

ZRAM_SIZE_BYTES=$(( MEM_MB * 1024 * 1024 ))
log "Kich hoat ZRAM (${MEM_MB}MB)..."
modprobe zram num_devices=1 2>/dev/null || true
if [[ -b /dev/zram0 ]]; then
  swapon --show 2>/dev/null | grep -q "/dev/zram0" && swapoff /dev/zram0 2>/dev/null || true
  
  SELECTED_ALGO="lz4"
  if grep -q "zstd" /sys/block/zram0/comp_algorithm 2>/dev/null; then
    echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    SELECTED_ALGO="zstd"
  else
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  fi
  
  echo "$ZRAM_SIZE_BYTES" > /sys/block/zram0/disksize 2>/dev/null || true
  mkswap /dev/zram0 >/dev/null 2>&1
  swapon -p 10 /dev/zram0 2>/dev/null || true
  log "Da kich hoat ZRAM ${MEM_MB}MB (${SELECTED_ALGO^^} Priority 10) thanh cong!"
fi

SWAPPINESS=100
sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true

DISK_FREE_MB=$(df -m / | awk 'NR==2 {print $4}')
MAX_SAFE_SWAP=$(( DISK_FREE_MB - 2048 ))
if (( MAX_SAFE_SWAP < 512 )); then MAX_SAFE_SWAP=512; fi
if (( TARGET_SWAP_MB > MAX_SAFE_SWAP )); then
  TARGET_SWAP_MB=$MAX_SAFE_SWAP
fi

if (( CPU <= 2 )); then
  CONCURRENT_DOWNLOADS=3; SYN_BACKLOG=8192
elif (( CPU <= 4 )); then
  CONCURRENT_DOWNLOADS=5; SYN_BACKLOG=16384
else
  CONCURRENT_DOWNLOADS=8; SYN_BACKLOG=32768
fi

echo "=============================================================="
echo "  VPS $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU"
echo "  DETECTED PROFILE : ${TIER_NAME}"
echo "  Swap target=${TARGET_SWAP_MB}MB | Standard Limit=${CONTAINER_MEM_LIMIT}/${CONTAINER_SWAP_LIMIT}"
echo "  PROTECTION ENFORCED: Honeygain / Repocket / Packetstream / Wipter"
echo "=============================================================="

CURR_SWAP_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}' || echo 0)
SWAP_USED_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $3}' || echo 0)
RAM_AVAIL_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 0)

if (( IS_CONTAINER == 1 )); then
  warn "May ${VIRT} (container) thuong KHONG tao duoc swap -> bo qua"
elif (( CURR_SWAP_MB >= TARGET_SWAP_MB - 256 )) && (( CURR_SWAP_MB <= TARGET_SWAP_MB + 1536 )); then
  log "Da co swap đia ${CURR_SWAP_MB}MB -> giu nguyen"
else
  REBUILD_SWAP=1
  if (( CURR_SWAP_MB > TARGET_SWAP_MB + 1536 )); then
    if (( SWAP_USED_MB > RAM_AVAIL_MB - 200 )); then
      warn "Swap hien tai dang dung ${SWAP_USED_MB}MB -> Giu nguyen de an toan live!"
      REBUILD_SWAP=0
    else
      swapoff /swapfile /swapfile2 2>/dev/null || true
      sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null || true
      rm -f /swapfile /swapfile2 2>/dev/null || true
      CURR_SWAP_MB=0
    fi
  fi

  if (( REBUILD_SWAP == 1 )); then
    NEEDED_SWAP_MB=$(( TARGET_SWAP_MB - CURR_SWAP_MB ))
    SWAP_TARGET_FILE="/swapfile"
    if [[ -f /swapfile ]] && swapon --show=NAME 2>/dev/null | grep -q '/swapfile'; then
      SWAP_TARGET_FILE="/swapfile2"
    fi

    log "Tao swap ${NEEDED_SWAP_MB}MB (${SWAP_TARGET_FILE})..."
    if ! fallocate -l "${NEEDED_SWAP_MB}M" "$SWAP_TARGET_FILE" 2>/dev/null; then
      dd if=/dev/zero of="$SWAP_TARGET_FILE" bs=1M count="$NEEDED_SWAP_MB" status=none
    fi
    chmod 600 "$SWAP_TARGET_FILE"
    if mkswap "$SWAP_TARGET_FILE" >/dev/null 2>&1 && swapon -p 0 "$SWAP_TARGET_FILE" 2>/dev/null; then
      grep -q "^${SWAP_TARGET_FILE}" /etc/fstab || echo "${SWAP_TARGET_FILE} none swap sw,pri=0 0 0" >> /etc/fstab
      log "Tao swap đia ${SWAP_TARGET_FILE} ${NEEDED_SWAP_MB}MB thanh cong"
    else
      rm -f "$SWAP_TARGET_FILE"
    fi
  fi
fi

log "Dang diet cac dich vu OS ngom RAM ngam (snapd, multipathd, udisks2, earlyoom)..."
if has_systemd; then
  systemctl stop snapd multipathd udisks2 accountsservice earlyoom 2>/dev/null || true
  systemctl disable snapd multipathd udisks2 accountsservice earlyoom 2>/dev/null || true
fi
apt-get purge -y snapd earlyoom 2>/dev/null || true
rm -rf /var/cache/snapd/ /var/lib/snapd/ 2>/dev/null || true

if command -v docker >/dev/null 2>&1; then
  log "Dang don dep cac container Watchtower trung lap ngom RAM..."
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep "internetincomewatchtower" | xargs -r docker rm -f >/dev/null 2>&1 || true
fi

MAIN_IF=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n1 || echo "")
if [[ -f /etc/vnstat.conf ]]; then
  if [[ -n "$MAIN_IF" ]]; then
    sed -i "s/Interface \".*\"/Interface \"$MAIN_IF\"/" /etc/vnstat.conf
  fi
  grep -q 'ExcludeInterface' /etc/vnstat.conf || echo 'ExcludeInterface "veth* docker0 tun* tap*"' >> /etc/vnstat.conf
  if has_systemd; then systemctl restart vnstat 2>/dev/null || true; fi
fi

if has_systemd; then
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
fi
timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF_APT'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF_APT

if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
fi

rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 222.252.2.2\nnameserver 203.162.4.190\nnameserver 9.9.9.9\n' > /etc/resolv.conf

modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

modprobe tun 2>/dev/null || true
if [[ ! -c /dev/net/tun ]]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 600 /dev/net/tun 2>/dev/null || true
fi
if [[ -c /dev/net/tun ]]; then
  echo tun > /etc/modules-load.d/tun.conf 2>/dev/null || true
  MYST_TUN_OK=1
  log "TUN device san sang (/dev/net/tun) -> Mysterium co the tao WireGuard"
else
  MYST_TUN_OK=0
  warn "KHONG co /dev/net/tun (ao hoa: ${VIRT})."
  warn "  -> Mysterium SE LOI: CreateTUN(\"myst0\") failed"
fi

iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save 2>/dev/null || true
fi

echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true

SYSCTL_FILE=/etc/sysctl.d/99-internetincome.conf
cat > "$SYSCTL_FILE" <<EOF_SYSCTL
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
# [CRITICAL CHROMIUM/WIPTER FIX] Cấp đủ bộ nhớ ảo tránh Crash Wipter
vm.max_map_count = 262144
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152
vm.min_free_kbytes = 65536
vm.page-cluster = 0
vm.overcommit_memory = 1
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 300
vm.dirty_background_ratio = 3
vm.dirty_ratio = 8
fs.file-max = 2097152
fs.inotify.max_user_instances = 65536
fs.inotify.max_user_watches = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
EOF_SYSCTL

sed -i '/disable_ipv6/d' "$SYSCTL_FILE" 2>/dev/null || true

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue
  sysctl -w "$line" >/dev/null 2>&1 || true
done < "$SYSCTL_FILE"
log "Kernel Tuning Safe Mode (vm.max_map_count=262144) xong"

if [[ -f /etc/sysctl.d/99-vps-optimize.conf ]]; then
  rm -f /etc/sysctl.d/99-vps-optimize.conf
fi

mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/99-nofile.conf <<'EOF_LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF_LIMITS

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-ii-limit.conf <<'EOF_JOURNAL'
[Journal]
SystemMaxUse=10M
RuntimeMaxUse=5M
EOF_JOURNAL
if has_systemd; then systemctl restart systemd-journald 2>/dev/null || true; fi

#============================================================================
# CAI THU VIEN HO SO APP - ULTRA ANTI-BAN ENFORCEMENT
#============================================================================
mkdir -p /usr/local/lib
cat > /usr/local/lib/ii-app-profiles.sh <<'EOF_PROFILES'
#!/usr/bin/env bash
#============================================================================
# /usr/local/lib/ii-app-profiles.sh (ULTRA ANTI-BAN EDITION)
#============================================================================

ii_tier_idx() {
  local m="${1:-0}"
  if   (( m <= 2500 )); then echo 1
  elif (( m <= 5000 )); then echo 2
  elif (( m <= 9000 )); then echo 3
  else                       echo 4
  fi
}

_p() { local t="$1"; shift; local a=("$@"); echo "${a[$((t-1))]}"; }

ii_profile() {
  local n img t
  n="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's|^/||')"
  img="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  t="${3:-3}"
  case "$t" in 1|2|3|4) ;; *) t=3 ;; esac

  P_APP=""; P_MEM=""; P_SWAP=""; P_POLICY="unless-stopped"
  P_VPS="safe"; P_MAXIP=0; P_NOTE=""

  case "$n" in
    tun*)
      P_APP="tun2socks";  P_MEM=$(_p $t 32m 48m 64m 96m);   P_SWAP=$(_p $t 64m 96m 128m 192m)
      P_POLICY="__KEEP__"; P_NOTE="Ha tang mang proxy" ;;
    dindurnetwork*|dindproxylite*|adnadedind*|dind*)
      P_APP="docker-in-docker"; P_MEM=$(_p $t 128m 160m 200m 256m); P_SWAP=$(_p $t 256m 320m 400m 512m)
      P_POLICY="__KEEP__"; P_NOTE="Docker-in-Docker ha tang" ;;

    # ================= NHOM CHAY TOT TREN VPS =================
    myst*)
      P_APP="Mysterium"; P_MEM=$(_p $t 250m 250m 300m 350m); P_SWAP=$(_p $t 500m 500m 600m 700m)
      P_VPS="safe"; P_NOTE="Can /dev/net/tun" ;;
    traffmon*)
      P_APP="Traffmonetizer"; P_MEM=$(_p $t 70m 90m 110m 140m); P_SWAP=$(_p $t 140m 180m 220m 280m)
      P_VPS="safe"; P_NOTE="Lightweight binary" ;;
    bitping*)
      P_APP="Bitping"; P_MEM=$(_p $t 90m 110m 140m 180m); P_SWAP=$(_p $t 180m 220m 280m 360m)
      P_VPS="safe"; P_NOTE="Network tests node" ;;
    proxyrack*)
      P_APP="Proxyrack"; P_MEM=$(_p $t 70m 90m 110m 140m); P_SWAP=$(_p $t 140m 180m 220m 280m)
      P_VPS="safe" ;;
    proxybase*)
      P_APP="Proxybase"; P_MEM=$(_p $t 70m 90m 110m 140m); P_SWAP=$(_p $t 140m 180m 220m 280m)
      P_VPS="safe" ;;
    proxylite*)
      P_APP="Proxylite"; P_MEM=$(_p $t 70m 90m 110m 140m); P_SWAP=$(_p $t 140m 180m 220m 280m)
      P_VPS="safe" ;;
    peer2profit*)
      P_APP="Peer2Profit"; P_MEM=$(_p $t 90m 110m 140m 180m); P_SWAP=$(_p $t 180m 220m 280m 360m)
      P_VPS="safe" ;;
    urnetwork*)
      P_APP="URnetwork"; P_MEM=$(_p $t 110m 140m 180m 220m); P_SWAP=$(_p $t 220m 280m 360m 440m)
      P_VPS="safe" ;;
    titan*)
      P_APP="Titan Network"; P_MEM=$(_p $t 200m 256m 320m 400m); P_SWAP=$(_p $t 400m 512m 640m 800m)
      P_VPS="safe" ;;
    antgain*)
      P_APP="AntGain"; P_MEM=$(_p $t 70m 90m 110m 140m); P_SWAP=$(_p $t 140m 180m 220m 280m)
      P_VPS="safe" ;;
    wizardgain*)
      P_APP="WizardGain"; P_MEM=$(_p $t 70m 90m 110m 140m); P_SWAP=$(_p $t 140m 180m 220m 280m)
      P_VPS="safe" ;;

    # ============ NHOM SIẾT CHẶT CHỐNG KHÓA ACC (ULTRA ANTI-BAN) =============
    honey*)
      # HONEYGAIN: Đặt policy on-failure:3 (Lỗi 3 lần dừng luôn). RAM nâng 200MB.
      P_APP="Honeygain"; P_MEM=$(_p $t 200m 220m 256m 320m); P_SWAP=$(_p $t 400m 440m 512m 640m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1
      P_NOTE="ULTRA ANTI-BAN: Restart 3 lần dừng hẳn. Khóa 1 device/IP" ;;
    repocket*)
      # REPOCKET: Đặt policy on-failure:3. RAM nâng 200MB tránh Node.js OOM.
      P_APP="Repocket"; P_MEM=$(_p $t 200m 220m 256m 300m); P_SWAP=$(_p $t 400m 440m 512m 600m)
      P_POLICY="on-failure:3"; P_VPS="safe"; P_MAXIP=1
      P_NOTE="ULTRA ANTI-BAN: Node.js 200MB headroom. Max 1 device/IP" ;;
    packetstream*)
      # PACKETSTREAM: Policy on-failure:3. Dừng ngay khi proxy có dấu hiệu đứt.
      P_APP="PacketStream"; P_MEM=$(_p $t 100m 120m 140m 180m); P_SWAP=$(_p $t 200m 240m 280m 360m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1
      P_NOTE="ULTRA ANTI-BAN: Ngắt kết nối ngay khi Proxy đứt" ;;
    pawns*)
      P_APP="IPRoyal Pawns"; P_MEM=$(_p $t 100m 120m 140m 180m); P_SWAP=$(_p $t 200m 240m 280m 360m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1
      P_NOTE="Strict Residential" ;;
    packetshare*)
      P_APP="Packetshare"; P_MEM=$(_p $t 100m 120m 140m 180m); P_SWAP=$(_p $t 200m 240m 280m 360m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1 ;;
    earnfm*)
      P_APP="EarnFM"; P_MEM=$(_p $t 140m 160m 180m 220m); P_SWAP=$(_p $t 280m 320m 360m 440m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1 ;;
    wipter*)
      # WIPTER: Nâng RAM 450MB, Policy on-failure:5 để bảo vệ Chromium.
      P_APP="Wipter"; P_MEM=$(_p $t 450m 450m 500m 600m); P_SWAP=$(_p $t 800m 800m 900m 1000m)
      P_POLICY="on-failure:5"; P_VPS="resi"
      P_NOTE="Chromium Heap Headroom 450MB" ;;
    depinext*)
      P_APP="Depin/Grass ext"; P_MEM=$(_p $t 400m 450m 500m 600m); P_SWAP=$(_p $t 700m 800m 900m 1000m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;
    ebesucher*)
      P_APP="Ebesucher"; P_MEM=$(_p $t 400m 450m 512m 640m); P_SWAP=$(_p $t 700m 800m 900m 1000m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;
    adnade*)
      P_APP="Adnade"; P_MEM=$(_p $t 400m 450m 512m 640m); P_SWAP=$(_p $t 700m 800m 900m 1000m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;

    earnapp*)
      P_APP="EarnApp"; P_MEM=$(_p $t 100m 120m 140m 180m); P_SWAP=$(_p $t 200m 240m 280m 360m)
      P_POLICY="on-failure:3"; P_VPS="ban"; P_MAXIP=1
      P_NOTE="BANNED ON VPS/VM" ;;

    *)
      P_APP=""; P_POLICY="__KEEP__"; P_NOTE="Khong co ho so - giu nguyen cau hinh goc" ;;
  esac

  if [[ -z "$P_APP" && -n "$img" ]]; then
    case "$img" in
      *mysteriumnetwork/myst*) ii_profile "myst" "" "$t"; return ;;
      *repocket*)              ii_profile "repocket" "" "$t"; return ;;
      *honeygain*)             ii_profile "honey" "" "$t"; return ;;
      *traffmonetizer*)        ii_profile "traffmon" "" "$t"; return ;;
      *bitping*)               ii_profile "bitping" "" "$t"; return ;;
      *earnfm*)                ii_profile "earnfm" "" "$t"; return ;;
      *earnapp*)               ii_profile "earnapp" "" "$t"; return ;;
      *proxyrack*)             ii_profile "proxyrack" "" "$t"; return ;;
      *proxybase*)             ii_profile "proxybase" "" "$t"; return ;;
      *proxylite*)             ii_profile "proxylite" "" "$t"; return ;;
      *pawns*)                 ii_profile "pawns" "" "$t"; return ;;
      *packetstream*)          ii_profile "packetstream" "" "$t"; return ;;
      *packetshare*)           ii_profile "packetshare" "" "$t"; return ;;
      *peer2profit*)           ii_profile "peer2profit" "" "$t"; return ;;
      *community-provider*)    ii_profile "urnetwork" "" "$t"; return ;;
      *titan-edge*)            ii_profile "titan" "" "$t"; return ;;
      *antgain*)               ii_profile "antgain" "" "$t"; return ;;
      *wizardgain*)            ii_profile "wizardgain" "" "$t"; return ;;
    esac
  fi
}

II_APPS="myst repocket traffmon bitping proxyrack proxybase proxylite peer2profit urnetwork titan antgain wizardgain honey pawns packetstream packetshare earnfm wipter depinext ebesucher adnade earnapp"

# DANH SÁCH APP ĐƯỢC BẢO VỆ CHỐNG SUSPEND TUYỆT ĐỐI
II_SUSPEND_SENSITIVE="honey pawns packetstream packetshare earnfm wipter depinext ebesucher adnade earnapp repocket"

ii_is_suspend_sensitive() {
  local n="${1:-}"
  for a in $II_SUSPEND_SENSITIVE; do
    case "$n" in ${a}*) return 0 ;; esac
  done
  return 1
}
EOF_PROFILES
chmod 644 /usr/local/lib/ii-app-profiles.sh
. /usr/local/lib/ii-app-profiles.sh
log "Da cai bang ho so toi uu cho $(echo $II_APPS | wc -w) nen tang (Ultra Anti-Ban Enabled)"

#============================================================================
# FLAPGUARD ULTRA - ÉP DỪNG 12 TIẾNG NẾU CONTAINER CÓ DẤU HIỆU SẬP LIÊN TỤC
#============================================================================
cat > /usr/local/bin/ii-flapguard.sh <<'EOF_FLAPGUARD'
#!/usr/bin/env bash
set -uo pipefail

PROFILES=/usr/local/lib/ii-app-profiles.sh
[[ -r "$PROFILES" ]] && . "$PROFILES"

LOG=/var/log/ii-flapguard.log
STATE=/var/lib/ii-flapguard
mkdir -p "$STATE" 2>/dev/null || true

# NGƯỠNG SIẾT CHẶT TUYỆT ĐỐI: Chỉ cho phép tối đa 2 lần restart trong 1 giờ.
# Nếu bị lặp lại quá 2 lần -> Ép ngắt hẳn 12 Tiếng (43200s) để giữ an toàn cho Account!
FLAP_MAX="${FLAP_MAX:-2}"
FLAP_WINDOW="${FLAP_WINDOW:-3600}"
COOLDOWN="${COOLDOWN:-43200}"

ts() { date '+%F %T'; }
say() { echo "[$(ts)] $*" >> "$LOG"; }

command -v docker >/dev/null 2>&1 || exit 0

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
TIER=$(ii_tier_idx "$MEM_MB" 2>/dev/null || echo 3)

for cid in $(docker ps -aq 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||') || continue
  [[ -n "$cname" ]] || continue
  cimg=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || echo "")

  ii_profile "$cname" "$cimg" "$TIER" 2>/dev/null || continue
  ii_is_suspend_sensitive "$cname" || continue

  rc=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0)
  running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo false)
  oom=$(docker inspect -f '{{.State.OOMKilled}}' "$cid" 2>/dev/null || echo false)
  now=$(date +%s)

  f="$STATE/${cname}.state"
  prev_rc=0; prev_t=0; stopped_at=0
  [[ -f "$f" ]] && read -r prev_rc prev_t stopped_at < "$f" 2>/dev/null
  prev_rc=${prev_rc:-0}; prev_t=${prev_t:-0}; stopped_at=${stopped_at:-0}

  if (( stopped_at > 0 )); then
    if (( now - stopped_at >= COOLDOWN )); then
      say "[$cname] Het cooldown ($(( (now-stopped_at)/3600 )) gio). Mo lai an toan."
      docker start "$cid" >/dev/null 2>&1 \
        && say "[$cname] Da khoi dong lai sau cooldown." \
        || say "[$cname] Khong start duoc sau cooldown."
      echo "$rc $now 0" > "$f"
    fi
    continue
  fi

  if (( prev_t == 0 )); then
    echo "$rc $now 0" > "$f"
    continue
  fi

  delta=$(( rc - prev_rc ))
  elapsed=$(( now - prev_t ))

  if (( delta < 0 )); then
    echo "$rc $now 0" > "$f"
    continue
  fi

  if (( elapsed >= FLAP_WINDOW )); then
    if (( delta > FLAP_MAX )); then
      say "[$cname] FLAP DETECTED: ${delta} lan restart trong $(( elapsed/60 )) phut (Nguong an toan: ${FLAP_MAX})."
      say "[$cname] -> DUNG HAN 12 TIENG DE BAO VE ACCOUNT KHOI BI BAN VINH VIEN."
      [[ "$oom" == "true" ]] && say "[$cname] Nguyen nhan: OOMKilled."
      docker update --restart=no "$cid" >/dev/null 2>&1 || true
      docker stop "$cid" >/dev/null 2>&1 || true
      echo "$rc $now $now" > "$f"
    else
      echo "$rc $now 0" > "$f"
    fi
    continue
  fi

  if (( delta > FLAP_MAX )); then
    say "[$cname] FLAP GAP: ${delta} lan restart chi trong $(( elapsed/60 )) phut."
    say "[$cname] -> DUNG HAN 12 TIENG NGAY LAP TUC."
    [[ "$oom" == "true" ]] && say "[$cname] Nguyen nhan: OOMKilled."
    docker update --restart=no "$cid" >/dev/null 2>&1 || true
    docker stop "$cid" >/dev/null 2>&1 || true
    echo "$rc $now $now" > "$f"
  fi
done

find "$STATE" -name '*.state' -mtime +14 -delete 2>/dev/null || true
EOF_FLAPGUARD
chmod +x /usr/local/bin/ii-flapguard.sh
ln -sf /usr/local/bin/ii-flapguard.sh /usr/bin/ii-flapguard 2>/dev/null || true
log "Da cai ii-flapguard Ultra Anti-Ban (Tối đa 2 restarts/h, Cooldown 12h)"

auto_patch_engageub_repo() {
  log "Dang quet va PATCH RAM DOCKER + FIX TAN GOC CO IPV6..."
  ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc)
  if [[ -n "$BASE_DIR" ]]; then ROOTS+=("$BASE_DIR"); fi

  while IFS= read -r sh_file; do
    d=$(dirname "$sh_file")
    if [[ -f "${d}/properties.conf" ]]; then
      sed -i "s/MAX_MEMORY=.*/MAX_MEMORY=${CONTAINER_MEM_LIMIT}/" "${d}/properties.conf" 2>/dev/null || true
      grep -q "MAX_MEMORY=" "${d}/properties.conf" || echo "MAX_MEMORY=${CONTAINER_MEM_LIMIT}" >> "${d}/properties.conf"
    fi

    if [[ -f "$sh_file" ]]; then
      cp -n "$sh_file" "${sh_file}.bak" 2>/dev/null || true
      
      sed -i -E 's/--sysctl[ =]+net\.ipv6\.conf\.[a-zA-Z0-9_]+\.disable_ipv6=[0-9]//g' "$sh_file" 2>/dev/null || true
      sed -i 's/--sysctl net.ipv6.conf.[a-z0-9_]*.disable_ipv6=[0-9]//g' "$sh_file" 2>/dev/null || true

      if ! grep -q "\--restart" "$sh_file"; then
        sed -i "s/docker run -d/docker run -d --restart=unless-stopped/g" "$sh_file" 2>/dev/null || true
      fi

      if ! grep -q "\--memory" "$sh_file"; then
        sed -i "s/docker run -d/docker run -d --memory=\"${CONTAINER_MEM_LIMIT}\" --memory-swap=\"${CONTAINER_SWAP_LIMIT}\"/g" "$sh_file"
      fi

      sed -i "s/--memory=\"[0-9]*[a-z]*\"/--memory=\"${CONTAINER_MEM_LIMIT}\"/g" "$sh_file" 2>/dev/null || true
      sed -i "s/--memory-swap=\"[0-9]*[a-z]*\"/--memory-swap=\"${CONTAINER_SWAP_LIMIT}\"/g" "$sh_file" 2>/dev/null || true

      sed -i -E '/mysterium|myst/I s/--memory="[0-9]+[a-zA-Z]+"/--memory="250m"/g' "$sh_file" 2>/dev/null || true
      sed -i -E '/mysterium|myst/I s/--memory-swap="[0-9]+[a-zA-Z]+"/--memory-swap="500m"/g' "$sh_file" 2>/dev/null || true

      sed -i -E '/wipter/I s/--memory="[0-9]+[a-zA-Z]+"/--memory="450m"/g' "$sh_file" 2>/dev/null || true
      sed -i -E '/wipter/I s/--memory-swap="[0-9]+[a-zA-Z]+"/--memory-swap="800m"/g' "$sh_file" 2>/dev/null || true

      for _app in $II_APPS; do
        ii_profile "$_app" "" "$TIER_IDX"
        [[ -n "$P_MEM" ]] || continue
        sed -i -E "/docker run/{/--name ${_app}/{
          s/--memory=\"[0-9]+[a-zA-Z]+\"/--memory=\"${P_MEM}\"/g;
          s/--memory-swap=\"[0-9]+[a-zA-Z]+\"/--memory-swap=\"${P_SWAP}\"/g
        }}" "$sh_file" 2>/dev/null || true

        if [[ "$P_POLICY" != "__KEEP__" ]]; then
          sed -i -E "/docker run/{/--name ${_app}/{
            s/--restart=[a-z-]+(:[0-9]+)?/--restart=${P_POLICY}/g;
            s/--restart [a-z-]+(:[0-9]+)?/--restart=${P_POLICY}/g
          }}" "$sh_file" 2>/dev/null || true
        fi
      done

      if (( MYST_TUN_OK == 1 )); then
        sed -i '/docker run/{\|mysteriumnetwork/myst:latest|{\|/dev/net/tun|!s|mysteriumnetwork/myst:latest|--device /dev/net/tun:/dev/net/tun mysteriumnetwork/myst:latest|}}' "$sh_file" 2>/dev/null || true
      fi
    fi
  done < <(find "${ROOTS[@]}" -maxdepth 4 -name internetIncome.sh -type f 2>/dev/null | sort -u)
}
auto_patch_engageub_repo

if command -v docker >/dev/null 2>&1; then
  CTRS=$(docker ps -q 2>/dev/null || true)
  if [[ -n "$CTRS" ]]; then
    log "Cap nhat LIVE Memory Limit cho toan bo Container dang chay..."
    docker update --memory="${CONTAINER_MEM_LIMIT}" --memory-swap="${CONTAINER_SWAP_LIMIT}" $CTRS >/dev/null 2>&1 || true
    docker update --restart=unless-stopped $CTRS >/dev/null 2>&1 || true
    
    _n_prof=0
    for cid in $CTRS; do
      c_img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
      c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || true)
      ii_profile "$c_name" "$c_img" "$TIER_IDX"
      [[ -n "$P_MEM" ]] || continue
      if [[ "$P_POLICY" == "__KEEP__" ]]; then
        docker update --memory="$P_MEM" --memory-swap="$P_SWAP" "$cid" >/dev/null 2>&1 || true
      else
        docker update --memory="$P_MEM" --memory-swap="$P_SWAP" \
                      --restart="$P_POLICY" "$cid" >/dev/null 2>&1 || true
      fi
      _n_prof=$((_n_prof+1))
      if [[ "$P_VPS" == "ban" ]]; then
        warn "  ${P_APP} (${c_name}): ${P_NOTE}"
      fi
    done
    log "Da ap dung ho so toi uu rieng cho ${_n_prof} container"
  fi
fi

mkdir -p /etc/docker
NEW_DAEMON="$(cat <<EOF_DAEMON
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "2m", "max-file": "2" },
  "dns": ["8.8.8.8", "1.1.1.1", "9.9.9.9"],
  "registry-mirrors": ["https://mirror.gcr.io", "https://docker.m.daocloud.io"],
  "max-concurrent-downloads": ${CONCURRENT_DOWNLOADS},
  "live-restore": true,
  "userland-proxy": false,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 }
  }
}
EOF_DAEMON
)"

DOCKER_RESTARTED=0
if [[ -f /etc/docker/daemon.json ]] && printf '%s\n' "$NEW_DAEMON" | cmp -s - /etc/docker/daemon.json; then
  log "daemon.json khong thay doi -> KHONG KHIEN DOCKER RESTART"
else
  if [[ -f /etc/docker/daemon.json ]]; then
    cp -f /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
  fi
  printf '%s\n' "$NEW_DAEMON" > /etc/docker/daemon.json
  if has_systemd; then
    systemctl restart docker
  else
    service docker start >/dev/null 2>&1 || service docker restart || true
  fi
  DOCKER_RESTARTED=1
fi

if has_systemd; then systemctl enable --now docker >/dev/null 2>&1 || true; fi

while ! docker info >/dev/null 2>&1; do
  sleep 1
done

# --- [RANDOMIZED STAGGERED START - MÔ PHỎNG ĐĂNG NHẬP THỰC TẾ TRÁNH BẪY API] ---
if (( DOCKER_RESTARTED == 1 )); then
  log "Dang bat lai cac container voi RANDOMIZED STAGGERED START (Mô phỏng thao tác người)..."
  
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
    docker start "$cid" >/dev/null 2>&1 || true
    
    # Tạo độ trễ ngẫu nhiên từ 3-7 giây giữa các container nhạy cảm
    RAND_WAIT=$(( 3 + RANDOM % 5 ))
    
    if [[ "$c_name" =~ wipter|ebesucher|adnade|depinext ]]; then
      sleep 10  # Chromium cần 10s để ổn định hoàn toàn
    elif [[ "$c_name" =~ honey|repocket|packetstream|packetshare|pawns|earnfm|earnapp ]]; then
      sleep "$RAND_WAIT"
    else
      sleep 1.5
    fi
  done < <(find /opt /root /home /srv /home/ubuntu /home/opc -maxdepth 4 -name containernames.txt -type f -exec cat {} + 2>/dev/null | sort -u)

  if command -v ctr >/dev/null 2>&1; then
    for cid in $(docker ps -aq --no-trunc -f status=exited 2>/dev/null); do
      ctr -n moby task kill -s SIGKILL "$cid" >/dev/null 2>&1 || true
      ctr -n moby task rm "$cid" >/dev/null 2>&1 || true
    done
  fi

  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
    docker start "$cid" >/dev/null 2>&1 || true
    
    RAND_WAIT=$(( 3 + RANDOM % 5 ))
    if [[ "$c_name" =~ wipter|ebesucher|adnade|depinext ]]; then
      sleep 10
    elif [[ "$c_name" =~ honey|repocket|packetstream|packetshare|pawns|earnfm|earnapp ]]; then
      sleep "$RAND_WAIT"
    else
      sleep 1.5
    fi
  done < <(docker ps -aq -f status=exited 2>/dev/null)

  log "Da revive xong tat ca container mot cach an toan tuyet doi!"
fi

install_cron_stack() {
  cat > /usr/local/bin/ii-restart-all.sh <<'EOF_RESTART'
#!/usr/bin/env bash
LOG=/var/log/ii-restart.log
ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc __EXTRA__)
ts() { date '+%F %T'; }
HAVE_CTR=0; command -v ctr >/dev/null 2>&1 && HAVE_CTR=1

{
  echo "[$(ts)] ==================== ii-restart-all ===================="
  MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if (( MEM_MB <= 2500 )); then
    MEM_LIMIT="35m"; SWAP_LIMIT="90m"
  elif (( MEM_MB <= 5000 )); then
    MEM_LIMIT="50m"; SWAP_LIMIT="128m"
  elif (( MEM_MB <= 9000 )); then
    MEM_LIMIT="70m"; SWAP_LIMIT="160m"
  else
    MEM_LIMIT="100m"; SWAP_LIMIT="256m"
  fi

  PROFILES=/usr/local/lib/ii-app-profiles.sh
  if [[ -r "$PROFILES" ]]; then . "$PROFILES"; fi
  TIER_IDX=$(ii_tier_idx "$MEM_MB" 2>/dev/null || echo 3)

  modprobe tun 2>/dev/null || true
  if [[ ! -c /dev/net/tun ]]; then
    mkdir -p /dev/net 2>/dev/null || true
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 600 /dev/net/tun 2>/dev/null || true
  fi
  MYST_TUN_OK=0; [[ -c /dev/net/tun ]] && MYST_TUN_OK=1

  while IFS= read -r sh_f; do
    d_path=$(dirname "$sh_f")
    [[ -f "${d_path}/properties.conf" ]] && sed -i "s/MAX_MEMORY=.*/MAX_MEMORY=${MEM_LIMIT}/" "${d_path}/properties.conf" 2>/dev/null || true
    if [[ -f "$sh_f" ]]; then
      sed -i -E 's/--sysctl[ =]+net\.ipv6\.conf\.[a-zA-Z0-9_]+\.disable_ipv6=[0-9]//g' "$sh_f" 2>/dev/null || true
      sed -i 's/--sysctl net.ipv6.conf.[a-z0-9_]*.disable_ipv6=[0-9]//g' "$sh_f" 2>/dev/null || true
      grep -q "\--restart" "$sh_f" || sed -i "s/docker run -d/docker run -d --restart=unless-stopped/g" "$sh_f" 2>/dev/null || true
      grep -q "\--memory" "$sh_f" || sed -i "s/docker run -d/docker run -d --memory=\"${MEM_LIMIT}\" --memory-swap=\"${SWAP_LIMIT}\"/g" "$sh_f" 2>/dev/null || true

      sed -i "s/--memory=\"[0-9]*[a-z]*\"/--memory=\"${MEM_LIMIT}\"/g" "$sh_f" 2>/dev/null || true
      sed -i "s/--memory-swap=\"[0-9]*[a-z]*\"/--memory-swap=\"${SWAP_LIMIT}\"/g" "$sh_f" 2>/dev/null || true

      sed -i -E '/mysterium|myst/I s/--memory="[0-9]+[a-zA-Z]+"/--memory="250m"/g' "$sh_f" 2>/dev/null || true
      sed -i -E '/mysterium|myst/I s/--memory-swap="[0-9]+[a-zA-Z]+"/--memory-swap="500m"/g' "$sh_f" 2>/dev/null || true

      sed -i -E '/wipter/I s/--memory="[0-9]+[a-zA-Z]+"/--memory="450m"/g' "$sh_f" 2>/dev/null || true
      sed -i -E '/wipter/I s/--memory-swap="[0-9]+[a-zA-Z]+"/--memory-swap="800m"/g' "$sh_f" 2>/dev/null || true

      for _app in ${II_APPS:-}; do
        ii_profile "$_app" "" "$TIER_IDX"
        [[ -n "$P_MEM" ]] || continue
        sed -i -E "/docker run/{/--name ${_app}/{
          s/--memory=\"[0-9]+[a-zA-Z]+\"/--memory=\"${P_MEM}\"/g;
          s/--memory-swap=\"[0-9]+[a-zA-Z]+\"/--memory-swap=\"${P_SWAP}\"/g
        }}" "$sh_f" 2>/dev/null || true
        if [[ "$P_POLICY" != "__KEEP__" ]]; then
          sed -i -E "/docker run/{/--name ${_app}/{
            s/--restart=[a-z-]+(:[0-9]+)?/--restart=${P_POLICY}/g;
            s/--restart [a-z-]+(:[0-9]+)?/--restart=${P_POLICY}/g
          }}" "$sh_f" 2>/dev/null || true
        fi
      done

      if (( MYST_TUN_OK == 1 )); then
        sed -i '/docker run/{\|mysteriumnetwork/myst:latest|{\|/dev/net/tun|!s|mysteriumnetwork/myst:latest|--device /dev/net/tun:/dev/net/tun mysteriumnetwork/myst:latest|}}' "$sh_f" 2>/dev/null || true
      fi
    fi
  done < <(find "${ROOTS[@]}" -maxdepth 4 -name internetIncome.sh -type f 2>/dev/null | sort -u)

  mapfile -t FILES < <(find "${ROOTS[@]}" -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)
  if (( ${#FILES[@]} == 0 )); then
    echo "[$(ts)] chua thay folder engageub nao"
  else
    STUCK=$(docker ps -aq --no-trunc -f status=exited 2>/dev/null || true)
    if (( HAVE_CTR == 1 )) && [[ -n "$STUCK" ]]; then
      for cid in $STUCK; do
        ctr -n moby task kill -s SIGKILL "$cid" >/dev/null 2>&1
        ctr -n moby task rm "$cid" >/dev/null 2>&1
      done
    fi
    TOTAL=0
    for cn in "${FILES[@]}"; do
      d=$(dirname "$cn")
      [[ -f "${d}/internetIncome.sh" ]] || continue
      n=$(grep -c . "$cn" 2>/dev/null || echo 0)
      TOTAL=$((TOTAL+n))
      echo "[$(ts)] >>> ${d} (${n} container - restart rải rác mô phỏng người dùng)..."
      
      while IFS= read -r cid; do
        [[ -n "$cid" ]] || continue
        c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
        docker restart "$cid" >/dev/null 2>&1 || echo "[$(ts)] !! loi restart $cid"
        
        RAND_WAIT=$(( 3 + RANDOM % 5 ))
        if [[ "$c_name" =~ wipter|ebesucher|adnade|depinext ]]; then
          sleep 10
        elif [[ "$c_name" =~ honey|repocket|packetstream|packetshare|pawns|earnfm|earnapp ]]; then
          sleep "$RAND_WAIT"
        else
          sleep 1.5
        fi
      done < "$cn"

      sleep 5
    done

    while IFS= read -r cid; do
      [[ -n "$cid" ]] || continue
      c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
      docker start "$cid" >/dev/null 2>&1 || true
      
      RAND_WAIT=$(( 3 + RANDOM % 5 ))
      if [[ "$c_name" =~ wipter|ebesucher|adnade|depinext ]]; then
        sleep 10
      elif [[ "$c_name" =~ honey|repocket|packetstream|packetshare|pawns|earnfm|earnapp ]]; then
        sleep "$RAND_WAIT"
      else
        sleep 1.5
      fi
    done < <(cat "${FILES[@]}" 2>/dev/null | sort -u)

    docker update --restart=unless-stopped $(docker ps -aq 2>/dev/null || true) >/dev/null 2>&1 || true
    for cid in $(docker ps -aq 2>/dev/null); do
      c_img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
      c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || true)
      cn=$(printf '%s' "$c_name" | sed 's|^/||')
      ii_profile "$cn" "$c_img" "$TIER_IDX"
      [[ -n "$P_MEM" ]] || continue
      if [[ "$P_POLICY" == "__KEEP__" ]]; then
        docker update --memory="$P_MEM" --memory-swap="$P_SWAP" "$cid" >/dev/null 2>&1 || true
      else
        docker update --memory="$P_MEM" --memory-swap="$P_SWAP" \
                      --restart="$P_POLICY" "$cid" >/dev/null 2>&1 || true
      fi
    done

    STILL=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
    echo "[$(ts)] xong: ${TOTAL} container | con Exited: ${STILL}"
  fi
} >> "$LOG" 2>&1
EOF_RESTART
  if [[ -n "$BASE_DIR" ]]; then
    sed -i "s|__EXTRA__|\"${BASE_DIR}\"|" /usr/local/bin/ii-restart-all.sh
  else
    sed -i "s| __EXTRA__||" /usr/local/bin/ii-restart-all.sh
  fi
  chmod +x /usr/local/bin/ii-restart-all.sh

  cat > /etc/cron.d/internetincome <<'EOF_CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

15 4 * * 0 root /usr/local/bin/ii-restart-all.sh

# [CRITICAL PATCH] FLAPGUARD ENGINE - Kiểm tra và Dừng 12 tiếng nếu phát hiện lỗi Loop Reconnect (Chạy 10p/lần)
*/10 * * * * root /usr/local/bin/ii-flapguard.sh >/dev/null 2>&1

# [CRITICAL PATCH] BẢO VỆ CHỐNG BAN ACC: Loại trừ hoàn toàn nhóm nhạy cảm khỏi Auto-Start 15 phút
*/15 * * * * root for c in $(docker ps -aq -f status=exited 2>/dev/null); do n=$(docker inspect -f '{{.Name}}{{.Config.Image}}' "$c" 2>/dev/null); case "$n" in *honey*|*pawns*|*packetstream*|*packetshare*|*earnfm*|*wipter*|*depinext*|*ebesucher*|*adnade*|*earnapp*|*repocket*) ;; *) docker start "$c" >/dev/null 2>&1 ;; esac; done
*/15 * * * * root find /root /home /opt /srv /home/ubuntu /home/opc -name 'internetIncome.sh' -exec sed -i -E 's/--sysctl[ =]+net\.ipv6\.conf\.[a-zA-Z0-9_]+\.disable_ipv6=[0-9]//g' {} + >/dev/null 2>&1
0 3 * * 0 root /usr/bin/docker network prune -f >/dev/null 2>&1
15 3 * * 0 root /usr/bin/docker volume prune -f >/dev/null 2>&1
30 5 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1
EOF_CRON
  chmod 644 /etc/cron.d/internetincome

  if has_systemd; then
    systemctl enable --now cron >/dev/null 2>&1 || true
  else
    service cron start >/dev/null 2>&1 || true
  fi
}

if (( DO_CRON == 1 )); then
  install_cron_stack
fi

cat > /usr/local/bin/ii-status.sh <<'EOF_STATUS'
#!/usr/bin/env bash
set -u

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

echo -e "${C_B}==================== [INTERNETINCOME 24/7 VPS QUALITY DIAGNOSTIC] ====================${C_0}"
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "HOSTNAME     : $(hostname)"
echo "UPTIME       : $(uptime -p 2>/dev/null || uptime)"
echo "KERNEL/VIRT  : $(uname -r) ($(systemd-detect-virt 2>/dev/null || echo 'unknown'))"

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if (( MEM_MB <= 2500 )); then
  echo -e "HARDWARE TIER: ${C_B}[TIER 1: 1-2 CPU / 2GB RAM - LIGHTWEIGHT PROXIES]${C_0}"
elif (( MEM_MB <= 5000 )); then
  echo -e "HARDWARE TIER: ${C_B}[TIER 2: 2 CPU / 4GB RAM - BALANCED PROXIES]${C_0}"
elif (( MEM_MB <= 9000 )); then
  echo -e "HARDWARE TIER: ${C_B}[TIER 3: 2 CPU / 8GB RAM - HIGH DENSITY PROXIES]${C_0}"
else
  echo -e "HARDWARE TIER: ${C_B}[TIER 4: 2+ CPU / 12GB+ RAM - DEDICATED WIPTER / HEAVY APPS]${C_0}"
fi

ISSUES_COUNT=0
WARNINGS_COUNT=0

# --- 1. DOCKER CONTAINERS & RAM AUDIT ---
echo -e "\n${C_C}--- [1. NODE CONTAINERS & RAM LIMIT AUDIT] ---${C_0}"
ROOTS=("$@")
if (( ${#ROOTS[@]} == 0 )); then ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc); fi

found=0
while IFS= read -r cn; do
  d=$(dirname "$cn")
  [[ -f "${d}/internetIncome.sh" ]] || continue
  found=1
  total=0; running=0; stopped=0; oom_cnt=0; high_restart=0
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    state=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo "not_found")
    if [[ "$state" == "true" ]]; then
      running=$((running+1))
      total=$((total+1))
      oom=$(docker inspect -f '{{.State.OOMKilled}}' "$c" 2>/dev/null || echo "false")
      rc=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo "0")
      [[ "$oom" == "true" ]] && oom_cnt=$((oom_cnt+1))
      (( rc > 5 )) && high_restart=$((high_restart+1))
    elif [[ "$state" == "false" ]]; then
      stopped=$((stopped+1))
      total=$((total+1))
    fi
  done < "$cn"

  mark=""
  if (( stopped > 0 )); then
    mark="${mark} ${C_R}[${stopped} STOPPED]${C_0}"
    ISSUES_COUNT=$((ISSUES_COUNT+stopped))
  fi
  if (( oom_cnt > 0 )); then
    mark="${mark} ${C_R}[${oom_cnt} OOM KILLED]${C_0}"
    ISSUES_COUNT=$((ISSUES_COUNT+oom_cnt))
  fi
  if (( high_restart > 0 )); then
    mark="${mark} ${C_Y}[${high_restart} UNSTABLE RESTARTS]${C_0}"
    WARNINGS_COUNT=$((WARNINGS_COUNT+high_restart))
  fi
  (( total > 0 && stopped == 0 && oom_cnt == 0 && high_restart == 0 )) && mark="${C_G}[100% HEALTHY]${C_0}"

  printf "  %-42s %3s/%-3s running  %b\n" "$d" "$running" "$total" "$mark"
done < <(find "${ROOTS[@]}" -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)

if (( found == 0 )); then echo "  (No InternetIncome folders found)"; fi

RUNNING_CTRS=$(docker ps -q 2>/dev/null | wc -l)
TOTAL_CTRS=$(docker ps -aq 2>/dev/null | wc -l)
EXITED_CTRS=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
echo "  TOTAL SUMMARY: ${RUNNING_CTRS} running / ${TOTAL_CTRS} total (Exited: ${EXITED_CTRS})"

# --- AUDIT CHI TIẾT TỪNG NỀN TẢNG ---
echo -e "\n${C_C}--- [1b. PER-PLATFORM AUDIT: RAM / RESTART POLICY / IP TYPE] ---${C_0}"
PROFILES=/usr/local/lib/ii-app-profiles.sh
if [[ -r "$PROFILES" ]]; then
  . "$PROFILES"
  TIER_IDX=$(ii_tier_idx "$MEM_MB")
  printf "    %-16s %-9s %-16s %-6s %s\n" "APP" "RAM" "POLICY" "RC" "TRANG THAI"
  _any=0
  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    cn=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
    ci=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
    ii_profile "$cn" "$ci" "$TIER_IDX"
    [[ -n "$P_APP" ]] || continue
    case "$P_APP" in tun2socks|docker-in-docker) continue ;; esac
    _any=1
    cmem=$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null || echo 0)
    cmb=$(( cmem / 1024 / 1024 ))
    cpol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}{{if .HostConfig.RestartPolicy.MaximumRetryCount}}:{{.HostConfig.RestartPolicy.MaximumRetryCount}}{{end}}' "$cid" 2>/dev/null || echo "?")
    crc=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0)
    coom=$(docker inspect -f '{{.State.OOMKilled}}' "$cid" 2>/dev/null || echo false)
    want=${P_MEM%m}
    st=""; col="$C_G"
    if (( cmb == 0 )); then st="KHONG GIOI HAN"; col="$C_Y"; WARNINGS_COUNT=$((WARNINGS_COUNT+1))
    elif (( cmb < want )); then st="RAM THAP (can ${P_MEM})"; col="$C_R"; ISSUES_COUNT=$((ISSUES_COUNT+1))
    else st="OK"; fi
    if [[ "$coom" == "true" ]]; then st="OOM KILLED!"; col="$C_R"; ISSUES_COUNT=$((ISSUES_COUNT+1)); fi
    if [[ "$P_POLICY" != "__KEEP__" && "$cpol" == "always" ]]; then
      st="$st | policy=always NGUY HIEM"; col="$C_R"; ISSUES_COUNT=$((ISSUES_COUNT+1))
    fi
    printf "    ${col}%-16s %-9s %-16s %-6s %s${C_0}\n" "$P_APP" "${cmb}MB" "$cpol" "$crc" "$st"

    case "$P_VPS" in
      ban)  echo -e "      ${C_R}!! ${P_NOTE}${C_0}"
            echo -e "      ${C_R}!! GO NGAY app nay khoi VPS de tranh mat account${C_0}"
            ISSUES_COUNT=$((ISSUES_COUNT+1)) ;;
      resi) echo -e "      ${C_Y}~  Chi ho tro IP residential. Tren VPS: thu nhap gan 0 va co the bi khoa.${C_0}"
            WARNINGS_COUNT=$((WARNINGS_COUNT+1)) ;;
    esac
    if ii_is_suspend_sensitive "$cn"; then
      if (( crc > 3 )); then
        echo -e "      ${C_R}!! RestartCount=${crc} > 3 -> Đã chạm ngưỡng ngắt an toàn của FlapGuard!${C_0}"
        ISSUES_COUNT=$((ISSUES_COUNT+1))
      elif (( crc > 1 )); then
        echo -e "      ${C_Y}~  RestartCount=${crc} - Proxy không ổn định, FlapGuard đang bảo vệ.${C_0}"
        WARNINGS_COUNT=$((WARNINGS_COUNT+1))
      fi
    fi
    if [[ "$P_APP" == "Mysterium" ]]; then
      if docker inspect -f '{{range .HostConfig.Devices}}{{.PathOnHost}}{{end}}' "$cid" 2>/dev/null | grep -q '/dev/net/tun'; then
        echo -e "      ${C_G}+  TUN device da mount (WireGuard OK)${C_0}"
      else
        echo -e "      ${C_R}!! THIEU TUN -> CreateTUN(\"myst0\") failed, node KHONG kiem duoc tien${C_0}"
        ISSUES_COUNT=$((ISSUES_COUNT+1))
      fi
    fi
  done < <(docker ps -aq 2>/dev/null)
  (( _any == 0 )) && echo "    (Khong co app nao co ho so dang chay)"
else
  echo "    (Chua cai /usr/local/lib/ii-app-profiles.sh - chay lai setup_vps.sh)"
fi

if [[ -d /var/lib/ii-flapguard ]]; then
  _held=0
  for f in /var/lib/ii-flapguard/*.state; do
    [[ -e "$f" ]] || continue
    read -r _rc _t _stopped < "$f" 2>/dev/null || continue
    if [[ "${_stopped:-0}" != "0" ]]; then
      _left=$(( (${_stopped} + 43200 - $(date +%s)) / 3600 ))
      (( _left < 0 )) && _left=0
      echo -e "  ${C_Y}FLAPGUARD PROTECTION: $(basename "$f" .state) đang tạm dừng 12h để BẢO VỆ TÀI KHOẢN (Còn ~${_left}h)${C_0}"
      _held=1
    fi
  done
  (( _held == 0 )) && echo -e "  FLAPGUARD ENGINE: ${C_G}Khong co container nao bi loi Reconnect Loop${C_0}"
fi

if [[ -c /dev/net/tun ]]; then
  echo -e "  Host TUN Device        : ${C_G}/dev/net/tun OK (Mysterium co the chay)${C_0}"
else
  echo -e "  Host TUN Device        : ${C_R}THIEU! Mysterium se loi CreateTUN.${C_0}"
  WARNINGS_COUNT=$((WARNINGS_COUNT+1))
fi

# --- 2. NETWORK, PROXY & ROUTING HEALTH ---
echo -e "\n${C_C}--- [2. NETWORK, PROXY & ROUTING HEALTH] ---${C_0}"
IP_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
if [[ "$IP_FWD" == "1" ]]; then
  echo -e "  IP Forwarding (Routing)  : ${C_G}ENABLED (1)${C_0}"
else
  echo -e "  IP Forwarding (Routing)  : ${C_R}DISABLED (0) <-- CRITICAL!${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
fi

NTP_STAT=$(timedatectl status 2>/dev/null | grep "NTP service" | awk '{print $3}' || echo "unknown")
if [[ "$NTP_STAT" == "active" || "$NTP_STAT" == "yes" ]]; then
  echo -e "  NTP Time Sync Status    : ${C_G}ACTIVE (Strict millisecond accuracy)${C_0}"
else
  echo -e "  NTP Time Sync Status    : ${C_Y}INACTIVE (${NTP_STAT})${C_0}"
  WARNINGS_COUNT=$((WARNINGS_COUNT+1))
fi

DNS_START=$(date +%s%N 2>/dev/null || echo 0)
DNS_RES=$(timeout 2 host google.com 1.1.1.1 2>/dev/null || timeout 2 host google.com 8.8.8.8 2>/dev/null || echo "")
DNS_END=$(date +%s%N 2>/dev/null || echo 0)
if [[ -n "$DNS_RES" ]]; then
  DNS_MS=$(( (DNS_END - DNS_START) / 1000000 ))
  echo -e "  DNS Resolution (Google) : ${C_G}OK (${DNS_MS}ms)${C_0}"
else
  echo -e "  DNS Resolution (Google) : ${C_Y}CHECK_TIMEOUT (Fallback active)${C_0}"
fi

HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}\t%{time_total}" --connect-timeout 2 --max-time 3 http://1.1.1.1 2>/dev/null || curl -o /dev/null -s -w "%{http_code}\t%{time_total}" --connect-timeout 2 --max-time 3 -k https://google.com 2>/dev/null || echo "000 0")
CODE=$(echo "$HTTP_CODE" | awk '{print $1}')
TIME=$(echo "$HTTP_CODE" | awk '{print $2}')
if [[ "$CODE" == "200" || "$CODE" == "301" || "$CODE" == "302" ]]; then
  echo -e "  Outbound Internet Latency: ${C_G}ONLINE (HTTP ${CODE} in ${TIME}s)${C_0}"
else
  echo -e "  Outbound Internet Latency: ${C_R}BLOCKED / TIMEOUT (No Internet)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
fi

CONN_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CONN_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
CONN_PCT=$(( CONN_COUNT * 100 / CONN_MAX ))
if (( CONN_PCT > 80 )); then
  echo -e "  Conntrack Saturation    : ${C_R}${CONN_COUNT}/${CONN_MAX} (${CONN_PCT}% - NEAR SATURATION!)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
else
  echo -e "  Conntrack Active Streams: ${C_G}${CONN_COUNT} / ${CONN_MAX} (${CONN_PCT}% max)${C_0}"
fi

# --- 3. SYSTEM RAM, SWAP & ZRAM HEALTH ---
echo -e "\n${C_C}--- [3. SYSTEM RAM, SWAP & ZRAM ALLOCATION] ---${C_0}"
RAM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
RAM_USED=$(free -m | awk '/^Mem:/{print $3}')
RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
SWAP_VAL=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 0)

echo "  RAM  : Total ${RAM_TOTAL}MB | Used ${RAM_USED}MB | Avail ${RAM_AVAIL}MB"
echo "  Swap : Total ${SWAP_TOTAL}MB | Used ${SWAP_USED}MB | Swappiness ${SWAP_VAL}"

if swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
  ZRAM_SIZE=$(swapon --show 2>/dev/null | grep "/dev/zram0" | awk '{print $3}')
  ZRAM_ALGO=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -o '\[.*\]' | tr -d '[]' || echo "active")
  echo -e "  ZRAM : ${C_G}ACTIVE (${ZRAM_SIZE} ${ZRAM_ALGO^^} Priority 10)${C_0}"
else
  echo -e "  ZRAM : ${C_Y}NOT ACTIVE (Performance penalty)${C_0}"
  WARNINGS_COUNT=$((WARNINGS_COUNT+1))
fi

OOM_LOGS=$(dmesg 2>/dev/null | grep -i "out of memory" | tail -n 3 || echo "")
if [[ -n "$OOM_LOGS" ]]; then
  echo -e "  Kernel OOM Kills        : ${C_R}DETECTED RECENT OOM KILLS IN DMESG!${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
else
  echo -e "  Kernel OOM Kills        : ${C_G}NONE (Clean kernel log)${C_0}"
fi

# --- 4. CPU LOAD & DISK / FILESYSTEM HEALTH ---
echo -e "\n${C_C}--- [4. CPU, DISK I/O & FILESYSTEM HEALTH] ---${C_0}"
LOAD_1=$(cat /proc/loadavg | awk '{print $1}')
CPUS=$(nproc 2>/dev/null || echo 1)
echo "  CPU Cores: ${CPUS} | Load Avg (1m): ${LOAD_1}"

if touch /tmp/ii_rw_test 2>/dev/null; then
  rm -f /tmp/ii_rw_test
  echo -e "  Filesystem Write Mode  : ${C_G}READ-WRITE (Normal)${C_0}"
else
  echo -e "  Filesystem Write Mode  : ${C_R}READ-ONLY (CRITICAL: Disk corrupt or full!)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
fi

DISK_USE_PCT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
INODE_USE_PCT=$(df -i / | awk 'NR==2{print $5}' | tr -d '%')
if (( DISK_USE_PCT > 90 )); then
  echo -e "  Disk Storage Usage     : ${C_R}${DISK_USE_PCT}% used (FULL RISK!)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
else
  echo -e "  Disk Storage Usage     : ${C_G}${DISK_USE_PCT}% used${C_0}"
fi

if (( INODE_USE_PCT > 90 )); then
  echo -e "  Disk Inode Usage       : ${C_R}${INODE_USE_PCT}% used (INODE EXHAUSTION!)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
else
  echo -e "  Disk Inode Usage       : ${C_G}${INODE_USE_PCT}% used${C_0}"
fi

FILE_MAX=$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)
FILE_NR=$(cat /proc/sys/fs/file-nr 2>/dev/null | awk '{print $1}' || echo 0)
echo "  Open File Descriptors  : ${FILE_NR} / ${FILE_MAX}"

# --- 5. 24/7 INCOME STABILITY SUMMARY & QUALITY SCORE ---
echo -e "\n${C_B}---------------- [24/7 INCOME QUALITY DIAGNOSTIC SUMMARY] ----------------${C_0}"

SCORE=100
SCORE=$(( SCORE - (ISSUES_COUNT * 20) - (WARNINGS_COUNT * 5) ))
if (( SCORE < 0 )); then SCORE=0; fi

if (( ISSUES_COUNT == 0 && WARNINGS_COUNT == 0 )); then
  echo -e "  OVERALL SCORE : ${C_G}100% PERFECT${C_0} - System is 100% stable & optimal for maximum earnings!"
  echo -e "  STATUS        : ${C_G}[HEALTHY_SMOOTH_24_7]${C_0} No action required."
elif (( ISSUES_COUNT == 0 )); then
  echo -e "  OVERALL SCORE : ${C_Y}${SCORE}% GOOD${C_0} - System running fine with minor warnings."
  echo -e "  STATUS        : ${C_Y}[STABLE_WITH_WARNINGS]${C_0} Run 'sudo bash ~/setup_vps.sh' to re-optimize."
else
  echo -e "  OVERALL SCORE : ${C_R}${SCORE}% UNSTABLE (${ISSUES_COUNT} Critical Issues Found!)${C_0}"
  echo -e "  STATUS        : ${C_R}[INCOME_RISK_DETECTED]${C_0} Income loss risk! Run 'sudo bash ~/setup_vps.sh' immediately!"
fi
echo -e "${C_B}=========================================================================="
EOF_STATUS

chmod +x /usr/local/bin/ii-status.sh
ln -sf /usr/local/bin/ii-status.sh /usr/bin/ii-status.sh 2>/dev/null || true
ln -sf /usr/local/bin/ii-status.sh /usr/bin/ii-status 2>/dev/null || true

cat > /usr/local/bin/ii-deep.sh <<'EOF_DEEP'
#!/usr/bin/env bash
echo "==================== [PRO DEEP STABILITY DIAGNOSTIC] ===================="
echo "TIMESTAMP : $(date '+%Y-%m-%d %H:%M:%S')"
echo "HOSTNAME  : $(hostname)"
echo "UPTIME    : $(uptime -p 2>/dev/null || uptime)"
echo ""
echo "--- [1. MEMORY PRESSURE STALLS (PSI)] ---"
cat /proc/pressure/memory 2>/dev/null || echo "PSI not supported"
echo ""
echo "--- [2. KERNEL DMESG RECENT ERROR LOGS] ---"
ERRS=$(dmesg 2>/dev/null | grep -iE "error|fail|oom|read-only" | tail -n 8 || true)
if [[ -n "$ERRS" ]]; then echo "$ERRS"; else echo "Clean (No recent kernel errors)"; fi
echo ""
echo "--- [3. BANDWIDTH TRAFFIC STATS (vnstat)] ---"
vnstat -d 3 2>/dev/null || vnstat 2>/dev/null || echo "vnstat initializing..."
echo ""
echo "--- [4. TOP RESTARTING CONTAINERS] ---"
docker ps -a --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | head -n 6
echo ""
echo "--- [5. SAMPLE CONTAINER LOGS (3 Nodes)] ---"
for c in $(docker ps -q 2>/dev/null | shuf -n 3 2>/dev/null || docker ps -q 2>/dev/null | head -n 3); do
  c_name=$(docker inspect -f '{{.Name}}' "$c" 2>/dev/null || echo "$c")
  echo ">>> Log [$c_name]:"
  docker logs --tail 3 "$c" 2>&1 | sed 's/^/    /'
done
echo "=========================================================================="
EOF_DEEP
chmod +x /usr/local/bin/ii-deep.sh
ln -sf /usr/local/bin/ii-deep.sh /usr/bin/ii-deep 2>/dev/null || true

echo "============================= SETUP XONG (ULTRA ANTI-BAN EDITION) =============================="
/usr/local/bin/ii-status.sh || true
MASTER_EOF
chmod +x ~/setup_vps.sh

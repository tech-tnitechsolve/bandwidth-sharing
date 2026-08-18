cat << 'MASTER_EOF' > ~/setup_vps.sh
#!/usr/bin/env bash
#============================================================================
#  setup_vps.sh (2026 UNIVERSAL MASTER - ZERO DOWNTIME & ZERO PROXY UDP ERROR)
#============================================================================
set -Eeuo pipefail

ulimit -n 1048576 2>/dev/null || true
sysctl -w fs.inotify.max_user_watches=2097152 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_instances=65536 >/dev/null 2>&1 || true

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
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
DISK_TOTAL_MB=$(df -m / | awk 'NR==2 {print $2}')
DISK_FREE_MB=$(df -m / | awk 'NR==2 {print $4}')

# --- MATRIX PHÂN BỔ TÀI NGUYÊN (CHUẨN HÓA CHO Ổ SSD 20GB) ---
TIER_NAME=""
if (( MEM_MB <= 2500 )); then
  TIER_NAME="TIER 1 (1-2 CPU / 2GB RAM - LIGHTWEIGHT PROXIES)"
  CONTAINER_MEM_LIMIT="35m"; CONTAINER_SWAP_LIMIT="80m"
elif (( MEM_MB <= 5000 )); then
  TIER_NAME="TIER 2 (2 CPU / 4GB RAM - BALANCED PROXIES)"
  CONTAINER_MEM_LIMIT="45m"; CONTAINER_SWAP_LIMIT="100m"
elif (( MEM_MB <= 9000 )); then
  TIER_NAME="TIER 3 (2 CPU / 8GB RAM - HIGH DENSITY PROXIES)"
  CONTAINER_MEM_LIMIT="60m"; CONTAINER_SWAP_LIMIT="130m"
else
  TIER_NAME="TIER 4 (2+ CPU / 12GB+ RAM - DEDICATED WIPTER / HEAVY APPS)"
  CONTAINER_MEM_LIMIT="90m"; CONTAINER_SWAP_LIMIT="200m"
fi

# TỐI ƯU SWAPFILE Ổ CỨNG: Cố định 1024MB (1GB) để giữ ổ đĩa luôn ở mức ~50%
if (( MEM_MB >= 9000 )) || (( DISK_TOTAL_MB <= 25000 )); then
  TARGET_SWAP_MB=1024
elif (( MEM_MB <= 2500 )); then
  TARGET_SWAP_MB=1024
elif (( MEM_MB <= 5000 )); then
  TARGET_SWAP_MB=1536
else
  TARGET_SWAP_MB=2048
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
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools inotify-tools \
  iptables-persistent netfilter-persistent systemd-timesyncd systemd-resolved vnstat nload speedtest-cli dnsutils || true

# --- [BẢO VỆ CHỐNG BAN ACC] ĐỒNG BỘ THỜI GIAN NTP CHUẨN XÁC ---
if has_systemd; then
  systemctl unmask systemd-timesyncd 2>/dev/null || true
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  systemctl restart systemd-timesyncd 2>/dev/null || true
fi
timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true
log "Da dong bo thoi gian NTP chuan millisecond (Anti-Ban Token Enforced)!"

# --- [TỐI ƯU DNS ĐA TẦNG SIÊU TỐC & BẢO TOÀN GEOIP THU NHẬP] ---
log "Toi uu Smart Local DNS Cache (systemd-resolved) - Latency < 2ms..."
if has_systemd; then
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-income-dns.conf <<'EOF_RESOLV_CONF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 9.9.9.9
DNSStubListener=yes
Cache=yes
CacheFromLocalhost=yes
EOF_RESOLV_CONF
  systemctl unmask systemd-resolved 2>/dev/null || true
  systemctl enable --now systemd-resolved 2>/dev/null || true
  systemctl restart systemd-resolved 2>/dev/null || true
  
  if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
  fi
else
  cat > /etc/resolv.conf <<'EOF_FALLBACK_RESOLV'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:1 attempts:2 rotate
EOF_FALLBACK_RESOLV
fi

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

# --- CẤU HÌNH ZRAM ZSTD PRIORITY 10 ---
ZRAM_SIZE_BYTES=$(( MEM_MB * 1024 * 1024 ))
log "Kich hoat ZRAM ZSTD (${MEM_MB}MB)..."
modprobe zram num_devices=1 2>/dev/null || true
if [[ -b /dev/zram0 ]]; then
  swapon --show 2>/dev/null | grep -q "/dev/zram0" && swapoff /dev/zram0 2>/dev/null || true
  
  if grep -q "zstd" /sys/block/zram0/comp_algorithm 2>/dev/null; then
    echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    SELECTED_ALGO="zstd"
  else
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    SELECTED_ALGO="lz4"
  fi
  
  echo "$ZRAM_SIZE_BYTES" > /sys/block/zram0/disksize 2>/dev/null || true
  mkswap /dev/zram0 >/dev/null 2>&1
  swapon -p 10 /dev/zram0 2>/dev/null || true
  log "Da kich hoat ZRAM ${MEM_MB}MB (${SELECTED_ALGO^^} Priority 10) thanh cong!"
fi

SWAPPINESS=100
sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true

if (( CPU <= 2 )); then
  CONCURRENT_DOWNLOADS=3; SYN_BACKLOG=8192
elif (( CPU <= 4 )); then
  CONCURRENT_DOWNLOADS=5; SYN_BACKLOG=16384
else
  CONCURRENT_DOWNLOADS=8; SYN_BACKLOG=32768
fi

echo "=============================================================="
echo "  VPS $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU | SSD ${DISK_TOTAL_MB}MB"
echo "  DETECTED PROFILE : ${TIER_NAME}"
echo "  ZRAM COMPRESSION : ZSTD (MAX DENSITY)"
echo "  SSD SWAP TARGET  : ${TARGET_SWAP_MB}MB (SMART 20GB SSD PROFILE)"
echo "  DNS RESOLVER     : SYSTEMD-RESOLVED LOCAL CACHE (<2ms)"
echo "=============================================================="

CURR_DISK_SWAP_MB=$(swapon --show=NAME,SIZE --bytes 2>/dev/null | awk '/swapfile/{print int($2/1024/1024)}' || echo 0)

if (( IS_CONTAINER == 1 )); then
  warn "May ${VIRT} (container) thuong KHONG tao duoc swap -> bo qua"
else
  if (( CURR_DISK_SWAP_MB != TARGET_SWAP_MB )); then
    log "Chuan hoa Swapfile ve dung muc tieu ${TARGET_SWAP_MB}MB de giu SSD o muc ~50%..."
    swapoff /swapfile /swapfile2 2>/dev/null || true
    rm -f /swapfile /swapfile2 2>/dev/null || true
    
    if ! fallocate -l "${TARGET_SWAP_MB}M" /swapfile 2>/dev/null; then
      dd if=/dev/zero of=/swapfile bs=1M count="$TARGET_SWAP_MB" status=none
    fi
    chmod 600 /swapfile
    if mkswap /swapfile >/dev/null 2>&1 && swapon -p 0 /swapfile 2>/dev/null; then
      grep -q "^/swapfile" /etc/fstab || echo "/swapfile none swap sw,pri=0 0 0" >> /etc/fstab
      log "Da tao Swapfile /swapfile ${TARGET_SWAP_MB}MB thanh cong!"
    else
      rm -f /swapfile
    fi
  else
    log "Swapfile tren SSD da dung chuan ${CURR_DISK_SWAP_MB}MB -> Giu nguyen"
  fi
fi

apt-get clean 2>/dev/null || true
journalctl --vacuum-size=10M 2>/dev/null || true

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

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF_APT'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF_APT

modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

modprobe tun 2>/dev/null || true
if [[ ! -c /dev/net/tun ]]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 600 /dev/net/tun 2>/dev/null || true
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

# --- TỐI ƯU KERNEL CHUYÊN SÂU ĐỒNG HÓA PROXY VÀ CHỐNG DROP PACKET ---
SYSCTL_FILE=/etc/sysctl.d/99-internetincome.conf
cat > "$SYSCTL_FILE" <<EOF_SYSCTL
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
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
log "Kernel Tuning Safe Mode xong"

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
# THƯ VIỆN HỒ SƠ ỨNG DỤNG ĐÃ ĐƯỢC CÂN CHỈNH RAM CHUẨN XÁC
#============================================================================
mkdir -p /usr/local/lib
cat > /usr/local/lib/ii-app-profiles.sh <<'EOF_PROFILES'
#!/usr/bin/env bash
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
      P_APP="tun2socks";  P_MEM=$(_p $t 25m 32m 48m 64m);   P_SWAP=$(_p $t 50m 64m 96m 128m)
      P_POLICY="unless-stopped"; P_NOTE="Ha tang mang proxy" ;;
    dindurnetwork*|dindproxylite*|adnadedind*|dind*)
      P_APP="docker-in-docker"; P_MEM=$(_p $t 120m 140m 180m 220m); P_SWAP=$(_p $t 240m 280m 360m 440m)
      P_POLICY="unless-stopped"; P_NOTE="Docker-in-Docker ha tang" ;;

    myst*)
      P_APP="Mysterium"; P_MEM=$(_p $t 160m 200m 250m 300m); P_SWAP=$(_p $t 320m 400m 500m 600m)
      P_VPS="safe"; P_NOTE="Can /dev/net/tun" ;;
    traffmon*)
      P_APP="Traffmonetizer"; P_MEM=$(_p $t 40m 50m 65m 80m); P_SWAP=$(_p $t 80m 100m 130m 160m)
      P_VPS="safe"; P_NOTE="Lightweight binary" ;;
    bitping*)
      P_APP="Bitping"; P_MEM=$(_p $t 50m 65m 80m 100m); P_SWAP=$(_p $t 100m 130m 160m 200m)
      P_VPS="safe"; P_NOTE="Network tests node" ;;
    proxyrack*)
      P_APP="Proxyrack"; P_MEM=$(_p $t 40m 50m 65m 80m); P_SWAP=$(_p $t 80m 100m 130m 160m)
      P_VPS="safe" ;;
    proxybase*)
      P_APP="Proxybase"; P_MEM=$(_p $t 40m 50m 65m 80m); P_SWAP=$(_p $t 80m 100m 130m 160m)
      P_VPS="safe" ;;
    proxylite*)
      P_APP="Proxylite"; P_MEM=$(_p $t 40m 50m 65m 80m); P_SWAP=$(_p $t 80m 100m 130m 160m)
      P_VPS="safe" ;;
    peer2profit*)
      P_APP="Peer2Profit"; P_MEM=$(_p $t 50m 65m 80m 100m); P_SWAP=$(_p $t 100m 130m 160m 200m)
      P_VPS="safe" ;;
    urnetwork*)
      P_APP="URnetwork"; P_MEM=$(_p $t 60m 80m 100m 120m); P_SWAP=$(_p $t 120m 160m 200m 240m)
      P_VPS="safe" ;;
    titan*)
      P_APP="Titan Network"; P_MEM=$(_p $t 150m 180m 220m 280m); P_SWAP=$(_p $t 300m 360m 440m 560m)
      P_VPS="safe" ;;
    antgain*)
      P_APP="AntGain"; P_MEM=$(_p $t 40m 50m 65m 80m); P_SWAP=$(_p $t 80m 100m 130m 160m)
      P_VPS="safe" ;;
    wizardgain*)
      P_APP="WizardGain"; P_MEM=$(_p $t 40m 50m 65m 80m); P_SWAP=$(_p $t 80m 100m 130m 160m)
      P_VPS="safe" ;;

    honey*)
      P_APP="Honeygain"; P_MEM=$(_p $t 120m 140m 160m 200m); P_SWAP=$(_p $t 240m 280m 320m 400m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1
      P_NOTE="ULTRA ANTI-BAN" ;;
    repocket*)
      P_APP="Repocket"; P_MEM=$(_p $t 120m 140m 160m 200m); P_SWAP=$(_p $t 240m 280m 320m 400m)
      P_POLICY="on-failure:3"; P_VPS="safe"; P_MAXIP=1 ;;
    packetstream*)
      P_APP="PacketStream"; P_MEM=$(_p $t 65m 80m 100m 120m); P_SWAP=$(_p $t 130m 160m 200m 240m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1 ;;
    pawns*)
      P_APP="IPRoyal Pawns"; P_MEM=$(_p $t 65m 80m 100m 120m); P_SWAP=$(_p $t 130m 160m 200m 240m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1 ;;
    packetshare*)
      P_APP="Packetshare"; P_MEM=$(_p $t 65m 80m 100m 120m); P_SWAP=$(_p $t 130m 160m 200m 240m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1 ;;
    earnfm*)
      P_APP="EarnFM"; P_MEM=$(_p $t 80m 100m 120m 150m); P_SWAP=$(_p $t 160m 200m 240m 300m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1 ;;

    wipter*)
      P_APP="Wipter"; P_MEM=$(_p $t 320m 350m 400m 500m); P_SWAP=$(_p $t 600m 700m 800m 1000m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;
    depinext*)
      P_APP="Depin/Grass ext"; P_MEM=$(_p $t 300m 350m 400m 500m); P_SWAP=$(_p $t 600m 700m 800m 1000m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;
    ebesucher*)
      P_APP="Ebesucher"; P_MEM=$(_p $t 320m 350m 400m 500m); P_SWAP=$(_p $t 600m 700m 800m 1000m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;
    adnade*)
      P_APP="Adnade"; P_MEM=$(_p $t 320m 350m 400m 500m); P_SWAP=$(_p $t 600m 700m 800m 1000m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;
    earnapp*)
      P_APP="EarnApp"; P_MEM=$(_p $t 65m 80m 100m 120m); P_SWAP=$(_p $t 130m 160m 200m 240m)
      P_POLICY="on-failure:3"; P_VPS="ban"; P_MAXIP=1 ;;

    *)
      P_APP=""; P_POLICY="unless-stopped"; P_NOTE="Khong co ho so - giu mac dinh" ;;
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

#============================================================================
# FLAPGUARD ULTRA
#============================================================================
cat > /usr/local/bin/ii-flapguard.sh <<'EOF_FLAPGUARD'
#!/usr/bin/env bash
set -uo pipefail
PROFILES=/usr/local/lib/ii-app-profiles.sh
[[ -r "$PROFILES" ]] && . "$PROFILES"
LOG=/var/log/ii-flapguard.log
STATE=/var/lib/ii-flapguard
mkdir -p "$STATE" 2>/dev/null || true

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
      say "[$cname] Het cooldown. Mo lai an toan."
      docker start "$cid" >/dev/null 2>&1 || true
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
  if (( delta < 0 )); then echo "$rc $now 0" > "$f"; continue; fi

  if (( delta > FLAP_MAX )); then
    say "[$cname] FLAP DETECTED: ${delta} restarts trong $(( elapsed/60 )) phut -> Dung 12h."
    docker update --restart=no "$cid" >/dev/null 2>&1 || true
    docker stop "$cid" >/dev/null 2>&1 || true
    echo "$rc $now $now" > "$f"
  else
    echo "$rc $now 0" > "$f"
  fi
done
find "$STATE" -name '*.state' -mtime +14 -delete 2>/dev/null || true
EOF_FLAPGUARD
chmod +x /usr/local/bin/ii-flapguard.sh
ln -sf /usr/local/bin/ii-flapguard.sh /usr/bin/ii-flapguard 2>/dev/null || true

#============================================================================
# ENGINE TỰ ĐỘNG ĐỒNG BỘ RAM VÀ POLICY CHO MỌI CONTAINER
#============================================================================
cat > /usr/local/bin/ii-autosync.sh <<'EOF_AUTOSYNC'
#!/usr/bin/env bash
set -uo pipefail

PROFILES=/usr/local/lib/ii-app-profiles.sh
[[ -r "$PROFILES" ]] && . "$PROFILES"
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
TIER_IDX=$(ii_tier_idx "$MEM_MB" 2>/dev/null || echo 1)

find /root /opt /home /srv -maxdepth 4 -name "internetIncome.sh" -exec sed -i "s/--restart=always/--restart=unless-stopped/g" {} + 2>/dev/null || true
find /root /opt /home /srv -maxdepth 4 -name "internetIncome.sh" -exec sed -i "s/--restart always/--restart=unless-stopped/g" {} + 2>/dev/null || true

for cid in $(docker ps -aq 2>/dev/null); do
  c_img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
  c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || true)
  ii_profile "$c_name" "$c_img" "$TIER_IDX"
  [[ -n "$P_MEM" ]] || continue
  
  cmem=$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null || echo 0)
  cpol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null || echo "")
  
  want_bytes=$(( ${P_MEM%m} * 1024 * 1024 ))
  
  # Neu chua set RAM hoac Policy sai lech -> Update ngay
  if (( cmem == 0 || cmem < (want_bytes - 2097152) )) || [[ "$cpol" == "always" ]]; then
    docker update --memory="$P_MEM" --memory-swap="$P_SWAP" --restart="$P_POLICY" "$cid" >/dev/null 2>&1 || \
    docker update --memory="$P_MEM" --restart="$P_POLICY" "$cid" >/dev/null 2>&1 || true
  fi
done
EOF_AUTOSYNC
chmod +x /usr/local/bin/ii-autosync.sh
ln -sf /usr/local/bin/ii-autosync.sh /usr/bin/ii-autosync 2>/dev/null || true

/usr/local/bin/ii-autosync.sh

# --- DOCKER DAEMON CONFIG (KHÔNG HARDCODE DNS VÀO DOCKER ĐỂ TRÁNH LỖI UDP) ---
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF_DAEMON
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "2m", "max-file": "2" },
  "registry-mirrors": ["https://mirror.gcr.io", "https://docker.m.daocloud.io"],
  "max-concurrent-downloads": ${CONCURRENT_DOWNLOADS},
  "live-restore": true,
  "userland-proxy": false,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 }
  }
}
EOF_DAEMON

if has_systemd; then
  systemctl restart docker || true
  systemctl enable --now docker >/dev/null 2>&1 || true
fi

while ! docker info >/dev/null 2>&1; do sleep 1; done

#============================================================================
# ENGINE KHỞI ĐỘNG TUẦN TỰ (TUNNEL-FIRST)
#============================================================================
cat > /usr/local/bin/ii-staggered-start.sh <<'EOF_STAGGER'
#!/usr/bin/env bash
set -uo pipefail
command -v docker >/dev/null 2>&1 || exit 0
while ! docker info >/dev/null 2>&1; do sleep 1; done

TOTAL_NODES=$(docker ps -aq 2>/dev/null | wc -l)
echo "=== BAT DAU KHOI DONG TUAN TU ${TOTAL_NODES} CONTAINER ==="

for cid in $(docker ps -aq 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  if [[ "$cname" =~ ^tun|^dind ]]; then
    running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")
    if [[ "$running" != "true" ]]; then
      docker start "$cid" >/dev/null 2>&1 || true
      sleep 1
    fi
  fi
done

sleep 2

IDX=0
for cid in $(docker ps -aq 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")
  IDX=$((IDX+1))
  if [[ "$running" == "true" ]]; then continue; fi

  docker start "$cid" >/dev/null 2>&1 || true

  if [[ "$cname" =~ wipter|ebesucher|adnade|depinext ]]; then
    sleep 8
  elif [[ "$cname" =~ honey|repocket|packetstream|packetshare|pawns|earnfm|earnapp ]]; then
    sleep 3.5
  else
    sleep 0.8
  fi
done
echo "=== TAT CA ${TOTAL_NODES} NODE DA ONLINE AN TOAN ==="
EOF_STAGGER
chmod +x /usr/local/bin/ii-staggered-start.sh

if has_systemd; then
  cat > /etc/systemd/system/ii-boot-staggered.service <<'EOF_BOOT_SVC'
[Unit]
Description=InternetIncome Staggered Container Boot
After=docker.service zramswap.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ii-staggered-start.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_BOOT_SVC
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable ii-boot-staggered.service 2>/dev/null || true
fi

/usr/local/bin/ii-staggered-start.sh

install_cron_stack() {
  cat > /usr/local/bin/ii-restart-all.sh <<'EOF_RESTART'
#!/usr/bin/env bash
LOG=/var/log/ii-restart.log
ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc __EXTRA__)
ts() { date '+%F %T'; }
{
  echo "[$(ts)] ==================== ii-restart-all ===================="
  /usr/local/bin/ii-staggered-start.sh
  /usr/local/bin/ii-autosync.sh
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
*/5 * * * * root /usr/local/bin/ii-autosync.sh >/dev/null 2>&1
15 4 * * 0 root /usr/local/bin/ii-restart-all.sh
*/10 * * * * root /usr/local/bin/ii-flapguard.sh >/dev/null 2>&1
*/15 * * * * root for c in $(docker ps -aq -f status=exited 2>/dev/null); do n=$(docker inspect -f '{{.Name}}{{.Config.Image}}' "$c" 2>/dev/null); case "$n" in *honey*|*pawns*|*packetstream*|*packetshare*|*earnfm*|*wipter*|*depinext*|*ebesucher*|*adnade*|*earnapp*|*repocket*) ;; *) docker start "$c" >/dev/null 2>&1 ;; esac; done
0 3 * * 0 root /usr/bin/docker network prune -f >/dev/null 2>&1
15 3 * * 0 root /usr/bin/docker volume prune -f >/dev/null 2>&1
30 5 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1
EOF_CRON
  chmod 644 /etc/cron.d/internetincome

  if has_systemd; then systemctl enable --now cron 2>/dev/null || true; fi
}

if (( DO_CRON == 1 )); then install_cron_stack; fi

#============================================================================
# BẢNG CHẨN ĐOÁN TINH GỌN (ĐÃ FIX LỖI TÍNH TOÁN WARNINGS & LOCAL DNS)
#============================================================================
cat > /usr/local/bin/ii-status.sh <<'EOF_STATUS'
#!/usr/bin/env bash
set +u

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

echo -e "${C_B}==================== [INTERNETINCOME 24/7 TELEMETRY DIAGNOSTIC] ====================${C_0}"
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

# --- 1. DOCKER FOLDER DIRECTORY AUDIT ---
echo -e "\n${C_C}--- [1. NODE DIRECTORIES & ACTIVE AUDIT] ---${C_0}"
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

RUNNING_CTRS=$(docker ps -q 2>/dev/null | wc -l)
TOTAL_CTRS=$(docker ps -aq 2>/dev/null | wc -l)
EXITED_CTRS=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
echo "  TOTAL SUMMARY: ${RUNNING_CTRS} running / ${TOTAL_CTRS} total (Exited: ${EXITED_CTRS})"

# --- 1B. BẢNG TỔNG HỢP THEO TỪNG NỀN TẢNG ---
echo -e "\n${C_C}--- [1b. PLATFORMS AGGREGATION & ANTI-BAN AUDIT] ---${C_0}"
PROFILES=/usr/local/lib/ii-app-profiles.sh
if [[ -r "$PROFILES" ]]; then
  . "$PROFILES"
  TIER_IDX=$(ii_tier_idx "$MEM_MB")
  
  declare -A APP_COUNT APP_MEM APP_POL APP_OK APP_WARN APP_ERR

  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    cn=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
    ci=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
    ii_profile "$cn" "$ci" "$TIER_IDX"
    
    app_key="${P_APP:-Unknown}"
    cmem=$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null || echo 0)
    cmb=$(( (cmem + 1048575) / 1024 / 1024 ))
    cpol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null || echo "?")
    coom=$(docker inspect -f '{{.State.OOMKilled}}' "$cid" 2>/dev/null || echo false)
    crc=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0)
    want=${P_MEM%m}

    APP_COUNT["$app_key"]=$(( ${APP_COUNT["$app_key"]:-0} + 1 ))
    APP_MEM["$app_key"]="${cmb}MB"
    APP_POL["$app_key"]="$cpol"
    APP_ERR["$app_key"]=${APP_ERR["$app_key"]:-0}
    APP_WARN["$app_key"]=${APP_WARN["$app_key"]:-0}
    APP_OK["$app_key"]=${APP_OK["$app_key"]:-0}

    if [[ "$coom" == "true" ]] || [[ "$cpol" == "always" && "$P_POLICY" != "__KEEP__" ]]; then
      APP_ERR["$app_key"]=$(( ${APP_ERR["$app_key"]} + 1 ))
      ISSUES_COUNT=$((ISSUES_COUNT+1))
    elif (( want > 0 && cmb < (want - 2) )); then
      APP_WARN["$app_key"]=$(( ${APP_WARN["$app_key"]} + 1 ))
      WARNINGS_COUNT=$((WARNINGS_COUNT+1))
    else
      APP_OK["$app_key"]=$(( ${APP_OK["$app_key"]} + 1 ))
    fi

    if ii_is_suspend_sensitive "$cn" && (( crc > 3 )); then
      WARNINGS_COUNT=$((WARNINGS_COUNT+1))
    fi
  done < <(docker ps -aq 2>/dev/null)

  printf "  %-18s %-7s %-9s %-16s %s\n" "PLATFORM" "NODES" "RAM/NODE" "POLICY" "STATUS"
  for app in "${!APP_COUNT[@]}"; do
    err_cnt=${APP_ERR["$app"]:-0}
    warn_cnt=${APP_WARN["$app"]:-0}
    total_cnt=${APP_COUNT["$app"]}
    mem_val=${APP_MEM["$app"]}
    pol_val=${APP_POL["$app"]}
    
    st_col="$C_G"; st_text="[100% HEALTHY]"
    if (( err_cnt > 0 )); then
      st_col="$C_R"; st_text="[${err_cnt} RISK DETECTED]"
    elif (( warn_cnt > 0 )); then
      st_col="$C_Y"; st_text="[${warn_cnt} WARNINGS]"
    fi
    printf "  ${st_col}%-18s %-7s %-9s %-16s %s${C_0}\n" "$app" "$total_cnt" "$mem_val" "$pol_val" "$st_text"
  done
fi

if [[ -d /var/lib/ii-flapguard ]]; then
  _held=0
  for f in /var/lib/ii-flapguard/*.state; do
    [[ -e "$f" ]] || continue
    read -r _rc _t _stopped < "$f" 2>/dev/null || continue
    if [[ "${_stopped:-0}" != "0" ]]; then
      _left=$(( (${_stopped} + 43200 - $(date +%s)) / 3600 ))
      (( _left < 0 )) && _left=0
      echo -e "  ${C_Y}FLAPGUARD PROTECTION: $(basename "$f" .state) đang tạm dừng 12h (Còn ~${_left}h)${C_0}"
      _held=1
    fi
  done
  (( _held == 0 )) && echo -e "  FLAPGUARD ENGINE: ${C_G}Khong co container nao bi loi Reconnect Loop${C_0}"
fi

if [[ -c /dev/net/tun ]]; then
  echo -e "  Host TUN Device        : ${C_G}/dev/net/tun OK (WireGuard / Mysterium Ready)${C_0}"
fi

# --- 2. NETWORK, PROXY & ROUTING HEALTH ---
echo -e "\n${C_C}--- [2. NETWORK, PROXY & ROUTING HEALTH] ---${C_0}"
IP_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
if [[ "$IP_FWD" == "1" ]]; then
  echo -e "  IP Forwarding (Routing)  : ${C_G}ENABLED (1)${C_0}"
else
  echo -e "  IP Forwarding (Routing)  : ${C_R}DISABLED (0)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
fi

NTP_ACTIVE=0
if systemctl is-active systemd-timesyncd >/dev/null 2>&1 || [[ "$(timedatectl status 2>/dev/null | grep -i 'NTP service' | awk '{print $3}')" =~ active|yes ]]; then
  NTP_ACTIVE=1
fi

if (( NTP_ACTIVE == 1 )); then
  echo -e "  NTP Time Sync Status    : ${C_G}ACTIVE (Strict millisecond accuracy)${C_0}"
else
  echo -e "  NTP Time Sync Status    : ${C_Y}INACTIVE (Syncing...)${C_0}"
  WARNINGS_COUNT=$((WARNINGS_COUNT+1))
fi

DNS_START=$(date +%s%N 2>/dev/null || echo 0)
DNS_RES=$(timeout 2 host google.com 127.0.0.53 2>/dev/null || timeout 2 host google.com 1.1.1.1 2>/dev/null || timeout 2 host google.com 8.8.8.8 2>/dev/null || echo "")
DNS_END=$(date +%s%N 2>/dev/null || echo 0)
if [[ -n "$DNS_RES" ]]; then
  DNS_MS=$(( (DNS_END - DNS_START) / 1000000 ))
  echo -e "  DNS Resolution (Local Cache): ${C_G}OK (${DNS_MS}ms)${C_0}"
else
  echo -e "  DNS Resolution (Local Cache): ${C_Y}CHECK_TIMEOUT${C_0}"
fi

HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}\t%{time_total}" --connect-timeout 2 --max-time 3 http://1.1.1.1 2>/dev/null || curl -o /dev/null -s -w "%{http_code}\t%{time_total}" --connect-timeout 2 --max-time 3 -k https://google.com 2>/dev/null || echo "000 0")
CODE=$(echo "$HTTP_CODE" | awk '{print $1}')
TIME=$(echo "$HTTP_CODE" | awk '{print $2}')
if [[ "$CODE" == "200" || "$CODE" == "301" || "$CODE" == "302" ]]; then
  echo -e "  Outbound Internet Latency: ${C_G}ONLINE (HTTP ${CODE} in ${TIME}s)${C_0}"
else
  echo -e "  Outbound Internet Latency: ${C_R}BLOCKED / TIMEOUT${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
fi

CONN_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CONN_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
CONN_PCT=$(( CONN_COUNT * 100 / CONN_MAX ))
echo -e "  Conntrack Active Streams: ${C_G}${CONN_COUNT} / ${CONN_MAX} (${CONN_PCT}% capacity)${C_0}"

# --- 3. SYSTEM RAM, SWAP & ZRAM ALLOCATION ---
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
  echo -e "  ZRAM : ${C_Y}NOT ACTIVE${C_0}"
  WARNINGS_COUNT=$((WARNINGS_COUNT+1))
fi

OOM_LOGS=$(dmesg 2>/dev/null | grep -i "out of memory" | tail -n 3 || echo "")
if [[ -n "$OOM_LOGS" ]]; then
  echo -e "  Kernel OOM Kills        : ${C_R}DETECTED RECENT OOM KILLS!${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
else
  echo -e "  Kernel OOM Kills        : ${C_G}NONE (Clean kernel memory log)${C_0}"
fi

# --- 4. CPU LOAD & DISK / FILESYSTEM HEALTH ---
echo -e "\n${C_C}--- [4. CPU LOAD & DISK / FILESYSTEM HEALTH] ---${C_0}"
LOAD_1=$(cat /proc/loadavg | awk '{print $1}')
LOAD_5=$(cat /proc/loadavg | awk '{print $2}')
LOAD_15=$(cat /proc/loadavg | awk '{print $3}')
CPUS=$(nproc 2>/dev/null || echo 1)
echo "  CPU Cores: ${CPUS} | Load Avg (1m, 5m, 15m): ${LOAD_1}, ${LOAD_5}, ${LOAD_15}"

if touch /tmp/ii_rw_test 2>/dev/null; then
  rm -f /tmp/ii_rw_test
  echo -e "  Filesystem Write Mode  : ${C_G}READ-WRITE (Normal)${C_0}"
else
  echo -e "  Filesystem Write Mode  : ${C_R}READ-ONLY (CRITICAL!)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
fi

DISK_USE_PCT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
INODE_USE_PCT=$(df -i / | awk 'NR==2{print $5}' | tr -d '%')
echo -e "  Disk Storage Usage     : ${C_G}${DISK_USE_PCT}% used${C_0} | Inode Usage: ${C_G}${INODE_USE_PCT}% used${C_0}"

# --- 5. TỔNG KẾT ---
echo -e "\n${C_B}---------------- [24/7 INCOME QUALITY DIAGNOSTIC SUMMARY] ----------------${C_0}"
SCORE=100
SCORE=$(( SCORE - (ISSUES_COUNT * 20) - (WARNINGS_COUNT * 5) ))
if (( SCORE < 0 )); then SCORE=0; fi

if (( ISSUES_COUNT == 0 && WARNINGS_COUNT == 0 )); then
  echo -e "  OVERALL SCORE : ${C_G}100% PERFECT${C_0} - System is 100% stable & optimal for maximum earnings!"
  echo -e "  STATUS        : ${C_G}[HEALTHY_SMOOTH_24_7]${C_0} No action required."
elif (( ISSUES_COUNT == 0 )); then
  echo -e "  OVERALL SCORE : ${C_Y}${SCORE}% GOOD${C_0} - System running fine with minor warnings."
  echo -e "  STATUS        : ${C_Y}[STABLE_WITH_WARNINGS]${C_0} AutoSync engine is maintaining containers."
else
  echo -e "  OVERALL SCORE : ${C_R}${SCORE}% UNSTABLE (${ISSUES_COUNT} Critical Issues Found!)${C_0}"
  echo -e "  STATUS        : ${C_R}[INCOME_RISK_DETECTED]${C_0} AutoSync engine is repairing containers."
fi
echo -e "${C_B}=========================================================================="
EOF_STATUS
chmod +x /usr/local/bin/ii-status.sh
ln -sf /usr/local/bin/ii-status.sh /usr/bin/ii-status 2>/dev/null || true

echo "============================= SETUP XONG (2026 UNIVERSAL MASTER) =============================="
/usr/local/bin/ii-status.sh || true
MASTER_EOF
chmod +x ~/setup_vps.sh
sudo bash ~/setup_vps.sh

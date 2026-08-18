cat << 'VM_MASTER_EOF' > ~/setup_vm.sh
#!/usr/bin/env bash
#============================================================================
#  setup_vm.sh (2026 UNIVERSAL VM MASTER - ZERO UDP ERROR & FULL-AUTO SYNC)
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

AUTO_OFF=""
DO_PULL=1
DO_CRON=1
BASE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-off)   AUTO_OFF="${2:-}"; shift 2 ;;
    --auto-off=*) AUTO_OFF="${1#*=}"; shift ;;
    --base-dir)   BASE_DIR="${2:-}"; shift 2 ;;
    --base-dir=*) BASE_DIR="${1#*=}"; shift ;;
    --no-pull)    DO_PULL=0; shift ;;
    --no-cron)    DO_CRON=0; shift ;;
    -h|--help)    grep '^#' "$0" | head -n 22; exit 0 ;;
    *) die "Tham so khong hop le: $1 (xem: bash $0 --help)" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Can chay bang quyen root: sudo bash $0"
command -v apt-get >/dev/null 2>&1 || die "Script ho tro Debian/Ubuntu (apt-get)"

if [[ -n "$AUTO_OFF" ]]; then
  [[ "$AUTO_OFF" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--auto-off phai dang HH:MM (vd 23:30)"
  OFF_H=$((10#${AUTO_OFF%%:*}))
  OFF_M=$((10#${AUTO_OFF##*:}))
fi

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
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)

# --- MATRIX PHÂN BỔ TÀI NGUYÊN (CHUẨN HÓA CHO VM) ---
TIER_NAME=""
if (( MEM_MB <= 2500 )); then
  TIER_NAME="TIER 1 (1-2 CPU / 2GB RAM - LIGHTWEIGHT PROXIES)"
  CONTAINER_MEM_LIMIT="35m"; CONTAINER_SWAP_LIMIT="80m"; TARGET_SWAP_MB=2048
elif (( MEM_MB <= 5000 )); then
  TIER_NAME="TIER 2 (2 CPU / 4GB RAM - BALANCED PROXIES)"
  CONTAINER_MEM_LIMIT="45m"; CONTAINER_SWAP_LIMIT="100m"; TARGET_SWAP_MB=3072
elif (( MEM_MB <= 9000 )); then
  TIER_NAME="TIER 3 (2 CPU / 8GB RAM - HIGH DENSITY PROXIES)"
  CONTAINER_MEM_LIMIT="60m"; CONTAINER_SWAP_LIMIT="130m"; TARGET_SWAP_MB=4096
else
  TIER_NAME="TIER 4 (2+ CPU / 12GB+ RAM - DEDICATED WIPTER / HEAVY APPS)"
  CONTAINER_MEM_LIMIT="90m"; CONTAINER_SWAP_LIMIT="200m"; TARGET_SWAP_MB=4096
fi

TIER_IDX=1
if   (( MEM_MB <= 2500 )); then TIER_IDX=1
elif (( MEM_MB <= 5000 )); then TIER_IDX=2
elif (( MEM_MB <= 9000 )); then TIER_IDX=3
else                            TIER_IDX=4
fi

if (( CPU <= 2 )); then
  CONCURRENT_DOWNLOADS=3; SYN_BACKLOG=8192
elif (( CPU <= 4 )); then
  CONCURRENT_DOWNLOADS=5; SYN_BACKLOG=16384
else
  CONCURRENT_DOWNLOADS=8; SYN_BACKLOG=32768
fi

echo "=============================================================="
echo "  PERSONAL VM $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU | Ao hoa: ${VIRT}"
echo "  DETECTED PROFILE : ${TIER_NAME}"
echo "  ZRAM COMPRESSION : ZSTD (MAX DENSITY - CALIBRATED)"
echo "  ULTRA ANTI-BAN ENFORCED: Honeygain / Repocket / Packetstream / Pawns / Wipter"
echo "=============================================================="

log "Giai phong khoa APT Lock..."
if has_systemd; then
  systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
  systemctl disable apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
fi
pkill -9 -f "apt|dpkg|unattended-upgrades" 2>/dev/null || true
rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null || true
dpkg --configure -a 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

log "apt update & install goi phu thuoc cho VM..."
apt-get update -y -qq || true
apt-get install -y -qq --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools inotify-tools \
  iptables-persistent netfilter-persistent systemd-timesyncd vnstat nload speedtest-cli dnsutils || true

# --- [ĐẶC THÙ VM] ĐỒNG BỘ THỜI GIAN CHỐNG LỆCH GIỜ KHI WINDOWS SLEEP ---
if has_systemd; then
  systemctl unmask systemd-timesyncd 2>/dev/null || true
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  systemctl restart systemd-timesyncd 2>/dev/null || true
fi
timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true
log "Da dong bo thoi gian NTP chuan millisecond (Anti-Ban Sleep Drift Fix)!"

#============================================================================
# [TỐI ƯU DNS CHO VM - GIỮ GATEWAY WINDOWS HOST & CHỐNG DROP PACKET PROXY]
#============================================================================
log "Cau hinh DNS Direct-Upstream cho VM (Uu tien vSwitch Gateway & Fallback Cloudflare/Google)..."

# 1. Trích xuất DNS từ Gateway ảo của Windows (VMware NAT / Hyper-V vSwitch)
VM_GATEWAY_DNS=""
if [[ -f /run/systemd/resolve/resolv.conf ]]; then
  VM_GATEWAY_DNS=$(grep -E '^nameserver' /run/systemd/resolve/resolv.conf 2>/dev/null | grep -v '127.0.0.53' | awk '{print $2}' || true)
fi

# 2. Xây dựng resolv.conf trực tiếp bằng Real Nameservers
rm -f /etc/resolv.conf
{
  echo "# Generated for VM Income Nodes (Direct Upstream Mode)"
  echo "options timeout:1 attempts:2 rotate"
  for dns in $VM_GATEWAY_DNS; do
    echo "nameserver $dns"
  done
  echo "nameserver 1.1.1.1"
  echo "nameserver 8.8.8.8"
  echo "nameserver 9.9.9.9"
} | awk '!seen[$0]++' > /etc/resolv.conf
chmod 644 /etc/resolv.conf

log "Kich hoat KSM gop RAM ngam cho VM..."
if [[ -f /sys/kernel/mm/ksm/run ]]; then
  echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
  echo 300 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
  echo 1250 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
fi

# --- CẤU HÌNH ZRAM ZSTD PRIORITY 10 CHO VM ---
ZRAM_SIZE_BYTES=$(( MEM_MB * 1024 * 1024 ))
log "Kich hoat ZRAM ZSTD (${MEM_MB}MB) cho VM..."
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

if swapon --show=NAME --noheadings 2>/dev/null | grep -q "/swapfile"; then
  log "Da co swap đia /swapfile -> giu nguyen"
elif [[ "$VIRT" =~ ^(lxc|lxc-libvirt|openvz)$ ]]; then
  warn "May ${VIRT} khong tao duoc swap"
else
  log "Tao swap đia ${TARGET_SWAP_MB}MB..."
  if ! fallocate -l "${TARGET_SWAP_MB}M" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count="$TARGET_SWAP_MB" status=none
  fi
  chmod 600 /swapfile
  if mkswap /swapfile >/dev/null 2>&1 && swapon -p 0 /swapfile 2>/dev/null; then
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw,pri=0 0 0' >> /etc/fstab
    log "Tao swap đia /swapfile ${TARGET_SWAP_MB}MB thanh cong"
  else
    rm -f /swapfile
  fi
fi

if has_systemd; then
  systemctl stop snapd earlyoom 2>/dev/null || true
  systemctl disable snapd earlyoom 2>/dev/null || true
fi
apt-get purge -y snapd earlyoom 2>/dev/null || true
rm -rf /var/cache/snapd/ /var/lib/snapd/ 2>/dev/null || true

modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

# --- [MYSTERIUM TUN DEVICE SUPPORT CHO VM] ---
modprobe tun 2>/dev/null || true
if [[ ! -c /dev/net/tun ]]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 600 /dev/net/tun 2>/dev/null || true
fi
MYST_TUN_OK=0
if [[ -c /dev/net/tun ]]; then
  echo tun > /etc/modules-load.d/tun.conf 2>/dev/null || true
  MYST_TUN_OK=1
  log "TUN device san sang (/dev/net/tun) -> Mysterium co the chay"
fi

iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true

SYSCTL_FILE=/etc/sysctl.d/99-internetincome.conf
cat > "$SYSCTL_FILE" <<EOF_SYSCTL
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
vm.max_map_count = 262144
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152
vm.min_free_kbytes = 32768
vm.page-cluster = 0
vm.overcommit_memory = 1
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 3
vm.dirty_ratio = 8
fs.file-max = 2097152
fs.inotify.max_user_instances = 65536
fs.inotify.max_user_watches = 1048576
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

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue
  sysctl -w "$line" >/dev/null 2>&1 || true
done < "$SYSCTL_FILE"
log "Kernel Tuning Safe Mode xong"

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
SystemMaxUse=20M
RuntimeMaxUse=10M
EOF_JOURNAL
if has_systemd; then systemctl restart systemd-journald 2>/dev/null || true; fi

if ! command -v docker >/dev/null 2>&1; then
  log "Cai dat Docker cho VM..."
  curl -fsSL https://get.docker.com | sh
else
  log "Docker da co san: $(docker --version 2>/dev/null || echo '?')"
fi

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  usermod -aG docker "${SUDO_USER}" 2>/dev/null || true
fi

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
      P_NOTE="ULTRA ANTI-BAN: Restart 3 lần dừng hẳn. Khóa 1 device/IP" ;;
    repocket*)
      P_APP="Repocket"; P_MEM=$(_p $t 120m 140m 160m 200m); P_SWAP=$(_p $t 240m 280m 320m 400m)
      P_POLICY="on-failure:3"; P_VPS="safe"; P_MAXIP=1
      P_NOTE="Node.js Sweet Spot 120MB" ;;
    packetstream*)
      P_APP="PacketStream"; P_MEM=$(_p $t 65m 80m 100m 120m); P_SWAP=$(_p $t 130m 160m 200m 240m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1
      P_NOTE="ULTRA ANTI-BAN: Ngắt kết nối ngay khi Proxy đứt" ;;
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
      P_POLICY="on-failure:5"; P_VPS="resi"
      P_NOTE="Chromium Heap Calibrated 320MB" ;;
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
      P_APP=""; P_POLICY="unless-stopped"; P_NOTE="Khong co ho so - giu nguyen cau hinh goc" ;;
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
# FLAPGUARD ULTRA CHO VM
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
      say "[$cname] Het cooldown ($(( (now-stopped_at)/3600 )) gio). Mo lai an toan."
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

  if (( delta < 0 )); then
    echo "$rc $now 0" > "$f"
    continue
  fi

  if (( delta > FLAP_MAX )); then
    say "[$cname] FLAP DETECTED: ${delta} lan restart trong $(( elapsed/60 )) phut -> DUNG 12 TIENG."
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
# ENGINE TỰ ĐỘNG ĐỒNG BỘ RAM VÀ POLICY CHO VM
#============================================================================
cat > /usr/local/bin/ii-autosync.sh <<'EOF_AUTOSYNC'
#!/usr/bin/env bash
set -uo pipefail

PROFILES=/usr/local/lib/ii-app-profiles.sh
[[ -r "$PROFILES" ]] && . "$PROFILES"
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
TIER_IDX=$(ii_tier_idx "$MEM_MB" 2>/dev/null || echo 1)

find /home/antoine /root /opt /home /srv -maxdepth 4 -name "internetIncome.sh" -exec sed -i "s/--restart=always/--restart=unless-stopped/g" {} + 2>/dev/null || true
find /home/antoine /root /opt /home /srv -maxdepth 4 -name "internetIncome.sh" -exec sed -i "s/--restart always/--restart=unless-stopped/g" {} + 2>/dev/null || true

for cid in $(docker ps -aq 2>/dev/null); do
  c_img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
  c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || true)
  ii_profile "$c_name" "$c_img" "$TIER_IDX"
  [[ -n "$P_MEM" ]] || continue
  
  cmem=$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null || echo 0)
  cpol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null || echo "")
  
  want_bytes=$(( ${P_MEM%m} * 1024 * 1024 ))
  
  if (( cmem == 0 || cmem < (want_bytes - 2097152) )) || [[ "$cpol" == "always" ]]; then
    docker update --memory="$P_MEM" --memory-swap="$P_SWAP" --restart="$P_POLICY" "$cid" >/dev/null 2>&1 || \
    docker update --memory="$P_MEM" --restart="$P_POLICY" "$cid" >/dev/null 2>&1 || true
  fi
done
EOF_AUTOSYNC
chmod +x /usr/local/bin/ii-autosync.sh
ln -sf /usr/local/bin/ii-autosync.sh /usr/bin/ii-autosync 2>/dev/null || true

/usr/local/bin/ii-autosync.sh

# --- DOCKER DAEMON CONFIG (KHÔNG GHI ĐÈ DNS ĐỂ BẢO VỆ TUN2SOCKS) ---
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF_DAEMON
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
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
# ENGINE KHỞI ĐỘNG TUẦN TỰ (TUNNEL-FIRST CHO VM)
#============================================================================
cat > /usr/local/bin/ii-staggered-start.sh <<'EOF_STAGGER'
#!/usr/bin/env bash
set -uo pipefail
command -v docker >/dev/null 2>&1 || exit 0
while ! docker info >/dev/null 2>&1; do sleep 1; done

TOTAL_NODES=$(docker ps -aq 2>/dev/null | wc -l)
echo "=== BAT DAU KHOI DONG TUAN TU ${TOTAL_NODES} CONTAINER TREN VM ==="

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
echo "=== TAT CA ${TOTAL_NODES} NODE DA ONLINE AN TOAN TREN VM! ==="
EOF_STAGGER
chmod +x /usr/local/bin/ii-staggered-start.sh

# --- AUTOSTART CHỜ vSWITCH WINDOWS & ĐỒNG BỘ NTP NGAY KHI MỞ VM ---
cat > /usr/local/bin/ii-autostart.sh <<'EOS_AUTOSTART'
#!/usr/bin/env bash
LOG=/var/log/ii-autostart.log
ts() { date '+%F %T'; }

echo "[$(ts)] AUTOSTART: Dang cho vSwitch mang Windows on dinh (20s)..." >> "$LOG"
sleep 20

# Ép đồng bộ lại đồng hồ ngay đề phòng Windows vừa tỉnh dậy từ chế độ Sleep
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart systemd-timesyncd >/dev/null 2>&1 || true
fi

echo "[$(ts)] AUTOSTART: Khoi dong cac containers theo chuan Tunnel-First..." >> "$LOG"
/usr/local/bin/ii-staggered-start.sh >> "$LOG" 2>&1
/usr/local/bin/ii-autosync.sh >> "$LOG" 2>&1
EOS_AUTOSTART
chmod +x /usr/local/bin/ii-autostart.sh

/usr/local/bin/ii-staggered-start.sh

cat > /usr/local/bin/ii-restart-all.sh <<'EOF_RESTART'
#!/usr/bin/env bash
LOG=/var/log/ii-restart.log
ROOTS=(/home/antoine /opt /root /home /srv __EXTRA__)
ts() { date '+%F %T'; }

{
  echo "[$(ts)] ==================== ii-restart-all (VM EDITION) ===================="
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
ln -sf /usr/local/bin/ii-restart-all.sh /usr/bin/ii-restart-all 2>/dev/null || true

if (( DO_PULL == 1 )); then
  log "Pre-pulling core docker images cho VM..."
  for img in "traffmonetizer/cli_v2:latest" "xjasonlyu/tun2socks:latest"; do
    docker pull "$img" >/dev/null 2>&1 || true
  done
fi

#============================================================================
# BẢNG CHẨN ĐOÁN CHÍNH XÁC (ĐÃ FIX LỖI TÍNH WARNINGS CHO VM)
#============================================================================
cat > /usr/local/bin/ii-status.sh <<'EOF_STATUS'
#!/usr/bin/env bash
set +u

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

echo -e "${C_B}==================== [PERSONAL VM 24/7 TELEMETRY DIAGNOSTIC] ====================${C_0}"
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
if (( ${#ROOTS[@]} == 0 )); then ROOTS=(/home/antoine /opt /root /home /srv); fi

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

# --- 2. NETWORK & TIME SYNC ---
echo -e "\n${C_C}--- [2. NETWORK & TIME SYNC] ---${C_0}"
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
DNS_RES=$(timeout 2 host -W 1 google.com 2>/dev/null || echo "")
DNS_END=$(date +%s%N 2>/dev/null || echo 0)
if [[ -n "$DNS_RES" ]]; then
  DNS_MS=$(( (DNS_END - DNS_START) / 1000000 ))
  echo -e "  DNS Resolution (Direct) : ${C_G}OK (${DNS_MS}ms)${C_0}"
else
  echo -e "  DNS Resolution (Direct) : ${C_Y}CHECK_TIMEOUT${C_0}"
fi

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

# --- 4. CPU LOAD & DISK / FILESYSTEM HEALTH ---
echo -e "\n${C_C}--- [4. CPU LOAD & DISK / FILESYSTEM HEALTH] ---${C_0}"
LOAD_1=$(cat /proc/loadavg | awk '{print $1}')
LOAD_5=$(cat /proc/loadavg | awk '{print $2}')
LOAD_15=$(cat /proc/loadavg | awk '{print $3}')
CPUS=$(nproc 2>/dev/null || echo 1)
echo "  CPU Cores: ${CPUS} | Load Avg (1m, 5m, 15m): ${LOAD_1}, ${LOAD_5}, ${LOAD_15}"

DISK_USE_PCT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
INODE_USE_PCT=$(df -i / | awk 'NR==2{print $5}' | tr -d '%')
echo -e "  Disk Storage Usage     : ${C_G}${DISK_USE_PCT}% used${C_0} | Inode Usage: ${C_G}${INODE_USE_PCT}% used${C_0}"

# --- 5. TỔNG KẾT ---
echo -e "\n${C_B}---------------- [VM INCOME QUALITY DIAGNOSTIC SUMMARY] ----------------${C_0}"
SCORE=100
SCORE=$(( SCORE - (ISSUES_COUNT * 20) - (WARNINGS_COUNT * 5) ))
if (( SCORE < 0 )); then SCORE=0; fi

if (( ISSUES_COUNT == 0 && WARNINGS_COUNT == 0 )); then
  echo -e "  OVERALL SCORE : ${C_G}100% PERFECT${C_0} - VM is 100% stable & optimal for maximum earnings!"
  echo -e "  STATUS        : ${C_G}[HEALTHY_SMOOTH_VM]${C_0} Personal VM is running perfectly!"
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
echo "=========================================================================="
EOF_DEEP
chmod +x /usr/local/bin/ii-deep.sh
ln -sf /usr/local/bin/ii-deep.sh /usr/bin/ii-deep 2>/dev/null || true

cat > /etc/logrotate.d/ii-logs <<'EOF_LOGROTATE'
/var/log/ii-*.log {
    weekly
    rotate 4
    size 10M
    missingok
    notifempty
    copytruncate
}
EOF_LOGROTATE

if (( DO_CRON == 1 )); then
  {
    echo 'SHELL=/bin/bash'
    echo 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
    echo ''
    echo '# Tự động đồng bộ chuẩn hóa RAM cho các folder IP mới tạo (Chạy 5p/lần ngầm)'
    echo '*/5 * * * * root /usr/local/bin/ii-autosync.sh >/dev/null 2>&1'
    echo ''
    echo '# Sau khi MỞ VM: Tự động khởi động lại các Container mượt mà sau 20s (chờ vSwitch Windows)'
    echo '@reboot root /usr/local/bin/ii-autostart.sh'
    echo '*/10 * * * * root /usr/local/bin/ii-flapguard.sh >/dev/null 2>&1'
    echo '*/15 * * * * root for c in $(docker ps -aq -f status=exited 2>/dev/null); do n=$(docker inspect -f '\''{{.Name}}{{.Config.Image}}'\'' "$c" 2>/dev/null); case "$n" in *honey*|*pawns*|*packetstream*|*packetshare*|*earnfm*|*wipter*|*depinext*|*ebesucher*|*adnade*|*earnapp*|*repocket*) ;; *) docker start "$c" >/dev/null 2>&1 ;; esac; done'
    echo '0 3 * * 0 root /usr/bin/docker network prune -f >/dev/null 2>&1'
    echo '15 3 * * 0 root /usr/bin/docker volume prune -f >/dev/null 2>&1'
    echo '30 5 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1'
    if [[ -n "$AUTO_OFF" ]]; then
      echo ''
      echo "# Tự TẮT MÁY ẢO đúng giờ bạn đặt (${AUTO_OFF})"
      echo "${OFF_M} ${OFF_H} * * * root /usr/sbin/poweroff"
    fi
  } > /etc/cron.d/internetincome
  chmod 644 /etc/cron.d/internetincome

  if has_systemd; then
    systemctl enable --now cron >/dev/null 2>&1 || true
  else
    service cron start >/dev/null 2>&1 || true
  fi
fi

log "Autostart: container tu chay lai mượt mà mỗi khi MỞ VM (@reboot)"
if [[ -n "$AUTO_OFF" ]]; then
  log "Auto-off: may se tu poweroff luc ${AUTO_OFF} hang ngay"
fi

echo
echo "============================= SETUP XONG (VM 2026 UNIVERSAL MASTER) =============================="
/usr/local/bin/ii-status.sh || true
VM_MASTER_EOF
chmod +x ~/setup_vm.sh
sudo bash ~/setup_vm.sh

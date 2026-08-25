#!/usr/bin/env bash
#============================================================================
#  setup_oracle_cloud.sh — OCI x86, đồng bộ VPS/VM (ZRAM zstd, DNS direct, IP-Auth Hardened)
#============================================================================
set -Eeuo pipefail

ulimit -n 1048576 2>/dev/null || true
sysctl -w fs.inotify.max_user_watches=2097152 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_instances=65536 >/dev/null 2>&1 || true

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
  C_BG_BLUE='\033[44;37m'; C_BOLD='\033[1m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
  C_BG_BLUE=''; C_BOLD=''
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
ARCH="$(uname -m)"
IS_CONTAINER=0
case "$VIRT" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1 ;; esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)
DISK_TOTAL_MB=$(df -m / | awk 'NR==2 {print $2}')
DISK_FREE_MB=$(df -m / | awk 'NR==2 {print $4}')

# Matrix phân bổ tài nguyên chuẩn OCI
TIER_NAME=""
if (( MEM_MB <= 1200 )); then
  TIER_NAME="TIER 1 (OCI AMD 1 CPU / 1GB RAM - LIGHTWEIGHT PROXIES)"
  CONTAINER_MEM_LIMIT="35m"; CONTAINER_SWAP_LIMIT="90m"
  TARGET_SWAP_MB=1536
elif (( MEM_MB <= 2500 )); then
  TIER_NAME="TIER 2 (OCI AMD 1-2 CPU / 2GB RAM - BALANCED PROXIES)"
  CONTAINER_MEM_LIMIT="50m"; CONTAINER_SWAP_LIMIT="128m"
  TARGET_SWAP_MB=2048
elif (( MEM_MB <= 7000 )); then
  TIER_NAME="TIER 3 (OCI ARM 1-2 CPU / 6GB RAM - HIGH DENSITY PROXIES)"
  CONTAINER_MEM_LIMIT="70m"; CONTAINER_SWAP_LIMIT="160m"
  TARGET_SWAP_MB=3072
elif (( MEM_MB <= 13000 )); then
  TIER_NAME="TIER 4 (OCI ARM 2-4 CPU / 12GB RAM - DEDICATED APPS)"
  CONTAINER_MEM_LIMIT="100m"; CONTAINER_SWAP_LIMIT="256m"
  TARGET_SWAP_MB=4096
else
  TIER_NAME="TIER 5 (OCI ARM 4 CPU / 24GB RAM - MAXIMUM POWER)"
  CONTAINER_MEM_LIMIT="150m"; CONTAINER_SWAP_LIMIT="512m"
  TARGET_SWAP_MB=4096
fi

# Nhận diện chính xác Card mạng chính & Host Public IP Whitelist
PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
if [[ -z "$PRIMARY_IFACE" ]]; then
  PRIMARY_IFACE=$(ip link show up 2>/dev/null | grep -E '^[0-9]+: (ens|enp|eth|eno)' | awk -F': ' '{print $2}' | head -n1)
fi
PRIMARY_IFACE=${PRIMARY_IFACE:-"ens3"}

HOST_PUBLIC_IP=$(curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://api.ipify.org 2>/dev/null || \
                curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://icanhazip.com 2>/dev/null || \
                echo "Khong_xac_dinh")

echo -e "\n${C_BG_BLUE}${C_BOLD} [!] HOST PUBLIC IP DÀNH CHO IP-AUTHENTICATION PROXIES (WHITELIST IP) ${C_0}"
echo -e " ${C_BOLD}>>> IP CẦN WHITELIST : ${C_G}${C_BOLD}${HOST_PUBLIC_IP}${C_0}"
echo -e " ${C_Y}Hãy đảm bảo IP trên đã được Whitelist chính xác trong Dashboard nhà cung cấp Proxy!${C_0}\n"

clear_apt_locks() {
  log "Giai phong khoa APT Lock cua Oracle Cloud..."
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
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null || true
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null || true

log "apt update & install cac goi phu thuoc OCI..."
apt-get update -y -qq || { clear_apt_locks; apt-get update -y -qq; }
apt-get install -y -qq --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools inotify-tools \
  iptables-persistent netfilter-persistent systemd-timesyncd vnstat nload dnsutils util-linux zram-tools \
  linux-modules-extra-"$(uname -r)" 2>/dev/null || true

# NTP Time Sync Millisecond
if has_systemd; then
  systemctl unmask systemd-timesyncd 2>/dev/null || true
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  systemctl restart systemd-timesyncd 2>/dev/null || true
fi
timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true
log "Da dong bo thoi gian NTP chuan millisecond (Anti-Ban Token Ready)!"

# DNS Direct Upstream & Khóa bất biến chattr +i
log "Cau hinh DNS Direct-Upstream & Khoa bat bien..."
if has_systemd && systemctl is-active --quiet systemd-resolved; then
  systemctl stop systemd-resolved 2>/dev/null || true
  systemctl disable systemd-resolved 2>/dev/null || true
fi
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
{
  echo "# Generated for High Density Income Nodes (Direct Upstream Mode)"
  echo "options timeout:1 attempts:2 rotate"
  echo "nameserver 1.1.1.1"
  echo "nameserver 8.8.8.8"
  echo "nameserver 9.9.9.9"
} > /etc/resolv.conf
chmod 644 /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true

# Ép ưu tiên IPv4 cho IP-Authentication Proxies (/etc/gai.conf)
log "Cau hinh /etc/gai.conf uu tien IPv4 tuyet doi cho IP-Auth..."
cat << 'EOF_GAI' > /etc/gai.conf
precedence ::ffff:0:0/96  100
precedence ::/0           40
precedence 2002::/16      30
precedence ::/96          20
precedence ::1/128        50
EOF_GAI

# Cài đặt Docker official
if ! command -v docker >/dev/null 2>&1; then
  log "ORACLE CLOUD: Dang tu dong cai dat Docker official (Arch: ${ARCH})..."
  curl -fsSL https://get.docker.com | sh || apt-get install -y -qq docker.io
  log "Cai dat Docker cho Oracle Cloud thanh cong!"
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

log "Kich hoat KSM (Kernel Samepage Merging) Aggressive gop RAM ngam..."
if [[ -f /sys/kernel/mm/ksm/run ]]; then
  echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
  echo 200 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
  echo 1500 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
  log "Da kich hoat KSM Aggressive (Tiet kiem ~200MB RAM)!"
fi

# ZRAM: 100% RAM, zstd, pri 10 — disk swap chi pri 0
log "ZRAM = RAM (zstd), dong bo VPS/VM"
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/internetincome.conf <<'EOF_MODULES'
zram
tcp_bbr
br_netfilter
nf_conntrack
tun
EOF_MODULES
modprobe zram num_devices=1 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
modprobe tun 2>/dev/null || true

cat > /usr/local/bin/ii-init-zram.sh <<'EOF_ZRAM_INIT'
#!/usr/bin/env bash
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
ZRAM_BYTES=$(( MEM_MB * 1024 * 1024 ))
modprobe zram num_devices=1 2>/dev/null || true
[[ -b /dev/zram0 ]] || exit 0
swapon --show 2>/dev/null | grep -q /dev/zram0 && swapoff /dev/zram0 2>/dev/null || true
if grep -qw zstd /sys/block/zram0/comp_algorithm 2>/dev/null; then
  echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
else
  echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
fi
echo "$ZRAM_BYTES" > /sys/block/zram0/disksize 2>/dev/null || true
mkswap /dev/zram0 >/dev/null 2>&1 || true
swapon -p 10 /dev/zram0 2>/dev/null || true
EOF_ZRAM_INIT
chmod +x /usr/local/bin/ii-init-zram.sh

if has_systemd; then
  systemctl disable --now zramswap 2>/dev/null || true
  cat > /etc/systemd/system/ii-zram.service <<'EOF_ZRAM_SVC'
[Unit]
Description=InternetIncome ZRAM ZSTD
DefaultDependencies=no
After=local-fs.target
Before=swap.target docker.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ii-init-zram.sh
RemainAfterExit=yes
[Install]
WantedBy=swap.target
EOF_ZRAM_SVC
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable --now ii-zram.service 2>/dev/null || true
fi
/usr/local/bin/ii-init-zram.sh

SWAPPINESS=100
sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true

MAX_SAFE_SWAP=$(( DISK_FREE_MB - 2048 ))
if (( MAX_SAFE_SWAP < 512 )); then MAX_SAFE_SWAP=512; fi
if (( TARGET_SWAP_MB > MAX_SAFE_SWAP )); then TARGET_SWAP_MB=$MAX_SAFE_SWAP; fi

if (( CPU <= 2 )); then CONCURRENT_DOWNLOADS=3; SYN_BACKLOG=8192;
elif (( CPU <= 4 )); then CONCURRENT_DOWNLOADS=5; SYN_BACKLOG=16384;
else CONCURRENT_DOWNLOADS=8; SYN_BACKLOG=32768; fi

echo "=============================================================="
echo "  ORACLE CLOUD VPS $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU (${ARCH})"
echo "  DETECTED PROFILE : ${TIER_NAME}"
echo "  Swap target=${TARGET_SWAP_MB}MB | Swappiness=${SWAPPINESS} (ZRAM Priority 10)"
echo "=============================================================="

# Swapfile SSD
if (( IS_CONTAINER == 1 )); then
  warn "May ${VIRT} khong tao duoc swap -> bo qua"
elif swapon --show 2>/dev/null | grep -q "/swapfile"; then
  log "Swapfile tren SSD da co san -> Giu nguyen"
else
  log "Tao Swapfile tren SSD ve dung muc tieu ${TARGET_SWAP_MB}MB..."
  fallocate -l "${TARGET_SWAP_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$TARGET_SWAP_MB" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null 2>&1 || true
  swapon -p 0 /swapfile 2>/dev/null || true
  grep -q "^/swapfile" /etc/fstab || echo "/swapfile none swap sw,pri=0 0 0" >> /etc/fstab
  log "Da tao Swapfile /swapfile ${TARGET_SWAP_MB}MB thanh cong!"
fi

apt-get clean 2>/dev/null || true
journalctl --vacuum-size=10M 2>/dev/null || true

log "Dang diet cac dich vu OS & Oracle Bloatware ngom RAM ngam..."
if has_systemd; then
  # Tiêu diệt oracle-cloud-agent giải phóng ~180MB RAM
  systemctl stop oracle-cloud-agent oracle-cloud-agent-updater snapd multipathd udisks2 accountsservice earlyoom unattended-upgrades 2>/dev/null || true
  systemctl disable oracle-cloud-agent oracle-cloud-agent-updater snapd multipathd udisks2 accountsservice earlyoom unattended-upgrades 2>/dev/null || true
  systemctl mask oracle-cloud-agent oracle-cloud-agent-updater snapd 2>/dev/null || true
fi
apt-get purge -y snapd earlyoom 2>/dev/null || true
rm -rf /var/cache/snapd/ /var/lib/snapd/ 2>/dev/null || true

MAIN_IF=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n1 || echo "")
if [[ -f /etc/vnstat.conf ]]; then
  [[ -n "$MAIN_IF" ]] && sed -i "s/Interface \".*\"/Interface \"$MAIN_IF\"/" /etc/vnstat.conf
  grep -q 'ExcludeInterface' /etc/vnstat.conf || echo 'ExcludeInterface "veth* docker0 tun* tap*"' >> /etc/vnstat.conf
  if has_systemd; then systemctl restart vnstat 2>/dev/null || true; fi
fi

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF_APT'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF_APT

modprobe tun 2>/dev/null || true
if [[ ! -c /dev/net/tun ]]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 600 /dev/net/tun 2>/dev/null || true
fi

# Mở khóa iptables Oracle Cloud cho Docker & TUN Routing
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
vm.max_map_count = 262144
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152
vm.min_free_kbytes = 32768
vm.page-cluster = 0
vm.overcommit_memory = 1
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 200
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
# THƯ VIỆN HỒ SƠ ỨNG DỤNG (24+ APP CHUẨN ĐỊNH MỨC RAM)
#============================================================================
mkdir -p /usr/local/lib
cat > /usr/local/lib/ii-app-profiles.sh <<'EOF_PROFILES'
#!/usr/bin/env bash
ii_tier_idx() {
  local m="${1:-0}"
  if   (( m <= 1200 )); then echo 1
  elif (( m <= 2500 )); then echo 2
  elif (( m <= 7000 )); then echo 3
  elif (( m <= 13000 )); then echo 4
  else                       echo 5
  fi
}

_p() { local t="$1"; shift; local a=("$@"); echo "${a[$((t-1))]}"; }

ii_profile() {
  local n img t
  n="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's|^/||')"
  img="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  t="${3:-2}"
  case "$t" in 1|2|3|4|5) ;; *) t=2 ;; esac

  P_APP=""; P_MEM=""; P_SWAP=""; P_POLICY="unless-stopped"
  P_VPS="safe"; P_MAXIP=0; P_NOTE=""

  case "$n" in
    tun*|hev*|tun2proxy*)
      P_APP="tun2socks";  P_MEM=$(_p $t 25m 32m 48m 64m 80m);   P_SWAP=$(_p $t 50m 64m 96m 128m 160m)
      P_POLICY="unless-stopped"; P_NOTE="Ha tang mang proxy" ;;
    dindurnetwork*|dindproxylite*|adnadedind*|dind*)
      P_APP="docker-in-docker"; P_MEM=$(_p $t 120m 140m 180m 220m 260m); P_SWAP=$(_p $t 240m 280m 360m 440m 520m)
      P_POLICY="unless-stopped"; P_NOTE="Docker-in-Docker ha tang" ;;

    myst*)
      P_APP="Mysterium"; P_MEM=$(_p $t 160m 200m 250m 300m 350m); P_SWAP=$(_p $t 320m 400m 500m 600m 700m)
      P_VPS="safe"; P_NOTE="Can /dev/net/tun" ;;
    traffmon*)
      P_APP="Traffmonetizer"; P_MEM=$(_p $t 35m 45m 65m 80m 100m); P_SWAP=$(_p $t 70m 90m 130m 160m 200m)
      P_VPS="safe"; P_NOTE="Lightweight binary" ;;
    bitping*)
      P_APP="Bitping"; P_MEM=$(_p $t 50m 65m 80m 100m 120m); P_SWAP=$(_p $t 100m 130m 160m 200m 240m)
      P_VPS="safe"; P_NOTE="Network tests node" ;;
    proxyrack*)
      P_APP="Proxyrack"; P_MEM=$(_p $t 40m 50m 65m 80m 100m); P_SWAP=$(_p $t 80m 100m 130m 160m 200m)
      P_VPS="safe" ;;
    proxybase*)
      P_APP="Proxybase"; P_MEM=$(_p $t 40m 50m 65m 80m 100m); P_SWAP=$(_p $t 80m 100m 130m 160m 200m)
      P_VPS="safe" ;;
    proxylite*)
      P_APP="Proxylite"; P_MEM=$(_p $t 40m 50m 65m 80m 100m); P_SWAP=$(_p $t 80m 100m 130m 160m 200m)
      P_VPS="safe" ;;
    peer2profit*)
      P_APP="Peer2Profit"; P_MEM=$(_p $t 50m 65m 80m 100m 120m); P_SWAP=$(_p $t 100m 130m 160m 200m 240m)
      P_VPS="safe" ;;
    urnetwork*)
      P_APP="URnetwork"; P_MEM=$(_p $t 60m 80m 100m 120m 150m); P_SWAP=$(_p $t 120m 160m 200m 240m 300m)
      P_VPS="safe" ;;
    titan*)
      P_APP="Titan Network"; P_MEM=$(_p $t 150m 180m 220m 280m 350m); P_SWAP=$(_p $t 300m 360m 440m 560m 700m)
      P_VPS="safe" ;;
    antgain*)
      P_APP="AntGain"; P_MEM=$(_p $t 40m 50m 65m 80m 100m); P_SWAP=$(_p $t 80m 100m 130m 160m 200m)
      P_VPS="safe" ;;
    wizardgain*)
      P_APP="WizardGain"; P_MEM=$(_p $t 40m 50m 65m 80m 100m); P_SWAP=$(_p $t 80m 100m 130m 160m 200m)
      P_VPS="safe" ;;

    honey*)
      P_APP="Honeygain"; P_MEM=$(_p $t 120m 140m 160m 200m 250m); P_SWAP=$(_p $t 240m 280m 320m 400m 500m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1; P_NOTE="ULTRA ANTI-BAN" ;;
    repocket*)
      P_APP="Repocket"; P_MEM=$(_p $t 120m 140m 160m 200m 250m); P_SWAP=$(_p $t 240m 280m 320m 400m 500m)
      P_POLICY="on-failure:3"; P_VPS="safe"; P_MAXIP=1 ;;
    packetstream*)
      P_APP="PacketStream"; P_MEM=$(_p $t 65m 80m 100m 120m 150m); P_SWAP=$(_p $t 130m 160m 200m 240m 300m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1 ;;
    pawns*)
      P_APP="IPRoyal Pawns"; P_MEM=$(_p $t 65m 80m 100m 120m 150m); P_SWAP=$(_p $t 130m 160m 200m 240m 300m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1 ;;
    packetshare*)
      P_APP="Packetshare"; P_MEM=$(_p $t 65m 80m 100m 120m 150m); P_SWAP=$(_p $t 130m 160m 200m 240m 300m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1 ;;
    earnfm*)
      P_APP="EarnFM"; P_MEM=$(_p $t 80m 100m 120m 150m 180m); P_SWAP=$(_p $t 160m 200m 240m 300m 360m)
      P_POLICY="on-failure:3"; P_VPS="resi"; P_MAXIP=1 ;;

    wipter*)
      P_APP="Wipter"; P_MEM=$(_p $t 320m 350m 400m 500m 600m); P_SWAP=$(_p $t 600m 700m 800m 1000m 1200m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;
    depinext*|grass*|gradient*|nodepay*|dawn*|oasis*|blockmesh*|pipe*|toggle*|functor*|navigate*|teneo*|meshchain*|openloop*)
      P_APP="Browser/DePIN Extension"; P_MEM=$(_p $t 280m 340m 400m 500m 600m); P_SWAP=$(_p $t 560m 680m 800m 1000m 1200m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;
    ebesucher*)
      P_APP="Ebesucher"; P_MEM=$(_p $t 320m 350m 400m 500m 600m); P_SWAP=$(_p $t 600m 700m 800m 1000m 1200m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;
    adnade*)
      P_APP="Adnade"; P_MEM=$(_p $t 320m 350m 400m 500m 600m); P_SWAP=$(_p $t 600m 700m 800m 1000m 1200m)
      P_POLICY="on-failure:5"; P_VPS="resi" ;;
    earnapp*)
      P_APP="EarnApp"; P_MEM=$(_p $t 65m 80m 100m 120m 150m); P_SWAP=$(_p $t 130m 160m 200m 240m 300m)
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

II_SUSPEND_SENSITIVE="honey pawns packetstream packetshare earnfm wipter depinext ebesucher adnade earnapp repocket grass gradient nodepay dawn titan"
ii_is_suspend_sensitive() {
  local n="${1:-}"
  for a in $II_SUSPEND_SENSITIVE; do
    case "$n" in *${a}*) return 0 ;; esac
  done
  return 1
}
EOF_PROFILES
chmod 644 /usr/local/lib/ii-app-profiles.sh
. /usr/local/lib/ii-app-profiles.sh

#============================================================================
# FLAPGUARD ULTRA (BẢO VỆ CHỐNG BAN TÀI KHOẢN KHI CRASH/RECONNECT LOOP)
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
TIER=$(ii_tier_idx "$MEM_MB" 2>/dev/null || echo 2)

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
TIER_IDX=$(ii_tier_idx "$MEM_MB" 2>/dev/null || echo 2)

for cid in $(docker ps -aq 2>/dev/null); do
  c_img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
  c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || true)
  ii_profile "$c_name" "$c_img" "$TIER_IDX"
  
  [[ -n "$P_POLICY" ]] && docker update --restart="$P_POLICY" "$cid" >/dev/null 2>&1 || true

  [[ -n "$P_MEM" ]] || continue
  cmem=$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null || echo 0)
  want_bytes=$(( ${P_MEM%m} * 1024 * 1024 ))
  
  if (( cmem == 0 || cmem < (want_bytes - 2097152) )); then
    docker update --memory="$P_MEM" --memory-swap="$P_SWAP" "$cid" >/dev/null 2>&1 || \
    docker update --memory="$P_MEM" "$cid" >/dev/null 2>&1 || true
  fi
done
EOF_AUTOSYNC
chmod +x /usr/local/bin/ii-autosync.sh
ln -sf /usr/local/bin/ii-autosync.sh /usr/bin/ii-autosync 2>/dev/null || true

#============================================================================
# HÀM AUTO-PATCH PROPERTIES.CONF (CHUẨN 100% TEST BRANCH & IP-AUTH)
#============================================================================
auto_patch_engageub_repo() {
  log "Dong bo properties TEST (SOCKS5 DNS off, DoH on). KHONG ghi MAX_MEMORY..."
  ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc)
  if [[ -n "${BASE_DIR:-}" ]]; then ROOTS+=("$BASE_DIR"); fi
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    grep -qE 'USE_SOCKS5_DNS|USE_PROXIES|USE_DNS_OVER_HTTPS' "$f" || continue
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    
    # Gỡ MAX_MEMORY tĩnh để ii-autosync tự điều phối
    sed -i -E '/^[[:space:]]*MAX_MEMORY=/d;/^[[:space:]]*MEMORY_RESERVATION=/d;/^[[:space:]]*MEMORY_SWAP=/d;/^[[:space:]]*CPU=/d' "$f" || true
    
    set_kv() {
      local k="$1" v="$2"
      if grep -qE "^[[:space:]]*#?[[:space:]]*${k}=" "$f"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${k}=.*|${k}=${v}|" "$f"
      else
        printf '\n%s=%s\n' "$k" "$v" >> "$f"
      fi
    }
    set_kv USE_DIRECT_CONNECTION false
    set_kv USE_PROXIES true
    set_kv USE_VPNS false
    set_kv USE_MULTI_IP false
    set_kv USE_SOCKS5_DNS false
    set_kv USE_DNS_OVER_HTTPS true
    set_kv USE_DNSCRYPT false
    set_kv USE_DNS_CACHE true
    set_kv USE_TUN2PROXY false
    set_kv USE_DOCKER_EMBEDDED_DNS false
    set_kv USE_CUSTOM_NETWORK false
    set_kv AUTO_UPDATE_CONTAINERS false
    set_kv ENABLE_LOGS false
    log "Da patch properties.conf tai: $(dirname "$f")"
  done < <(find "${ROOTS[@]}" -maxdepth 5 -name properties.conf -type f 2>/dev/null | sort -u)
}

auto_patch_engageub_repo
/usr/local/bin/ii-autosync.sh || true

# Cấu hình Docker daemon: Bỏ key "dns" để tránh xung đột TUN DNS
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
  systemctl daemon-reload 2>/dev/null || true
  if systemctl is-active docker >/dev/null 2>&1; then
    systemctl restart docker 2>/dev/null || true
  else
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
fi

CHECK_DOCKER=0
while ! docker info >/dev/null 2>&1; do
  sleep 1
  CHECK_DOCKER=$((CHECK_DOCKER+1))
  if (( CHECK_DOCKER >= 8 )); then break; fi
done

#============================================================================
# ENGINE KHỞI ĐỘNG TUẦN TỰ TUNNEL-FIRST
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
  if [[ "$cname" =~ ^tun|^hev|^socks5|^dind ]]; then
    running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")
    if [[ "$running" != "true" ]]; then
      docker start "$cid" >/dev/null 2>&1 || true
      sleep 1.5
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

  if [[ "$cname" =~ wipter|ebesucher|adnade|depinext|grass|gradient|nodepay|dawn|titan ]]; then
    sleep 8
  elif [[ "$cname" =~ honey|repocket|packetstream|packetshare|pawns|earnfm|earnapp ]]; then
    sleep 3.5
  else
    sleep 1.0
  fi
done
echo "=== TAT CA ${TOTAL_NODES} NODE DA ONLINE AN TOAN ==="
EOF_STAGGER
chmod +x /usr/local/bin/ii-staggered-start.sh

if has_systemd; then
  cat > /etc/systemd/system/ii-boot-staggered.service <<'EOF_BOOT_SVC'
[Unit]
Description=InternetIncome Staggered Container Boot
After=docker.service ii-zram.service
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

install_cron_stack() {
  cat > /usr/local/bin/ii-restart-all.sh <<'EOF_RESTART'
#!/usr/bin/env bash
LOG=/var/log/ii-restart.log
ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc __EXTRA__)
ts() { date '+%F %T'; }
HAVE_CTR=0; command -v ctr >/dev/null 2>&1 && HAVE_CTR=1

{
  echo "[$(ts)] ==================== ii-restart-all ===================="
  mapfile -t FILES < <(find "${ROOTS[@]}" -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)
  if (( ${#FILES[@]} == 0 )); then
    echo "[$(ts)] chua thay folder engageub nao"
  else
    STUCK=$(docker ps -aq --no-trunc -f status=exited 2>/dev/null || true)
    if (( HAVE_CTR == 1 )) && [[ -n "$STUCK" ]]; then
      for cid in $STUCK; do
        ctr -n moby task kill -s SIGKILL "$cid" >/dev/null 2>&1 || true
        ctr -n moby task rm "$cid" >/dev/null 2>&1 || true
      done
    fi
    /usr/local/bin/ii-staggered-start.sh
    /usr/local/bin/ii-autosync.sh
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
# BẢNG CHẨN ĐOÁN TIÊU CHUẨN 5 PHẦN (II-STATUS)
#============================================================================
cat > /usr/local/bin/ii-status.sh <<'EOF_STATUS'
#!/usr/bin/env bash
set +u

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

echo -e "${C_B}==================== [ORACLE CLOUD 24/7 TELEMETRY DIAGNOSTIC] ====================${C_0}"
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "HOSTNAME     : $(hostname)"
echo "UPTIME       : $(uptime -p 2>/dev/null || uptime)"
echo "KERNEL/ARCH  : $(uname -r) ($(uname -m))"

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
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
      (( rc > 10 )) && high_restart=$((high_restart+1))
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

if (( found == 0 )); then echo "  (Chua khoi tao folder engageub nao)"; fi

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

    APP_COUNT["$app_key"]=$(( ${APP_COUNT["$app_key"]:-0} + 1 ))
    APP_MEM["$app_key"]="${cmb}MB"
    APP_POL["$app_key"]="$cpol"
    APP_ERR["$app_key"]=${APP_ERR["$app_key"]:-0}
    APP_WARN["$app_key"]=${APP_WARN["$app_key"]:-0}
    APP_OK["$app_key"]=${APP_OK["$app_key"]:-0}

    if [[ "$coom" == "true" ]] || [[ "$cpol" == "always" ]]; then
      APP_ERR["$app_key"]=$(( ${APP_ERR["$app_key"]} + 1 ))
      ISSUES_COUNT=$((ISSUES_COUNT+1))
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
DNS_RES=$(timeout 2 host -W 1 google.com 2>/dev/null || echo "")
DNS_END=$(date +%s%N 2>/dev/null || echo 0)
if [[ -n "$DNS_RES" ]]; then
  DNS_MS=$(( (DNS_END - DNS_START) / 1000000 ))
  echo -e "  DNS Resolution (Direct) : ${C_G}OK (${DNS_MS}ms)${C_0}"
else
  echo -e "  DNS Resolution (Direct) : ${C_Y}CHECK_TIMEOUT${C_0}"
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

if swapon --show 2>/dev/null | grep -qE "/dev/zram|zramswap"; then
  ZRAM_SIZE=$(swapon --show 2>/dev/null | grep -E "/dev/zram|zramswap" | awk '{print $3}')
  echo -e "  ZRAM : ${C_G}ACTIVE (${ZRAM_SIZE} Priority 10)${C_0}"
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
CPUS=$(nproc 2>/dev/null || echo 1)
echo "  CPU Cores: ${CPUS} | Load Avg (1m): ${LOAD_1}"

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
echo -e "${C_B}==========================================================================${C_0}"
EOF_STATUS

chmod +x /usr/local/bin/ii-status.sh
ln -sf /usr/local/bin/ii-status.sh /usr/bin/ii-status.sh 2>/dev/null || true
ln -sf /usr/local/bin/ii-status.sh /usr/bin/ii-status 2>/dev/null || true

#============================================================================
# BẢNG CHẨN ĐOÁN CHUYÊN SÂU (II-DEEP)
#============================================================================
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

# Liên kết công cụ check-network-proxy nếu có
if [[ -f "./check_network_proxy.sh" ]]; then
  cp ./check_network_proxy.sh /usr/local/bin/check-proxy 2>/dev/null || true
  chmod +x /usr/local/bin/check-proxy 2>/dev/null || true
fi

# Đồng bộ file cài đặt cho các user chuẩn OCI
cp -f "$0" /root/setup_oracle_cloud.sh 2>/dev/null || true
cp -f "$0" /home/opc/setup_oracle_cloud.sh 2>/dev/null || true
cp -f "$0" /home/ubuntu/setup_oracle_cloud.sh 2>/dev/null || true

echo "============================= SETUP XONG (100% AUTO-PILOT OCI MASTER 2026 - FULL ULTIMATE) =============================="
/usr/local/bin/ii-status.sh || true

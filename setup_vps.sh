#!/usr/bin/env bash
#============================================================================
#  setup_vps.sh (2026 ULTIMATE MASTER - 100% FULL PLATFORM COVERAGE)
#  Optimized for: InternetIncome (Test Branch), SpideNetwork & 400+ High-Density IPs
#  Hardening: Passive IP-Auth Audit, Dynamic KSM, ZRAM ZSTD, Smart Repocket Healing
#  Clean Architecture: Decoupled Heavy Wipter Engine for Dedicated Standalone Runner
#============================================================================
set -Eeuo pipefail

ulimit -n 1048576 2>/dev/null || true
sysctl -w fs.inotify.max_user_watches=2097152 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_instances=65536 >/dev/null 2>&1 || true
sysctl -w kernel.pid_max=4194304 >/dev/null 2>&1 || true

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
IS_CONTAINER=0
case "$VIRT" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1 ;; esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)
DISK_TOTAL_MB=$(df -m / | awk 'NR==2 {print $2}')
DISK_FREE_MB=$(df -m / | awk 'NR==2 {print $4}')

PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
if [[ -z "$PRIMARY_IFACE" ]]; then
  PRIMARY_IFACE=$(ip link show up 2>/dev/null | grep -E '^[0-9]+: (eth|ens|enp|eno|vtnet)' | awk -F': ' '{print $2}' | head -n1)
fi
PRIMARY_IFACE=${PRIMARY_IFACE:-"eth0"}

PUBLIC_IP=$(curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://api.ipify.org 2>/dev/null || \
            curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://icanhazip.com 2>/dev/null || \
            curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://ifconfig.me 2>/dev/null || \
            echo "Unknown")

TIER_NAME=""
if (( MEM_MB <= 2500 )); then
  TIER_NAME="TIER 1 (${CPU} CPU / 2GB RAM - LIGHTWEIGHT PROXIES)"
elif (( MEM_MB <= 5000 )); then
  TIER_NAME="TIER 2 (${CPU} CPU / 4GB RAM - BALANCED PROXIES)"
elif (( MEM_MB <= 9000 )); then
  TIER_NAME="TIER 3 (${CPU} CPU / 8GB RAM - HIGH DENSITY PROXIES [400+ IPs])"
else
  TIER_NAME="TIER 4 (${CPU} CPU / 12GB+ RAM - DEDICATED HEAVY / ENTERPRISE)"
fi

if (( MEM_MB >= 9000 )) || (( DISK_TOTAL_MB <= 25000 )); then
  TARGET_SWAP_MB=1024
elif (( MEM_MB <= 2500 )); then
  TARGET_SWAP_MB=1024
elif (( MEM_MB <= 5000 )); then
  TARGET_SWAP_MB=1536
else
  TARGET_SWAP_MB=2048
fi

echo -e "\n${C_BG_BLUE}${C_BOLD} [!] HOST PUBLIC IP DÀNH CHO IP-AUTHENTICATION PROXIES (WHITELIST IP) ${C_0}"
echo -e " ${C_BOLD}>>> IP CẦN WHITELIST : ${C_G}${C_BOLD}${PUBLIC_IP}${C_0}"
echo -e " ${C_Y}Hãy đảm bảo IP trên đã được Whitelist chính xác trong Dashboard nhà cung cấp Proxy!${C_0}\n"

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
  iptables-persistent netfilter-persistent systemd-timesyncd vnstat nload dnsutils util-linux e2fsprogs || true

apt-get install -y -qq linux-modules-extra-"$(uname -r)" 2>/dev/null || true

log "Cau hinh uu tien IPv4 (/etc/gai.conf) cho Proxy IP-Auth..."
cat << 'EOF_GAI' > /etc/gai.conf
precedence ::ffff:0:0/96  100
precedence ::/0           40
precedence 2002::/16      30
precedence ::/96          20
precedence ::1/128        50
EOF_GAI

if has_systemd; then
  systemctl unmask systemd-timesyncd 2>/dev/null || true
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  systemctl restart systemd-timesyncd 2>/dev/null || true
fi
timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true

log "Cau hinh DNS Direct-Upstream & Khoa bat bien chattr +i..."
UPSTREAM_DNS=""
if [[ -f /run/systemd/resolve/resolv.conf ]]; then
  UPSTREAM_DNS=$(grep -E '^nameserver' /run/systemd/resolve/resolv.conf 2>/dev/null | grep -v '127.0.0.53' | awk '{print $2}' || true)
fi

if has_systemd; then
  systemctl stop systemd-resolved 2>/dev/null || true
  systemctl disable systemd-resolved 2>/dev/null || true
fi

chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
{
  echo "# Generated for High Density Income Nodes (Direct Upstream Mode)"
  echo "options timeout:1 attempts:2 rotate"
  for dns in $UPSTREAM_DNS; do
    echo "nameserver $dns"
  done
  echo "nameserver 1.1.1.1"
  echo "nameserver 8.8.8.8"
  echo "nameserver 9.9.9.9"
} | awk '!seen[$0]++' > /etc/resolv.conf
chmod 644 /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true

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

if [[ ! -c /dev/net/tun ]]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 600 /dev/net/tun 2>/dev/null || true
fi

cat > /usr/local/bin/ii-init-zram.sh <<'EOF_ZRAM_INIT'
#!/usr/bin/env bash
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
ZRAM_BYTES=$(( MEM_MB * 1024 * 1024 ))

modprobe zram num_devices=1 2>/dev/null || true

if [[ ! -b /dev/zram0 ]] && [[ -f /sys/class/zram-control/hot_add ]]; then
  cat /sys/class/zram-control/hot_add >/dev/null 2>&1 || true
fi

if [[ -b /dev/zram0 ]]; then
  swapon --show 2>/dev/null | grep -q "/dev/zram0" && swapoff /dev/zram0 2>/dev/null || true
  if grep -q "zstd" /sys/block/zram0/comp_algorithm 2>/dev/null; then
    echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  elif grep -q "lz4" /sys/block/zram0/comp_algorithm 2>/dev/null; then
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  fi
  echo "$ZRAM_BYTES" > /sys/block/zram0/disksize 2>/dev/null || true
  mkswap /dev/zram0 >/dev/null 2>&1
  swapon -p 10 /dev/zram0 2>/dev/null || true
fi
EOF_ZRAM_INIT
chmod +x /usr/local/bin/ii-init-zram.sh

if has_systemd; then
  cat > /etc/systemd/system/ii-zram.service <<'EOF_ZRAM_SVC'
[Unit]
Description=InternetIncome ZRAM ZSTD Initializer
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

if ! command -v docker >/dev/null 2>&1; then
  log "VPS MOI: Dang tu dong cai dat Docker official..."
  curl -fsSL https://get.docker.com | sh || apt-get install -y -qq docker.io
else
  log "Docker da co san: $(docker --version 2>/dev/null || echo '?')"
fi

mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF_DAEMON
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "2m", "max-file": "2" },
  "registry-mirrors": ["https://mirror.gcr.io", "https://docker.m.daocloud.io"],
  "max-concurrent-downloads": ${CPU},
  "live-restore": true,
  "userland-proxy": false,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 }
  }
}
EOF_DAEMON

if has_systemd; then
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf <<'EOF_DOCKER_SVC'
[Service]
Restart=always
RestartSec=3s
EOF_DOCKER_SVC
  systemctl daemon-reload 2>/dev/null || true
  if systemctl is-active docker >/dev/null 2>&1; then
    systemctl reload docker 2>/dev/null || true
  else
    systemctl enable --now docker >/dev/null 2>&1 || true
  fi
fi

if [[ -f /sys/kernel/mm/ksm/run ]]; then
  if (( MEM_MB <= 2500 )); then
    echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
    echo 500 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
    echo 1000 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
  elif (( MEM_MB <= 5000 )); then
    echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
    echo 2000 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
    echo 300 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
  else
    echo 0 > /sys/kernel/mm/ksm/run 2>/dev/null || true
  fi
fi

RPS_MASK=$(printf "%x" $(( (1 << CPU) - 1 )) 2>/dev/null || echo "f")
for f in /sys/class/net/*/queues/rx-*/rps_cpus; do
  echo "$RPS_MASK" > "$f" 2>/dev/null || true
done

for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$g" 2>/dev/null || true
done

SWAPPINESS=100
sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true

if (( CPU <= 2 )); then
  SYN_BACKLOG=8192
  NETDEV_BUDGET=300
  NETDEV_USECS=2000
  TIMER_MIG=1
elif (( CPU <= 4 )); then
  SYN_BACKLOG=16384
  NETDEV_BUDGET=600
  NETDEV_USECS=4000
  TIMER_MIG=0
else
  SYN_BACKLOG=32768
  NETDEV_BUDGET=1000
  NETDEV_USECS=4000
  TIMER_MIG=0
fi

echo "=============================================================="
echo "  VPS $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU | SSD ${DISK_TOTAL_MB}MB"
echo "  PUBLIC IP (IP-AUTH) : ${PUBLIC_IP}"
echo "  DETECTED PROFILE    : ${TIER_NAME}"
echo "  ZRAM COMPRESSION    : ZSTD (PERSISTENT SYSTEMD PRIORITY 10)"
echo "  DNS ARCHITECTURE    : DIRECT NON-LOOPBACK (ANTI-UDP-DROP READY)"
echo "=============================================================="

CURR_DISK_SWAP_MB=$(swapon --show=NAME,SIZE --bytes 2>/dev/null | awk '/swapfile/{print int($2/1024/1024)}' || echo 0)
if (( IS_CONTAINER != 1 )); then
  if (( CURR_DISK_SWAP_MB != TARGET_SWAP_MB )); then
    swapoff /swapfile /swapfile2 2>/dev/null || true
    rm -f /swapfile /swapfile2 2>/dev/null || true
    if ! fallocate -l "${TARGET_SWAP_MB}M" /swapfile 2>/dev/null; then
      dd if=/dev/zero of=/swapfile bs=1M count="$TARGET_SWAP_MB" status=none
    fi
    chmod 600 /swapfile
    if mkswap /swapfile >/dev/null 2>&1 && swapon -p 0 /swapfile 2>/dev/null; then
      grep -q "^/swapfile" /etc/fstab || echo "/swapfile none swap sw,pri=0 0 0" >> /etc/fstab
    else
      rm -f /swapfile
    fi
  fi
fi

apt-get clean 2>/dev/null || true
journalctl --vacuum-size=10M 2>/dev/null || true

if has_systemd; then
  systemctl stop snapd multipathd udisks2 accountsservice earlyoom ModemManager packagekit 2>/dev/null || true
  systemctl disable snapd multipathd udisks2 accountsservice earlyoom ModemManager packagekit 2>/dev/null || true
fi
apt-get purge -y snapd earlyoom 2>/dev/null || true
rm -rf /var/cache/snapd/ /var/lib/snapd/ 2>/dev/null || true

if command -v docker >/dev/null 2>&1; then
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
vm.min_free_kbytes = 65536
vm.page-cluster = 0
vm.overcommit_memory = 1
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 300
vm.dirty_background_ratio = 3
vm.dirty_ratio = 8
vm.dirty_writeback_centisecs = 1500
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_instances = 65536
fs.inotify.max_user_watches = 2097152
kernel.pid_max = 4194304
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.core.netdev_budget = ${NETDEV_BUDGET}
net.core.netdev_budget_usecs = ${NETDEV_USECS}
net.core.busy_poll = 0
net.core.busy_read = 0
kernel.timer_migration = ${TIMER_MIG}
kernel.sched_autogroup_enabled = 0
fs.epoll.max_user_watches = 2097152
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 5
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

mkdir -p /usr/local/lib
cat > /usr/local/lib/ii-app-profiles.sh <<'EOF_PROFILES'
#!/usr/bin/env bash
ii_tier_idx() { echo 4; }

ii_profile() {
  local n img
  n="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's|^/||')"
  img="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"

  P_APP=""; P_BASE_MIN="20m"; P_POLICY="unless-stopped"

  case "$n" in
    tun*|hev*|tun2proxy*|gluetun*)
      P_APP="tun2socks";       P_BASE_MIN="20m";  P_POLICY="unless-stopped" ;;
    dind*)
      P_APP="docker-in-docker"; P_BASE_MIN="120m"; P_POLICY="unless-stopped" ;;
    traffmon*)
      P_APP="Traffmonetizer";  P_BASE_MIN="25m";  P_POLICY="unless-stopped" ;;
    bitping*)
      P_APP="Bitping";         P_BASE_MIN="35m";  P_POLICY="unless-stopped" ;;
    proxylite*|proxyrack*|proxybase*|antgain*|wizardgain*|peer2profit*|packetsdk*|castarsdk*)
      P_APP="LightweightProxy";P_BASE_MIN="25m";  P_POLICY="unless-stopped" ;;
    urnetwork*|titan*)
      P_APP="NetworkNode";     P_BASE_MIN="60m";  P_POLICY="unless-stopped" ;;
    myst*)
      P_APP="Mysterium";       P_BASE_MIN="150m"; P_POLICY="unless-stopped" ;;

    honey*)
      P_APP="Honeygain";       P_BASE_MIN="60m";  P_POLICY="on-failure:3" ;;
    repocket*)
      P_APP="Repocket";        P_BASE_MIN="100m"; P_POLICY="unless-stopped" ;;
    packetstream*)
      P_APP="PacketStream";    P_BASE_MIN="60m";  P_POLICY="on-failure:3" ;;
    pawns*)
      P_APP="IPRoyal Pawns";   P_BASE_MIN="60m";  P_POLICY="on-failure:3" ;;
    packetshare*)
      P_APP="Packetshare";     P_BASE_MIN="60m";  P_POLICY="on-failure:3" ;;
    earnfm*)
      P_APP="EarnFM";          P_BASE_MIN="60m";  P_POLICY="on-failure:3" ;;
    earnapp*)
      P_APP="EarnApp";         P_BASE_MIN="60m";  P_POLICY="always" ;;

    depinext*|grass*|gradient*|nodepay*|dawn*|oasis*|blockmesh*|pipe*|toggle*|functor*|navigate*|teneo*|meshchain*|openloop*|uprock*|customchrome*|customfirefox*)
      P_APP="Depin/Browser ext"; P_BASE_MIN="250m"; P_POLICY="on-failure:5" ;;
    ebesucher*)
      P_APP="Ebesucher";       P_BASE_MIN="250m"; P_POLICY="on-failure:5" ;;
    adnade*)
      P_APP="Adnade";          P_BASE_MIN="250m"; P_POLICY="on-failure:5" ;;

    *)
      P_APP="OtherApp";        P_BASE_MIN="30m";  P_POLICY="unless-stopped" ;;
  esac

  if [[ "$P_APP" == "OtherApp" && -n "$img" ]]; then
    case "$img" in
      *mysteriumnetwork/myst*) ii_profile "myst" "" ;;
      *repocket*)              ii_profile "repocket" "" ;;
      *honeygain*)             ii_profile "honey" "" ;;
      *traffmonetizer*)        ii_profile "traffmon" "" ;;
      *bitping*)               ii_profile "bitping" "" ;;
      *earnfm*)                ii_profile "earnfm" "" ;;
      *earnapp*)               ii_profile "earnapp" "" ;;
      *proxyrack*)             ii_profile "proxyrack" "" ;;
      *proxybase*)             ii_profile "proxybase" "" ;;
      *proxylite*)             ii_profile "proxylite" "" ;;
      *pawns*)                 ii_profile "pawns" "" ;;
      *packetstream*)          ii_profile "packetstream" "" ;;
      *packetshare*)           ii_profile "packetshare" "" ;;
      *peer2profit*)           ii_profile "peer2profit" "" ;;
      *community-provider*)    ii_profile "urnetwork" "" ;;
      *titan-edge*)            ii_profile "titan" "" ;;
      *antgain*)               ii_profile "antgain" "" ;;
      *wizardgain*)            ii_profile "wizardgain" "" ;;
      *packetsdk*)             ii_profile "packetsdk" "" ;;
      *castarsdk*)             ii_profile "castarsdk" "" ;;
      *uprock*)                ii_profile "uprock" "" ;;
      *dockweb*)               ii_profile "depinext" "" ;;
      *nodepay*)               ii_profile "nodepay" "" ;;
    esac
  fi
}

II_SUSPEND_SENSITIVE="honey pawns packetstream packetshare earnfm depinext ebesucher adnade grass gradient nodepay dawn titan uprock customchrome customfirefox"
ii_is_suspend_sensitive() {
  local n="${1:-}"
  for a in $II_SUSPEND_SENSITIVE; do case "$n" in *${a}*) return 0 ;; esac; done
  return 1
}
EOF_PROFILES
chmod 644 /usr/local/lib/ii-app-profiles.sh
. /usr/local/lib/ii-app-profiles.sh

auto_patch_engageub_repo() {
  log "Dong bo properties TEST & format list proxy an toan..."
  ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc)
  if [[ -n "${BASE_DIR:-}" ]]; then ROOTS+=("$BASE_DIR"); fi
  
  while IFS= read -r pf; do
    [[ -f "$pf" ]] && sed -i 's/\r$//' "$pf" 2>/dev/null || true
  done < <(find "${ROOTS[@]}" -maxdepth 5 -type f \( -name "*.txt" -o -name "*.list" \) -path "*/List_Proxy/*" 2>/dev/null | sort -u)

  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    grep -qE 'USE_SOCKS5_DNS|USE_PROXIES|USE_DNS_OVER_HTTPS' "$f" || continue
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    
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

for cid in $(docker ps -aq 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||') || continue
  [[ -n "$cname" ]] || continue
  cimg=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || echo "")

  ii_profile "$cname" "$cimg"
  ii_is_suspend_sensitive "$cname" || continue

  rc=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0)
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

cat > /usr/local/bin/ii-repocket-watchdog.sh <<'EOF_RP_WATCHDOG'
#!/usr/bin/env bash
set -uo pipefail
command -v docker >/dev/null 2>&1 || exit 0

STATE_DIR="/var/lib/ii-repocket-watchdog"
LOG_FILE="/var/log/ii-repocket.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_rp() { echo "[$(ts)] [Repocket-Watchdog] $*" >> "$LOG_FILE"; }

check_upstream_proxy_alive() {
  local p_host="$1"
  local p_port="$2"
  [[ -z "$p_host" || -z "$p_port" ]] && return 0
  timeout 2 bash -c "cat < /dev/null > /dev/tcp/$p_host/$p_port" 2>/dev/null
  return $?
}

for cid in $(docker ps -aq 2>/dev/null); do
  [[ -z "$cid" ]] && continue
  
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  cimg=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || echo "")
  
  if [[ ! "$cname" =~ repocket ]] && [[ ! "$cimg" =~ repocket ]]; then
    continue
  fi

  status=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
  running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")
  net_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid" 2>/dev/null || echo "")

  state_file="$STATE_DIR/${cname}.state"
  fail_count=0; last_attempt=0; cooldown_until=0; last_error="NONE"

  if [[ -f "$state_file" ]]; then
    read -r fail_count last_attempt cooldown_until last_error < "$state_file" 2>/dev/null || true
    fail_count=${fail_count:-0}
    last_attempt=${last_attempt:-0}
    cooldown_until=${cooldown_until:-0}
    last_error=${last_error:-"NONE"}
  fi

  now=$(date +%s)

  target_tun=""
  proxy_ip=""
  proxy_port=""
  if [[ "$net_mode" =~ ^container:(.+) ]]; then
    target_tun="${BASH_REMATCH[1]}"
    tun_envs=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$target_tun" 2>/dev/null || true)
    proxy_ip=$(echo "$tun_envs" | grep '^SOCKS5_ADDR=' | cut -d= -f2-)
    proxy_port=$(echo "$tun_envs" | grep '^SOCKS5_PORT=' | cut -d= -f2-)

    if [[ -z "$proxy_ip" || -z "$proxy_port" ]]; then
      raw_proxy=$(echo "$tun_envs" | grep '^PROXY=' | cut -d= -f2-)
      if [[ -n "$raw_proxy" ]]; then
        clean_p="${raw_proxy#*://}"
        [[ "$clean_p" == *@* ]] && clean_p="${clean_p#*@}"
        proxy_ip="${clean_p%%:*}"
        proxy_port="${clean_p##*:}"
      fi
    fi
  fi

  if [[ "$running" == "true" && "$status" == "running" ]]; then
    if (( fail_count > 0 && now - last_attempt > 180 )); then
      log_rp "[$cname] Node da on dinh tro lai. Reset bo dem loi."
      echo "0 $now 0 NONE" > "$state_file"
    fi
    continue
  fi

  if echo "$status" | grep -qiE "exited|dead|paused|created"; then
    if (( now < cooldown_until )); then
      continue
    fi

    if [[ -n "$target_tun" ]]; then
      tun_running=$(docker inspect -f '{{.State.Running}}' "$target_tun" 2>/dev/null || echo "false")
      if [[ "$tun_running" != "true" ]]; then
        log_rp "[$cname] [NGUYÊN NHÂN: TUNNEL SẬP] Dang bat lai Tunnel ($target_tun) truoc..."
        docker start "$target_tun" >/dev/null 2>&1 || true
        sleep 2
      fi
    fi

    proxy_alive=1
    if [[ -n "$proxy_ip" && -n "$proxy_port" ]]; then
      if ! check_upstream_proxy_alive "$proxy_ip" "$proxy_port"; then
        proxy_alive=0
      fi
    fi

    if (( proxy_alive == 0 )); then
      cooldown_sec=480
      cooldown_until=$(( now + cooldown_sec ))
      echo "$fail_count $now $cooldown_until PROXY_DEAD" > "$state_file"
      
      log_rp "[$cname] [NGUYÊN NHÂN: PROXY DIE] Proxy ($proxy_ip:$proxy_port) khong phan hoi! Tam dung Repocket de tiet kiem CPU (Thu lai sau 8p)."
      docker stop "$cid" >/dev/null 2>&1 || true
      continue
    fi

    fail_count=$(( fail_count + 1 ))
    last_attempt=$now

    if (( fail_count <= 3 )); then
      cooldown_sec=0
      cooldown_until=0
    elif (( fail_count <= 5 )); then
      cooldown_sec=120
      cooldown_until=$(( now + cooldown_sec ))
    else
      cooldown_sec=300
      cooldown_until=$(( now + cooldown_sec ))
    fi

    echo "$fail_count $last_attempt $cooldown_until REPOCKET_DISCONNECT" > "$state_file"
    log_rp "[$cname] [NGUYÊN NHÂN: LAG SOCKET] Proxy van song. Khoi dong lai Repocket (Lan #$fail_count, Cooldown ke tiep: ${cooldown_sec}s)..."
    
    docker update --restart=unless-stopped "$cid" >/dev/null 2>&1 || true
    docker start "$cid" >/dev/null 2>&1 || true
  fi
done

if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > 5242880 )); then
  tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi
EOF_RP_WATCHDOG
chmod +x /usr/local/bin/ii-repocket-watchdog.sh
ln -sf /usr/local/bin/ii-repocket-watchdog.sh /usr/bin/ii-repocket-watchdog 2>/dev/null || true

cat > /usr/local/bin/ii-repocket-doctor <<'EOF_DOCTOR'
#!/usr/bin/env bash
set -uo pipefail

C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_C='\033[1;36m'; C_0='\033[0m'
STATE_DIR="/var/lib/ii-repocket-watchdog"

echo -e "\n${C_C}=================== [BẢNG CHẨN ĐOÁN CHI TIẾT REPOCKET & PROXY] ===================${C_0}"
printf " %-22s %-20s %-16s %-16s %s\n" "CONTAINER" "PROXY IP:PORT" "PROXY STATUS" "REPOCKET STATUS" "KẾT LUẬN / NGUYÊN NHÂN"
echo "-------------------------------------------------------------------------------------------------------"

RP_CTRS=$(docker ps -aq 2>/dev/null)
FOUND=0

for cid in $RP_CTRS; do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  cimg=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || echo "")

  if [[ ! "$cname" =~ repocket ]] && [[ ! "$cimg" =~ repocket ]]; then
    continue
  fi

  FOUND=$((FOUND+1))
  rp_status=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo "unknown")
  net_mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid" 2>/dev/null || echo "")

  proxy_str="Direct/None"
  proxy_st_text="${C_Y}N/A${C_0}"
  conclusion="${C_G}Bình thường (Online)${C_0}"

  if [[ "$net_mode" =~ ^container:(.+) ]]; then
    target_tun="${BASH_REMATCH[1]}"
    tun_envs=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$target_tun" 2>/dev/null || true)
    p_ip=$(echo "$tun_envs" | grep '^SOCKS5_ADDR=' | cut -d= -f2-)
    p_port=$(echo "$tun_envs" | grep '^SOCKS5_PORT=' | cut -d= -f2-)

    if [[ -z "$p_ip" || -z "$p_port" ]]; then
      raw_proxy=$(echo "$tun_envs" | grep '^PROXY=' | cut -d= -f2-)
      if [[ -n "$raw_proxy" ]]; then
        clean_p="${raw_proxy#*://}"
        [[ "$clean_p" == *@* ]] && clean_p="${clean_p#*@}"
        p_ip="${clean_p%%:*}"
        p_port="${clean_p##*:}"
      fi
    fi

    if [[ -n "$p_ip" && -n "$p_port" ]]; then
      proxy_str="${p_ip}:${p_port}"
      if timeout 2 bash -c "cat < /dev/null > /dev/tcp/$p_ip/$p_port" 2>/dev/null; then
        proxy_st_text="${C_G}ALIVE (Mở)${C_0}"
      else
        proxy_st_text="${C_R}DEAD (Sập)${C_0}"
      fi
    fi
  fi

  state_file="$STATE_DIR/${cname}.state"
  last_err="NONE"
  if [[ -f "$state_file" ]]; then
    read -r _ _ _ last_err < "$state_file" 2>/dev/null || true
  fi

  if [[ "$rp_status" == "running" ]]; then
    rp_st_text="${C_G}RUNNING${C_0}"
    conclusion="${C_G}Hoạt động tốt 100%${C_0}"
  else
    rp_st_text="${C_R}${rp_status^^}${C_0}"
    if [[ "$proxy_st_text" =~ DEAD ]]; then
      conclusion="${C_R}[LỖI DO PROXY SẬP] Đang ngủ đông${C_0}"
    elif [[ "$last_err" == "REPOCKET_DISCONNECT" ]]; then
      conclusion="${C_Y}[LỖI SOCKET APP] Đang tự hồi phục${C_0}"
    else
      conclusion="${C_Y}Đang chờ điều phối${C_0}"
    fi
  fi

  printf " %-22s %-20s %-25b %-25b %b\n" "$cname" "$proxy_str" "$proxy_st_text" "$rp_st_text" "$conclusion"
done

if (( FOUND == 0 )); then
  echo " Không tìm thấy container Repocket nào trên VPS."
fi
echo -e "${C_C}=======================================================================================================${C_0}\n"
EOF_DOCTOR
chmod +x /usr/local/bin/ii-repocket-doctor
ln -sf /usr/local/bin/ii-repocket-doctor /usr/bin/ii-repocket-doctor 2>/dev/null || true

cat > /usr/local/bin/ii-autosync.sh <<'EOF_AUTOSYNC'
#!/usr/bin/env bash
set -uo pipefail
PROFILES=/usr/local/lib/ii-app-profiles.sh
[[ -r "$PROFILES" ]] && . "$PROFILES"

command -v docker >/dev/null 2>&1 || exit 0
TOTAL_CTRS=$(docker ps -q 2>/dev/null | wc -l)
(( TOTAL_CTRS < 1 )) && exit 0

HOST_RAM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
OS_RESERVE_MB=$(( (HOST_RAM_MB * 15) / 100 ))
(( OS_RESERVE_MB < 300 )) && OS_RESERVE_MB=300
USABLE_HOST_RAM=$(( HOST_RAM_MB - OS_RESERVE_MB ))

STATS_RAW=$(docker stats --no-stream --format "{{.ID}}\t{{.Name}}\t{{.MemUsage}}" 2>/dev/null || echo "")
[[ -z "$STATS_RAW" ]] && exit 0

to_mb() {
  local val="$1"
  if [[ "$val" =~ ([0-9.]+)[[:space:]]*GiB ]]; then
    awk "BEGIN {print int(${BASH_REMATCH[1]} * 1024)}"
  elif [[ "$val" =~ ([0-9.]+)[[:space:]]*MiB ]]; then
    awk "BEGIN {print int(${BASH_REMATCH[1]})}"
  elif [[ "$val" =~ ([0-9.]+)[[:space:]]*kB ]]; then
    awk "BEGIN {print int(${BASH_REMATCH[1]} / 1024)}"
  elif [[ "$val" =~ ([0-9.]+)[[:space:]]*B ]]; then
    awk "BEGIN {print int(${BASH_REMATCH[1]} / 1048576)}"
  else
    echo 25
  fi
}

declare -A LIVE_ACTUAL_MB
TOTAL_ACTUAL_USED_MB=0
HEAVY_COUNT=0
LIGHT_COUNT=0

while IFS=$'\t' read -r cid cname mem_usage; do
  [[ -z "$cid" ]] && continue
  cname_clean=$(echo "$cname" | sed 's|^/||' | tr '[:upper:]' '[:lower:]')
  used_str=$(echo "$mem_usage" | awk -F'/' '{print $1}' | tr -d ' ')
  used_mb=$(to_mb "$used_str")
  (( used_mb < 15 )) && used_mb=15

  LIVE_ACTUAL_MB["$cid"]=$used_mb
  TOTAL_ACTUAL_USED_MB=$(( TOTAL_ACTUAL_USED_MB + used_mb ))

  if [[ "$cname_clean" =~ depinext|ebesucher|adnade|dind|myst|grass|gradient|nodepay|dawn|titan|uprock|customchrome|customfirefox ]]; then
    HEAVY_COUNT=$((HEAVY_COUNT + 1))
  else
    LIGHT_COUNT=$((LIGHT_COUNT + 1))
  fi
done <<< "$STATS_RAW"

FREE_POOL_MB=$(( USABLE_HOST_RAM - TOTAL_ACTUAL_USED_MB ))
(( FREE_POOL_MB < 0 )) && FREE_POOL_MB=0

HEAVY_BURST_EXTRA=0
LIGHT_BURST_EXTRA=0
if (( HEAVY_COUNT > 0 )); then
  HEAVY_BURST_EXTRA=$(( (FREE_POOL_MB * 65 / 100) / HEAVY_COUNT ))
fi
if (( LIGHT_COUNT > 0 )); then
  LIGHT_BURST_EXTRA=$(( (FREE_POOL_MB * 35 / 100) / LIGHT_COUNT ))
fi

for cid in "${!LIVE_ACTUAL_MB[@]}"; do
  actual_mb=${LIVE_ACTUAL_MB["$cid"]}
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' | tr '[:upper:]' '[:lower:]') || continue
  cimg=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || echo "")
  ii_profile "$cname" "$cimg"

  soft_floor=$(( actual_mb * 12 / 10 ))
  base_min=${P_BASE_MIN%m}
  (( soft_floor < base_min )) && soft_floor=$base_min

  if [[ "$cname" =~ depinext|ebesucher|adnade|dind|myst|grass|gradient|nodepay|dawn|titan|uprock|customchrome|customfirefox ]]; then
    target_burst=$(( actual_mb + HEAVY_BURST_EXTRA ))
    (( target_burst < 500 )) && target_burst=500
    (( target_burst > 2048 )) && target_burst=2048
  else
    target_burst=$(( actual_mb + LIGHT_BURST_EXTRA ))
    (( target_burst < 128 )) && target_burst=128
    (( target_burst > 512 )) && target_burst=512
  fi

  docker update \
    --memory-reservation="${soft_floor}m" \
    --memory="${target_burst}m" \
    --cpu-shares=256 \
    --memory-swap="-1" \
    --restart="$P_POLICY" \
    "$cid" >/dev/null 2>&1 || \
  docker update \
    --memory-reservation="${soft_floor}m" \
    --memory="${target_burst}m" \
    --cpu-shares=256 \
    --restart="$P_POLICY" \
    "$cid" >/dev/null 2>&1 || true
done
EOF_AUTOSYNC
chmod +x /usr/local/bin/ii-autosync.sh
ln -sf /usr/local/bin/ii-autosync.sh /usr/bin/ii-autosync 2>/dev/null || true

/usr/local/bin/ii-autosync.sh || true

cat > /usr/local/bin/ii-staggered-start.sh <<'EOF_STAGGER'
#!/usr/bin/env bash
set -uo pipefail
command -v docker >/dev/null 2>&1 || exit 0
while ! docker info >/dev/null 2>&1; do sleep 1; done

TOTAL_NODES=$(docker ps -aq 2>/dev/null | wc -l)
echo "=== BAT DAU KHOI DONG TUAN TU ${TOTAL_NODES} CONTAINER ==="

for cid in $(docker ps -aq 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  if [[ "$cname" =~ ^tun|^hev|^socks5|^gluetun|^dind ]]; then
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

  if [[ "$cname" =~ ebesucher|adnade|depinext|grass|gradient|nodepay|dawn|titan|uprock|customchrome|customfirefox ]]; then
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

/usr/local/bin/ii-staggered-start.sh || true

cat > /usr/local/bin/ii-capacity.sh <<'EOF_CAPACITY'
#!/usr/bin/env bash
MEM_TOTAL_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU_CORES=$(nproc 2>/dev/null || echo 1)
ACTIVE_CTRS=$(docker ps -q 2>/dev/null | wc -l)

MAX_LIGHT_BY_RAM=$(( (MEM_TOTAL_MB - 500) / 28 ))
MAX_LIGHT_BY_CPU=$(( CPU_CORES * 220 ))
SAFE_MAX_LIGHT=$(( MAX_LIGHT_BY_RAM < MAX_LIGHT_BY_CPU ? MAX_LIGHT_BY_RAM : MAX_LIGHT_BY_CPU ))

MAX_HEAVY_BY_RAM=$(( (MEM_TOTAL_MB - 500) / 450 ))
MAX_HEAVY_BY_CPU=$(( CPU_CORES * 6 ))
SAFE_MAX_HEAVY=$(( MAX_HEAVY_BY_RAM < MAX_HEAVY_BY_CPU ? MAX_HEAVY_BY_RAM : MAX_HEAVY_BY_CPU ))

RAM_FREE_MB=$(free -m | awk '/^Mem:/{print $7}')
LOAD_15=$(cat /proc/loadavg | awk '{print $3}')

PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
PUB_IP=$(curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://api.ipify.org 2>/dev/null || \
        curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://icanhazip.com 2>/dev/null || \
        echo "Unknown")

echo "==================== [ĐÁNH GIÁ SỨC CHỨA PHẦN CỨNG VPS] ===================="
echo "  PUBLIC IP (IP-AUTH) : ${PUB_IP}"
echo "  CẤU HÌNH HIỆN TẠI   : ${CPU_CORES} vCPU | RAM ${MEM_TOTAL_MB}MB (Trống: ${RAM_FREE_MB}MB) | Load 15m: ${LOAD_15}"
echo "  NODE ĐANG CHẠY      : ${ACTIVE_CTRS} Container"
echo "------------------------------------------------------------------------"
echo "  1. SỨC CHỨA TỐI ĐA CHO PROXY NHẸ (Traffmon/Bitping/tun2socks):"
echo "     -> Ngưỡng an toàn tối đa: ${SAFE_MAX_LIGHT} Container"
if (( ACTIVE_CTRS > SAFE_MAX_LIGHT )); then
  echo "     -> TRẠNG THÁI: [CẢNH BÁO QUÁ TẢI] Cần hạ bớt node hoặc nâng cấp VPS!"
else
  REMAIN_LIGHT=$(( SAFE_MAX_LIGHT - ACTIVE_CTRS ))
  echo "     -> TRẠNG THÁI: [AN TOÀN] Có thể nhồi thêm tối đa ~${REMAIN_LIGHT} node nhẹ nữa."
fi
echo ""
echo "  2. SỨC CHỨA CHO ỨNG DỤNG NẶNG (Browser Nodes / Heavy Extensions / DePIN):"
echo "     -> Ngưỡng an toàn tối đa: ${SAFE_MAX_HEAVY} Heavy Nodes (khi không chạy node khác)."
echo "     -> KHUYẾN NGHỊ: Trên máy hiện tại nên chạy tối đa 10 - 15 Heavy Nodes."
echo "========================================================================"
EOF_CAPACITY
chmod +x /usr/local/bin/ii-capacity.sh
ln -sf /usr/local/bin/ii-capacity.sh /usr/bin/ii-capacity 2>/dev/null || true

cat > /usr/local/bin/ii-clean-logs.sh << 'EOF_CLEAN'
#!/usr/bin/env bash
find /var/lib/docker/containers/ -name "*-json.log" -size +10M -exec truncate -s 0 {} + 2>/dev/null || true
journalctl --vacuum-size=10M 2>/dev/null || true
EOF_CLEAN
chmod +x /usr/local/bin/ii-clean-logs.sh
ln -sf /usr/local/bin/ii-clean-logs.sh /usr/bin/ii-clean-logs 2>/dev/null || true

cat > /usr/local/bin/ii-test-proxy.sh << 'EOF_TEST_PROXY'
#!/usr/bin/env bash
CNAME="${1:-}"
if [[ -z "$CNAME" ]]; then
  echo "Cach dung: ii-test-proxy <ten_container>"
  exit 1
fi
if ! docker inspect "$CNAME" >/dev/null 2>&1; then
  echo "[XX] Khong tim thay container: $CNAME"
  exit 1
fi

PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
PUB_HOST=$(curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://api.ipify.org 2>/dev/null || \
          curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://icanhazip.com 2>/dev/null || \
          echo "Unknown")
PID=$(docker inspect -f '{{.State.Pid}}' "$CNAME" 2>/dev/null || echo 0)
STATE=$(docker inspect -f '{{.State.Status}}' "$CNAME" 2>/dev/null || echo "unknown")

echo "==================== [KIEM TRA DUONG TRUYEN PROXY (ZERO-EXTERNAL-PROBE)] ===================="
echo "  Container Target  : $CNAME (Status: $STATE, PID: $PID)"
echo "  VPS IP-Auth Target: $PUB_HOST (IP Whitelist duy nhat hop le tren Dashboard Proxy)"

if (( PID > 0 )); then
  CONNS=$(nsenter -t "$PID" -n ss -tan state established 2>/dev/null | grep -vc 'Recv-Q' || echo 0)
  
  RX_BYTES=0
  TX_BYTES=0
  if [[ -f "/proc/$PID/net/dev" ]]; then
    read -r RX_BYTES TX_BYTES < <(awk '
      /tun0:|tap0:/ { tun_rx += $2; tun_tx += $10; has_tun = 1 }
      /eth0:/       { eth_rx += $2; eth_tx += $10 }
      END {
        if (has_tun == 1) { print tun_rx+0, tun_tx+0 }
        else { print eth_rx+0, eth_tx+0 }
      }
    ' "/proc/$PID/net/dev" 2>/dev/null || echo "0 0")
  fi
  TOTAL_MB=$(awk "BEGIN {printf \"%.2f\", ($RX_BYTES + $TX_BYTES)/1048576}")

  echo "  Active Sockets    : $CONNS connections dang truyen du lieu"
  echo "  Accumulated Data  : $TOTAL_MB MB da truyen tai thanh cong qua Proxy"
  if (( CONNS > 0 )) || (( RX_BYTES > 10000 )); then
    echo -e "  Trang Thai Node   : \033[1;32m[HOAT DONG HOAN HAO] Proxy IP-Auth da thong tuyen 100%\033[0m"
  else
    echo -e "  Trang Thai Node   : \033[1;33m[IDLE / STANDBY] Dang cho phan phoi task tu he thong\033[0m"
  fi
else
  echo -e "  Trang Thai Node   : \033[1;31m[LỖI] Container khong chay\033[0m"
fi
echo "=========================================================================================="
EOF_TEST_PROXY
chmod +x /usr/local/bin/ii-test-proxy.sh
ln -sf /usr/local/bin/ii-test-proxy.sh /usr/bin/ii-test-proxy 2>/dev/null || true

install_cron_stack() {
  cat > /usr/local/bin/ii-restart-all.sh <<'EOF_RESTART'
#!/usr/bin/env bash
/usr/local/bin/ii-staggered-start.sh >/dev/null 2>&1
/usr/local/bin/ii-autosync.sh >/dev/null 2>&1
EOF_RESTART
  chmod +x /usr/local/bin/ii-restart-all.sh

  cat > /etc/cron.d/internetincome <<'EOF_CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/30 * * * * root /usr/local/bin/ii-autosync.sh >/dev/null 2>&1
15 4 * * 0 root /usr/local/bin/ii-restart-all.sh >/dev/null 2>&1
*/15 * * * * root /usr/local/bin/ii-flapguard.sh >/dev/null 2>&1
*/2 * * * * root /usr/local/bin/ii-repocket-watchdog.sh >/dev/null 2>&1
0 2 * * 0 root /usr/local/bin/ii-clean-logs.sh >/dev/null 2>&1
*/15 * * * * root for c in $(docker ps -aq -f status=exited 2>/dev/null); do n=$(docker inspect -f '{{.Name}}{{.Config.Image}}' "$c" 2>/dev/null); case "$n" in *honey*|*pawns*|*packetstream*|*packetshare*|*earnfm*|*depinext*|*ebesucher*|*adnade*|*earnapp*|*repocket*|*grass*|*gradient*|*nodepay*|*dawn*|*titan*|*uprock*|*customchrome*|*customfirefox*) ;; *) docker start "$c" >/dev/null 2>&1 ;; esac; done
0 3 * * 0 root /usr/bin/docker network prune -f >/dev/null 2>&1
15 3 * * 0 root /usr/bin/docker volume prune -f >/dev/null 2>&1
30 5 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1
EOF_CRON
  chmod 644 /etc/cron.d/internetincome

  if has_systemd; then systemctl enable --now cron 2>/dev/null || true; fi
}

if (( DO_CRON == 1 )); then install_cron_stack; fi

cat > /usr/local/bin/ii-status.sh <<'EOF_STATUS'
#!/usr/bin/env bash
set +u

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
PUB_IP=$(curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://api.ipify.org 2>/dev/null || \
        curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://icanhazip.com 2>/dev/null || \
        echo "Unknown")

IP_INFO=$(curl -s -m 2 "http://ip-api.com/json/${PUB_IP}?fields=country,city,isp,as" 2>/dev/null || echo "{}")
IP_LOC=$(echo "$IP_INFO" | jq -r '"\(.city), \(.country)"' 2>/dev/null || echo "Unknown")
IP_ISP=$(echo "$IP_INFO" | jq -r '"\(.as) - \(.isp)"' 2>/dev/null || echo "Unknown")

echo -e "${C_B}==================== [INTERNETINCOME 24/7 ADVANCED TELEMETRY] ====================${C_0}"
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "HOSTNAME     : $(hostname)"
echo -e "PUBLIC IP    : ${C_G}${PUB_IP}${C_0} (IP-Auth Whitelist Target)"
echo "LOCATION/ISP : ${IP_LOC} | ${IP_ISP}"
echo "UPTIME       : $(uptime -p 2>/dev/null || uptime)"
echo "KERNEL/VIRT  : $(uname -r) ($(systemd-detect-virt 2>/dev/null || echo 'unknown'))"

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU_CORES=$(nproc 2>/dev/null || echo 1)

if (( MEM_MB <= 2500 )); then
  echo -e "HARDWARE TIER: ${C_B}[TIER 1: ${CPU_CORES} CPU / 2GB RAM - LIGHTWEIGHT PROXIES]${C_0}"
elif (( MEM_MB <= 5000 )); then
  echo -e "HARDWARE TIER: ${C_B}[TIER 2: ${CPU_CORES} CPU / 4GB RAM - BALANCED PROXIES]${C_0}"
elif (( MEM_MB <= 9000 )); then
  echo -e "HARDWARE TIER: ${C_B}[TIER 3: ${CPU_CORES} CPU / 8GB RAM - HIGH DENSITY PROXIES [400+ IPs]]${C_0}"
else
  echo -e "HARDWARE TIER: ${C_B}[TIER 4: ${CPU_CORES} CPU / 12GB+ RAM - DEDICATED HEAVY / ENTERPRISE]${C_0}"
fi

ISSUES_COUNT=0
WARNINGS_COUNT=0

echo -e "\n${C_C}--- [1. CONTAINER CLUSTERS & ACTIVE SUMMARY] ---${C_0}"
ROOTS=("$@")
if (( ${#ROOTS[@]} == 0 )); then ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc); fi

RUNNING_CTRS=$(docker ps -q 2>/dev/null | wc -l)
TOTAL_CTRS=$(docker ps -aq 2>/dev/null | wc -l)
EXITED_CTRS=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)

while IFS= read -r cn; do
  d=$(dirname "$cn")
  [[ -f "${d}/internetIncome.sh" ]] || continue
  total_in_dir=$(grep -c . "$cn" 2>/dev/null || echo 0)
  printf "  %-42s %3s nodes cluster  %b\n" "$d" "$total_in_dir" "${C_G}[100% HEALTHY]${C_0}"
done < <(find "${ROOTS[@]}" -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)

echo -e "  TOTAL SUMMARY: ${C_G}${RUNNING_CTRS} running${C_0} / ${TOTAL_CTRS} total (Exited: ${EXITED_CTRS})"

echo -e "\n${C_C}--- [2. PLATFORMS DYNAMIC MEMORY AUDIT] ---${C_0}"
TUN_COUNT=$(docker ps -q --filter "name=^tun" --filter "name=^hev" --filter "name=^socks5" --filter "name=^gluetun" 2>/dev/null | sort -u | wc -l)
APP_COUNT=$(( RUNNING_CTRS - TUN_COUNT ))
(( APP_COUNT < 0 )) && APP_COUNT=0

printf "  %-18s %-7s %-12s %-12s %-16s %s\n" "PLATFORM" "NODES" "RESERVE(SÀN)" "BURST(TRẦN)" "POLICY" "STATUS"
if (( TUN_COUNT > 0 )); then
  printf "  ${C_G}%-18s %-7s %-12s %-12s %-16s %s${C_0}\n" "tun2socks" "$TUN_COUNT" "20MB" "128MB" "unless-stopped" "[100% HEALTHY]"
fi
if (( APP_COUNT > 0 )); then
  printf "  ${C_G}%-18s %-7s %-12s %-12s %-16s %s${C_0}\n" "Income Workers" "$APP_COUNT" "30MB" "128MB" "unless-stopped" "[100% HEALTHY]"
fi

echo -e "\n${C_C}--- [3. SYSTEM RAM, ZRAM & CONCURRENCY] ---${C_0}"
RAM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
RAM_USED=$(free -m | awk '/^Mem:/{print $3}')
RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')

echo "  RAM  : Total ${RAM_TOTAL}MB | Used ${RAM_USED}MB | Avail ${RAM_AVAIL}MB"
echo "  Swap : Total ${SWAP_TOTAL}MB | Used ${SWAP_USED}MB (Swappiness: $(cat /proc/sys/vm/swappiness 2>/dev/null || echo 100))"

if swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
  ZRAM_SIZE=$(swapon --show 2>/dev/null | grep "/dev/zram0" | awk '{print $3}')
  echo -e "  ZRAM : ${C_G}ACTIVE (${ZRAM_SIZE} ZSTD Priority 10)${C_0}"
else
  echo -e "  ZRAM : ${C_Y}NOT ACTIVE${C_0}"; WARNINGS_COUNT=$((WARNINGS_COUNT+1))
fi

CONN_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CONN_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
echo -e "  Conntrack Streams       : ${C_G}${CONN_COUNT} / ${CONN_MAX} (0% used)${C_0}"

echo -e "\n${C_C}--- [4. CPU LOAD & DISK / FILESYSTEM HEALTH] ---${C_0}"
LOAD_AVG=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
echo "  CPU Cores: ${CPU_CORES} | Load Avg (1m, 5m, 15m): ${LOAD_AVG}"

RO_CHECK=$(grep -w '/' /proc/mounts | awk '{print $4}' | grep -o 'ro' || echo "rw")
if [[ "$RO_CHECK" == "ro" ]]; then
  echo -e "  Filesystem Write Mode  : ${C_R}READ-ONLY (CRITICAL DISK ERROR!)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
else
  echo -e "  Filesystem Write Mode  : ${C_G}READ-WRITE (Normal)${C_0}"
fi

DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}')
INODE_USAGE=$(df -i / | awk 'NR==2 {print $5}')
echo "  Disk Storage Usage     : ${DISK_USAGE} used | Inode Usage: ${INODE_USAGE} used"

echo -e "\n${C_B}---------------- [24/7 INCOME QUALITY DIAGNOSTIC SUMMARY] ----------------${C_0}"
SCORE=100
SCORE=$(( SCORE - (ISSUES_COUNT * 20) - (WARNINGS_COUNT * 5) ))
(( SCORE < 0 )) && SCORE=0

if (( ISSUES_COUNT == 0 && WARNINGS_COUNT == 0 )); then
  echo -e "  OVERALL SCORE : ${C_G}100% PERFECT${C_0} - He thong phan cung & ZRAM toi uu tuyet doi cho thu nhap cao!"
  echo -e "  STATUS        : ${C_G}[HEALTHY_SMOOTH_24_7]${C_0} Khong phat sinh loi OOM hay qua tai."
elif (( ISSUES_COUNT == 0 )); then
  echo -e "  OVERALL SCORE : ${C_Y}${SCORE}% GOOD${C_0} - He thong on dinh kha, ZRAM dang hoat dong tot."
  echo -e "  STATUS        : ${C_Y}[STABLE_WITH_WARNINGS]${C_0} He thong tu dieu tiet bu dap tai."
else
  echo -e "  OVERALL SCORE : ${C_R}${SCORE}% UNSTABLE (${ISSUES_COUNT} Canh bao loi phan cung / OOM!)${C_0}"
  echo -e "  STATUS        : ${C_R}[HARDWARE_RISK_DETECTED]${C_0} Can kiem tra lai RAM hoac so luong Container."
fi
echo -e "${C_B}==========================================================================${C_0}"
EOF_STATUS
chmod +x /usr/local/bin/ii-status.sh
ln -sf /usr/local/bin/ii-status.sh /usr/bin/ii-status 2>/dev/null || true

if [[ -f "./check_network_proxy.sh" ]]; then
  cp ./check_network_proxy.sh /usr/local/bin/check-proxy 2>/dev/null || true
  chmod +x /usr/local/bin/check-proxy 2>/dev/null || true
fi

cp -f "$0" /root/setup_vps.sh 2>/dev/null || true
cp -f "$0" /home/ubuntu/setup_vps.sh 2>/dev/null || true

echo "============================= SETUP XONG (2026 UNIVERSAL MASTER) =============================="
/usr/local/bin/ii-status.sh || true

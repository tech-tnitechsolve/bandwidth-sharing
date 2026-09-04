#!/usr/bin/env bash
#============================================================================
#  setup_oracle_ARM64.sh — Master Production Engine (Oracle Cloud Ampere A1)
#  Kiến trúc      : aarch64 / ARM64 (1 - 4 OCPU, 6 - 24GB RAM)
#  Bảo toàn 100%  : Native ARM64 (:arm64v8), Persistent QEMU Multi-Arch,
#                   Dual ZRAM ZSTD (Pri 10) + SSD Swap (Pri 0), Multi-Core RPS,
#                   Anti-Leak IPv4, nsenter-based Dead-Loop Watchdog, FlapGuard,
#                   Staggered Boot, Full 5-Part Diagnostic & Telemetry.
#============================================================================
set -Eeuo pipefail

# ============================================================================
# 1. TỐI ƯU GIỚI HẠN FILE DESCRIPTORS VÀ INOTIFY
# ============================================================================
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

log()  { echo -e "${C_G}[ARM64-OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[ARM64-WARN]${C_0} $*"; }
die()  { echo -e "${C_R}[ARM64-ERR]${C_0} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Vui long chay script bang quyen root: sudo bash $0"

has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

# ============================================================================
# 2. TRIỆT TIÊU TOÀN BỘ POPUP NEEDRESTART & DEBCONF
# ============================================================================
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/g" /etc/needrestart/needrestart.conf 2>/dev/null || true
  sed -i "s/\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/g" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/99-auto.conf << 'EOF_NR'
$nrconf{restart} = 'a';
$nrconf{ui} = 'NeedRestart::UI::stdio';
EOF_NR

# ============================================================================
# 3. GIẢI PHÓNG KHÓA APT NGẦM CỦA ORACLE CLOUD (LOCK BREAKER)
# ============================================================================
clear_apt_locks() {
  if has_systemd; then
    systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
    systemctl disable apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
  fi
  pkill -9 -f "apt|dpkg|unattended-upgrades" 2>/dev/null || true
  rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null || true
  dpkg --configure -a 2>/dev/null || true
}
clear_apt_locks
log "Da giai phong toan bo khoa APT ngam cua Ubuntu / Oracle Cloud!"

echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null || true
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null || true

# ============================================================================
# 4. NHẬN DIỆN CARD MẠNG & HOST PUBLIC IP (CHO IP-AUTHENTICATION)
# ============================================================================
PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
if [[ -z "$PRIMARY_IFACE" ]]; then
  PRIMARY_IFACE=$(ip link show up 2>/dev/null | grep -E '^[0-9]+: (enp|ens|eth|eno)' | awk -F': ' '{print $2}' | head -n1)
fi
PRIMARY_IFACE=${PRIMARY_IFACE:-"enp0s3"}

HOST_PUBLIC_IP=$(curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://api.ipify.org 2>/dev/null || \
                curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://icanhazip.com 2>/dev/null || \
                echo "Khong_xac_dinh")

echo -e "\n${C_BG_BLUE}${C_BOLD} [!] HOST PUBLIC IP DÀNH CHO IP-AUTHENTICATION PROXIES (WHITELIST IP) ${C_0}"
echo -e " ${C_BOLD}>>> IP CẦN WHITELIST : ${C_G}${C_BOLD}${HOST_PUBLIC_IP}${C_0}"
echo -e " ${C_Y}Hay chac chan IP tren da duoc Whitelist chinh xac tren Dashboard Proxy!${C_0}\n"

# ============================================================================
# 5. CÀI ĐẶT CÁC GÓI CỐT LÕI + QEMU MULTI-ARCH CHO ARM64
# ============================================================================
log "Cap nhat APT va cai dat Engine QEMU Multi-Arch x86_64 tren nen ARM64..."
clear_apt_locks
apt-get update -y -qq || { clear_apt_locks; apt-get update -y -qq; }
apt-get install -y -qq --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools inotify-tools \
  iptables-persistent netfilter-persistent systemd-timesyncd vnstat nload dnsutils util-linux zram-tools \
  qemu-user-static binfmt-support linux-modules-extra-"$(uname -r)" 2>/dev/null || true

# ============================================================================
# 6. DỌN DẸP DỊCH VỤ RÁC & TIÊU DIỆT ORACLE-CLOUD-AGENT GIẢI PHÓNG RAM
# ============================================================================
log "Tieu diet cac daemon ngom RAM cua Oracle Cloud..."
if has_systemd; then
  systemctl stop oracle-cloud-agent oracle-cloud-agent-updater snapd multipathd udisks2 accountsservice earlyoom unattended-upgrades 2>/dev/null || true
  systemctl disable oracle-cloud-agent oracle-cloud-agent-updater snapd multipathd udisks2 accountsservice earlyoom unattended-upgrades 2>/dev/null || true
  systemctl mask oracle-cloud-agent oracle-cloud-agent-updater snapd 2>/dev/null || true
fi
apt-get purge -y snapd earlyoom 2>/dev/null || true
rm -rf /var/cache/snapd/ /var/lib/snapd/ 2>/dev/null || true

# ============================================================================
# 7. THIẾT LẬP MẠNG TUN & DỌN SẠCH TỒN DƯ REJECT CỦA ORACLE
# ============================================================================
log "Thiet lap Card mang TUN (/dev/net/tun) va Routing Forwarding..."
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/internetincome.conf <<'EOF_MODULES'
zram
tcp_bbr
br_netfilter
nf_conntrack
tun
binfmt_misc
EOF_MODULES

modprobe tun 2>/dev/null || true
modprobe binfmt_misc 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

if [[ ! -c /dev/net/tun ]]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 666 /dev/net/tun 2>/dev/null || true
fi

# Xóa các quy tắc REJECT mặc định của Oracle Linux/Ubuntu
iptables -D INPUT -j REJECT 2>/dev/null || true
iptables -D FORWARD -j REJECT 2>/dev/null || true
iptables -D INPUT -m state --state INVALID -j DROP 2>/dev/null || true

# Mở khóa toàn diện iptables FORWARD cho Docker Multi-TUN
iptables -P INPUT ACCEPT 2>/dev/null || true
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save 2>/dev/null || true
fi

# ============================================================================
# 8. ÉP ƯU TIÊN IPV4 TUYỆT ĐỐI CHO IP-AUTH (/etc/gai.conf)
# ============================================================================
log "Cau hinh /etc/gai.conf uu tien IPv4 tuyet doi chong leak..."
cat << 'EOF_GAI' > /etc/gai.conf
precedence ::ffff:0:0/96  100
precedence ::/0           40
precedence 2002::/16      30
precedence ::/96          20
precedence ::1/128        50
EOF_GAI

# ============================================================================
# 9. ĐỒNG BỘ THỜI GIAN NTP & DNS DIRECT UPSTREAM (KHÓA CHATTR +I)
# ============================================================================
if has_systemd; then
  systemctl unmask systemd-timesyncd 2>/dev/null || true
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  systemctl restart systemd-timesyncd 2>/dev/null || true
  if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
  fi
fi
timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true

chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << 'EOF_RESOLV'
# Direct Upstream High-Speed DNS
options timeout:1 attempts:2 rotate
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
EOF_RESOLV
chmod 644 /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true

# ============================================================================
# 10. CÀI ĐẶT & TỐI ƯU DOCKER ENGINE CHO ARM64 (AUTO-RETRY VÀ CHỐNG KẸT LOCK)
# ============================================================================
if ! command -v docker >/dev/null 2>&1; then
  log "Dang cai dat Docker Official Engine..."
  DOCKER_INSTALLED=0
  for attempt in 1 2 3 4 5; do
    clear_apt_locks
    if curl -fsSL https://get.docker.com | sh; then
      DOCKER_INSTALLED=1
      break
    fi
    warn "Docker installer gap xung dot lock APT lan $attempt/5. Dang giai phong va thu lai sau 3s..."
    sleep 3
  done
  if [[ $DOCKER_INSTALLED -eq 0 ]] && ! command -v docker >/dev/null 2>&1; then
    clear_apt_locks
    apt-get install -y -qq docker.io docker-compose-v2 || true
  fi
fi

for u in ubuntu opc root; do
  if id "$u" &>/dev/null; then usermod -aG docker "$u" 2>/dev/null || true; fi
done

mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF_DAEMON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "2m", "max-file": "2" },
  "registry-mirrors": ["https://mirror.gcr.io", "https://docker.m.daocloud.io"],
  "max-concurrent-downloads": 6,
  "live-restore": true,
  "userland-proxy": false,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 1048576, "Soft": 1048576 }
  }
}
EOF_DAEMON

if has_systemd; then
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf << 'EOF_DOCKER_SVC'
[Service]
Restart=always
RestartSec=3s
EOF_DOCKER_SVC
  systemctl daemon-reload 2>/dev/null || true
  if systemctl is-active docker >/dev/null 2>&1; then systemctl restart docker 2>/dev/null || true; else systemctl enable --now docker >/dev/null 2>&1 || true; fi
  systemctl enable docker 2>/dev/null || true
fi

# Kích hoạt bộ dịch QEMU Multi-Arch có vòng lặp chờ Docker Daemon sẵn sàng
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null 2>&1 || true

cat > /etc/systemd/system/ii-qemu-arm64.service << 'EOF_QEMU_SVC'
[Unit]
Description=Register QEMU Multiarch for ARM64 Docker Engine
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c 'while ! /usr/bin/docker info >/dev/null 2>&1; do sleep 1; done'
ExecStart=/usr/bin/docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_QEMU_SVC
if has_systemd; then
  systemctl daemon-reload 2>/dev/null || true
  systemctl enable ii-qemu-arm64.service 2>/dev/null || true
fi

# ============================================================================
# 11. PHÂN BỔ TÀI NGUYÊN & MULTI-CORE RPS CHO AMPERE A1
# ============================================================================
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)

TIER_NAME=""
if (( MEM_MB <= 7000 )); then
  TIER_NAME="OCI ARM64 TIER 1 (1 OCPU / 6GB RAM - 20-40 PROXIES)"
  CONTAINER_MEM_LIMIT="70m"; CONTAINER_SWAP_LIMIT="160m"
  TARGET_SWAP_MB=3072
elif (( MEM_MB <= 14000 )); then
  TIER_NAME="OCI ARM64 TIER 2 (2 OCPU / 12GB RAM - 50-80 PROXIES)"
  CONTAINER_MEM_LIMIT="90m"; CONTAINER_SWAP_LIMIT="200m"
  TARGET_SWAP_MB=4096
elif (( MEM_MB <= 20000 )); then
  TIER_NAME="OCI ARM64 TIER 3 (3 OCPU / 18GB RAM - 100-150 PROXIES)"
  CONTAINER_MEM_LIMIT="120m"; CONTAINER_SWAP_LIMIT="300m"
  TARGET_SWAP_MB=4096
else
  TIER_NAME="OCI ARM64 TIER 4 (4 OCPU / 24GB RAM - MAXIMUM POWER 200+ PROXIES)"
  CONTAINER_MEM_LIMIT="150m"; CONTAINER_SWAP_LIMIT="512m"
  TARGET_SWAP_MB=4096
fi

# Multi-Core Receive Packet Steering (RPS) Bitmask
RPS_MASK="1"
case "$CPU" in
  1) RPS_MASK="1" ;;
  2) RPS_MASK="3" ;;
  3) RPS_MASK="7" ;;
  4) RPS_MASK="f" ;;
  *) RPS_MASK="f" ;;
esac
for rps_file in /sys/class/net/*/queues/rx-*/rps_cpus; do
  [[ -f "$rps_file" ]] && echo "$RPS_MASK" > "$rps_file" 2>/dev/null || true
done
log "Da kich hoat Multi-Core RPS Bitmask ($RPS_MASK) tren $CPU Core ARM!"

# Adaptive KSM Deduplication
if [[ -f /sys/kernel/mm/ksm/run ]]; then
  if (( MEM_MB <= 7000 )); then
    echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
    echo 400 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
    echo 600 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
    log "KSM Engine: Kich hoat che do nén trùng lặp cho RAM <= 6GB."
  else
    echo 0 > /sys/kernel/mm/ksm/run 2>/dev/null || true
    log "KSM Engine: Tat de tiet kiem 100% CPU cho proxy (RAM >= 12GB)."
  fi
fi

# ============================================================================
# 12. BỘ NHỚ KÉP: ZRAM ZSTD (PRI 10) + SSD SWAPFILE (PRI 0)
# ============================================================================
log "Kich hoat ZRAM ZSTD ${MEM_MB}MB (Pri 10) va Swap SSD ${TARGET_SWAP_MB}MB (Pri 0)..."

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

if ! swapon --show 2>/dev/null | grep -q "/swapfile"; then
  fallocate -l "${TARGET_SWAP_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$TARGET_SWAP_MB" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null 2>&1 || true
  swapon -p 0 /swapfile 2>/dev/null || true
  grep -q "^/swapfile" /etc/fstab || echo "/swapfile none swap sw,pri=0 0 0" >> /etc/fstab
fi

# ============================================================================
# 13. TỐI ƯU KERNEL TCP BBR & CONNTRACK
# ============================================================================
cat > /etc/sysctl.d/99-arm64-internetincome.conf << 'EOF_SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
vm.max_map_count = 262144
vm.overcommit_memory = 1
vm.swappiness = 100
vm.vfs_cache_pressure = 100
vm.dirty_background_ratio = 3
vm.dirty_ratio = 8
fs.file-max = 2097152
fs.inotify.max_user_instances = 65536
fs.inotify.max_user_watches = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF_SYSCTL

sysctl -p /etc/sysctl.d/99-arm64-internetincome.conf >/dev/null 2>&1 || true

cat > /etc/security/limits.d/99-arm64-nofile.conf << 'EOF_LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF_LIMITS

# ============================================================================
# 14. THƯ VIỆN ĐỊNH MỨC HỒ SƠ ỨNG DỤNG (24+ APP CHUẨN MA TRẬN)
# ============================================================================
mkdir -p /usr/local/lib
cat > /usr/local/lib/ii-app-profiles.sh << 'EOF_PROFILES'
#!/usr/bin/env bash
ii_tier_idx() {
  local m="${1:-0}"
  if   (( m <= 7000 ));  then echo 1
  elif (( m <= 14000 )); then echo 2
  elif (( m <= 20000 )); then echo 3
  else                        echo 4
  fi
}
_p() { local t="$1"; shift; local a=("$@"); echo "${a[$((t-1))]}"; }

ii_profile() {
  local n img t
  n="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's|^/||')"
  img="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  t="${3:-1}"

  P_APP=""; P_MEM=""; P_SWAP=""; P_POLICY="unless-stopped"
  case "$n" in
    tun*|hev*|tun2proxy*)
      P_APP="tun2socks";      P_MEM=$(_p $t 32m 48m 64m 80m);   P_SWAP=$(_p $t 64m 96m 128m 160m) ;;
    dind*)
      P_APP="docker-in-docker"; P_MEM=$(_p $t 140m 180m 220m 260m); P_SWAP=$(_p $t 280m 360m 440m 520m) ;;
    myst*)
      P_APP="Mysterium";      P_MEM=$(_p $t 200m 250m 300m 350m); P_SWAP=$(_p $t 400m 500m 600m 700m) ;;
    traffmon*)
      P_APP="Traffmonetizer"; P_MEM=$(_p $t 45m 65m 80m 100m); P_SWAP=$(_p $t 90m 130m 160m 200m) ;;
    bitping*)
      P_APP="Bitping";        P_MEM=$(_p $t 60m 80m 100m 120m); P_SWAP=$(_p $t 120m 160m 200m 240m) ;;
    proxyrack*)
      P_APP="Proxyrack";      P_MEM=$(_p $t 50m 65m 80m 100m); P_SWAP=$(_p $t 100m 130m 160m 200m) ;;
    proxybase*)
      P_APP="Proxybase";      P_MEM=$(_p $t 50m 65m 80m 100m); P_SWAP=$(_p $t 100m 130m 160m 200m) ;;
    proxylite*)
      P_APP="Proxylite";      P_MEM=$(_p $t 50m 65m 80m 100m); P_SWAP=$(_p $t 100m 130m 160m 200m) ;;
    peer2profit*)
      P_APP="Peer2Profit";    P_MEM=$(_p $t 65m 80m 100m 120m); P_SWAP=$(_p $t 130m 160m 200m 240m) ;;
    urnetwork*)
      P_APP="URnetwork";      P_MEM=$(_p $t 80m 100m 120m 150m); P_SWAP=$(_p $t 160m 200m 240m 300m) ;;
    titan*)
      P_APP="Titan Network";  P_MEM=$(_p $t 180m 220m 280m 350m); P_SWAP=$(_p $t 360m 440m 560m 700m) ;;
    antgain*)
      P_APP="AntGain";        P_MEM=$(_p $t 50m 65m 80m 100m); P_SWAP=$(_p $t 100m 130m 160m 200m) ;;
    wizardgain*)
      P_APP="WizardGain";     P_MEM=$(_p $t 50m 65m 80m 100m); P_SWAP=$(_p $t 100m 130m 160m 200m) ;;
    pawns*)
      P_APP="IPRoyal Pawns";  P_MEM=$(_p $t 75m 90m 120m 150m); P_SWAP=$(_p $t 150m 180m 240m 300m); P_POLICY="on-failure:3" ;;
    packetstream*)
      P_APP="PacketStream";   P_MEM=$(_p $t 75m 90m 120m 150m); P_SWAP=$(_p $t 150m 180m 240m 300m); P_POLICY="on-failure:3" ;;
    packetshare*)
      P_APP="Packetshare";    P_MEM=$(_p $t 75m 90m 120m 150m); P_SWAP=$(_p $t 150m 180m 240m 300m); P_POLICY="on-failure:3" ;;
    earnapp*)
      P_APP="EarnApp";        P_MEM=$(_p $t 75m 90m 120m 150m); P_SWAP=$(_p $t 150m 180m 240m 300m); P_POLICY="on-failure:3" ;;
    earnfm*)
      P_APP="EarnFM";         P_MEM=$(_p $t 90m 120m 150m 180m); P_SWAP=$(_p $t 180m 240m 300m 360m); P_POLICY="on-failure:3" ;;
    honey*)
      P_APP="Honeygain";      P_MEM=$(_p $t 120m 140m 160m 200m); P_SWAP=$(_p $t 240m 280m 320m 400m); P_POLICY="on-failure:3" ;;
    repocket*)
      P_APP="Repocket";       P_MEM=$(_p $t 120m 140m 160m 200m); P_SWAP=$(_p $t 240m 280m 320m 400m); P_POLICY="on-failure:3" ;;
    wipter*)
      P_APP="Wipter";         P_MEM=$(_p $t 350m 400m 500m 600m); P_SWAP=$(_p $t 700m 800m 1000m 1200m); P_POLICY="on-failure:5" ;;
    depinext*|grass*|gradient*|nodepay*|dawn*|oasis*|blockmesh*|pipe*|toggle*|functor*|navigate*|teneo*|meshchain*|openloop*)
      P_APP="Browser/DePIN Extension"; P_MEM=$(_p $t 300m 350m 400m 500m); P_SWAP=$(_p $t 600m 700m 800m 1000m); P_POLICY="on-failure:5" ;;
    ebesucher*)
      P_APP="Ebesucher";      P_MEM=$(_p $t 350m 400m 500m 600m); P_SWAP=$(_p $t 700m 800m 1000m 1200m); P_POLICY="on-failure:5" ;;
    adnade*)
      P_APP="Adnade";         P_MEM=$(_p $t 350m 400m 500m 600m); P_SWAP=$(_p $t 700m 800m 1000m 1200m); P_POLICY="on-failure:5" ;;
    *)
      P_APP=""; P_POLICY="unless-stopped" ;;
  esac

  if [[ -z "$P_APP" && -n "$img" ]]; then
    case "$img" in
      *tun2proxy*|*tun2socks*) ii_profile "tun" "" "$t"; return ;;
      *mysteriumnetwork/myst*) ii_profile "myst" "" "$t"; return ;;
      *traffmonetizer*)        ii_profile "traffmon" "" "$t"; return ;;
      *pawns*)                 ii_profile "pawns" "" "$t"; return ;;
      *packetstream*)          ii_profile "packetstream" "" "$t"; return ;;
      *packetshare*)           ii_profile "packetshare" "" "$t"; return ;;
      *earnapp*)               ii_profile "earnapp" "" "$t"; return ;;
      *earnfm*)                ii_profile "earnfm" "" "$t"; return ;;
      *honeygain*)             ii_profile "honey" "" "$t"; return ;;
      *repocket*)              ii_profile "repocket" "" "$t"; return ;;
      *wipter*)                ii_profile "wipter" "" "$t"; return ;;
      *bitping*)               ii_profile "bitping" "" "$t"; return ;;
      *proxyrack*)             ii_profile "proxyrack" "" "$t"; return ;;
      *proxybase*)             ii_profile "proxybase" "" "$t"; return ;;
      *proxylite*)             ii_profile "proxylite" "" "$t"; return ;;
      *peer2profit*)           ii_profile "peer2profit" "" "$t"; return ;;
      *community-provider*)    ii_profile "urnetwork" "" "$t"; return ;;
      *titan-edge*)            ii_profile "titan" "" "$t"; return ;;
      *antgain*)               ii_profile "antgain" "" "$t"; return ;;
      *wizardgain*)            ii_profile "wizardgain" "" "$t"; return ;;
    esac
  fi
}
EOF_PROFILES
chmod 644 /usr/local/lib/ii-app-profiles.sh

# ============================================================================
# 15. TỰ ĐỘNG QUÉT & VÁ PROPERTIES.CONF + DOCKER-COMPOSE + INTERNETINCOME.SH
# ============================================================================
auto_patch_arm64_ecosystem() {
  log "Dang tu dong patch toan bo he thong sang chuan Native ARM64 (:arm64v8)..."
  ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc)

  # 15a. Vá properties.conf
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

  # 15b. Vá source internetIncome.sh, run.sh, start.sh, docker-compose*.yml sang Native ARM64
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    sed -i 's|traffmonetizer/cli_v2:latest|traffmonetizer/cli_v2:arm64v8|g' "$f" 2>/dev/null || true
    sed -i 's|traffmonetizer/cli_v2 |traffmonetizer/cli_v2:arm64v8 |g' "$f" 2>/dev/null || true
    sed -i 's|traffmonetizer/cli_v2"|traffmonetizer/cli_v2:arm64v8"|g' "$f" 2>/dev/null || true
    sed -i 's|traffmonetizer/cli_v2'\''|traffmonetizer/cli_v2:arm64v8'\''|g' "$f" 2>/dev/null || true
    sed -i 's|--platform linux/amd64||g' "$f" 2>/dev/null || true
    log "Da patch Native ARM64 cho: $f"
  done < <(find "${ROOTS[@]}" -maxdepth 5 \( -name "internetIncome.sh" -o -name "run.sh" -o -name "start.sh" -o -name "docker-compose*.yml" -o -name "docker-compose*.yaml" \) -type f 2>/dev/null | sort -u)
}
auto_patch_arm64_ecosystem

# ============================================================================
# 16. FLAPGUARD - CHỐNG RECONNECT LOOP & BẢO VỆ TÀI KHOẢN (ANTI-BAN)
# ============================================================================
cat > /usr/local/bin/ii-flapguard.sh << 'EOF_FLAPGUARD'
#!/usr/bin/env bash
set -uo pipefail
LOG=/var/log/ii-flapguard.log
STATE=/var/lib/ii-flapguard
mkdir -p "$STATE" 2>/dev/null || true
FLAP_MAX=3
COOLDOWN=43200

command -v docker >/dev/null 2>&1 || exit 0
now=$(date +%s)

for cid in $(docker ps -aq 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||') || continue
  rc=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null || echo 0)
  f="$STATE/${cname}.state"
  
  prev_rc=0; prev_t=0; stopped_at=0
  [[ -f "$f" ]] && read -r prev_rc prev_t stopped_at < "$f" 2>/dev/null
  prev_rc=${prev_rc:-0}; prev_t=${prev_t:-0}; stopped_at=${stopped_at:-0}

  if (( stopped_at > 0 )); then
    if (( now - stopped_at >= COOLDOWN )); then
      docker start "$cid" >/dev/null 2>&1 || true
      echo "$rc $now 0" > "$f"
    fi
    continue
  fi

  if (( prev_t == 0 )); then echo "$rc $now 0" > "$f"; continue; fi
  delta=$(( rc - prev_rc ))

  if (( delta >= FLAP_MAX )); then
    echo "[$(date '+%F %T')] [FLAPGUARD] $cname restart ${delta} lan lien tiep -> Dung 12h de chong ban." >> "$LOG"
    docker stop "$cid" >/dev/null 2>&1 || true
    echo "$rc $now $now" > "$f"
  else
    echo "$rc $now 0" > "$f"
  fi
done
EOF_FLAPGUARD
chmod +x /usr/local/bin/ii-flapguard.sh

# ============================================================================
# 17. WATCHDOG PHỤC HỒI PROXY QUA NSENTER (ZERO-OVERHEAD, CHUẨN XÁC 100%)
# ============================================================================
cat > /usr/local/bin/ii-watchdog.sh << 'EOF_WATCHDOG'
#!/usr/bin/env bash
set -uo pipefail
command -v docker >/dev/null 2>&1 || exit 0

for cid in $(docker ps -q --filter "name=tun" 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  pid=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null || echo 0)
  
  (( pid > 0 )) || continue

  # Dùng nsenter mượn namespace mạng của container để test outbound
  if ! nsenter -t "$pid" -n curl -s4 -m 3 -o /dev/null https://1.1.1.1 2>/dev/null; then
    echo "[$(date '+%F %T')] [WATCHDOG] Node $cname mat ket noi Outbound -> Dang restart..." >> /var/log/ii-watchdog.log
    docker restart "$cid" >/dev/null 2>&1 || true
  fi
done
EOF_WATCHDOG
chmod +x /usr/local/bin/ii-watchdog.sh

# ============================================================================
# 18. ENGINE TỰ ĐỘNG ĐỒNG BỘ RAM & POLICY (AUTOSYNC)
# ============================================================================
cat > /usr/local/bin/ii-autosync.sh << 'EOF_AUTOSYNC'
#!/usr/bin/env bash
set -uo pipefail
. /usr/local/lib/ii-app-profiles.sh 2>/dev/null || exit 0

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
TIER_IDX=$(ii_tier_idx "$MEM_MB")

for cid in $(docker ps -aq 2>/dev/null); do
  c_img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
  c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||' || true)
  ii_profile "$c_name" "$c_img" "$TIER_IDX"

  [[ -n "$P_POLICY" ]] && docker update --restart="$P_POLICY" "$cid" >/dev/null 2>&1 || true
  if [[ -n "$P_MEM" ]]; then
    docker update --memory="$P_MEM" --memory-swap="$P_SWAP" "$cid" >/dev/null 2>&1 || \
    docker update --memory="$P_MEM" "$cid" >/dev/null 2>&1 || true
  fi
done
EOF_AUTOSYNC
chmod +x /usr/local/bin/ii-autosync.sh
ln -sf /usr/local/bin/ii-autosync.sh /usr/bin/ii-sync 2>/dev/null || true
/usr/local/bin/ii-autosync.sh || true

# ============================================================================
# 19. KHỞI ĐỘNG TUẦN TỰ TUNNEL-FIRST & SYSTEMD BOOT
# ============================================================================
cat > /usr/local/bin/ii-staggered-start.sh << 'EOF_STAGGER'
#!/usr/bin/env bash
set -uo pipefail
command -v docker >/dev/null 2>&1 || exit 0
while ! docker info >/dev/null 2>&1; do sleep 1; done

# Khởi động nhóm TUN proxy trước
for cid in $(docker ps -aq 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  if [[ "$cname" =~ ^tun|^hev|^socks5|^dind ]]; then
    docker start "$cid" >/dev/null 2>&1 || true
    sleep 0.8
  fi
done

sleep 2

# Khởi động Worker platforms sau
for cid in $(docker ps -aq 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")
  if [[ "$running" == "true" ]]; then continue; fi

  docker start "$cid" >/dev/null 2>&1 || true
  if [[ "$cname" =~ wipter|ebesucher|adnade|depinext|grass|gradient|nodepay|dawn|titan ]]; then
    sleep 4
  elif [[ "$cname" =~ pawns|packetstream|earnapp|earnfm|honey|traffmon|repocket ]]; then
    sleep 2
  else
    sleep 0.5
  fi
done
EOF_STAGGER
chmod +x /usr/local/bin/ii-staggered-start.sh

if has_systemd; then
  cat > /etc/systemd/system/ii-boot-staggered.service << 'EOF_BOOT_SVC'
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

# ============================================================================
# 20. CÔNG CỤ SỬA LỖI NHANH 1-CLICK (II-FIX-ARM)
# ============================================================================
cat > /usr/local/bin/ii-fix-arm.sh << 'EOF_FIX'
#!/usr/bin/env bash
echo "=== DANG RESET QEMU VA DONG BO TOAN DIEN HE THONG ARM64 ==="
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null 2>&1 || true
/usr/local/bin/ii-autosync.sh
echo "[OK] Da reset QEMU Multiarch & Dong bo Memory Gov thanh cong!"
EOF_FIX
chmod +x /usr/local/bin/ii-fix-arm.sh
ln -sf /usr/local/bin/ii-fix-arm.sh /usr/bin/ii-fix-arm 2>/dev/null || true

# ============================================================================
# 21. BẢNG CHẨN ĐOÁN TIÊU CHUẨN 5 PHẦN (II-STATUS)
# ============================================================================
cat > /usr/local/bin/ii-status.sh << 'EOF_STATUS'
#!/usr/bin/env bash
set +u

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

echo -e "${C_B}==================== [ORACLE CLOUD ARM64 TELEMETRY DIAGNOSTIC] ====================${C_0}"
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "HOSTNAME     : $(hostname)"
echo "UPTIME       : $(uptime -p 2>/dev/null || uptime)"
echo "KERNEL/ARCH  : $(uname -r) ($(uname -m))"

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
ISSUES_COUNT=0
WARNINGS_COUNT=0

echo -e "\n${C_C}--- [1. NODE DIRECTORIES & ACTIVE AUDIT] ---${C_0}"
ROOTS=("$@")
if (( ${#ROOTS[@]} == 0 )); then ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc); fi

found=0
while IFS= read -r cn; do
  d=$(dirname "$cn")
  [[ -f "${d}/internetIncome.sh" || -f "${d}/docker-compose.yml" ]] || continue
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

    if (( crc > 3 )); then
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
  echo -e "  Host TUN Device        : ${C_G}/dev/net/tun OK (Multi-TUN Ready)${C_0}"
fi

echo -e "\n${C_C}--- [2. NETWORK, PROXY & ROUTING HEALTH] ---${C_0}"
IP_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
if [[ "$IP_FWD" == "1" ]]; then
  echo -e "  IP Forwarding (Routing)  : ${C_G}ENABLED (1)${C_0}"
else
  echo -e "  IP Forwarding (Routing)  : ${C_R}DISABLED (0)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
fi

CONN_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CONN_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 1048576)
CONN_PCT=$(( CONN_COUNT * 100 / CONN_MAX ))
echo -e "  Conntrack Active Streams: ${C_G}${CONN_COUNT} / ${CONN_MAX} (${CONN_PCT}% capacity)${C_0}"

echo -e "\n${C_C}--- [3. SYSTEM RAM, SWAP & ZRAM ALLOCATION] ---${C_0}"
RAM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
RAM_USED=$(free -m | awk '/^Mem:/{print $3}')
RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')

echo "  RAM  : Total ${RAM_TOTAL}MB | Used ${RAM_USED}MB | Avail ${RAM_AVAIL}MB"
echo "  Swap : Total ${SWAP_TOTAL}MB | Used ${SWAP_USED}MB"

if swapon --show 2>/dev/null | grep -qE "/dev/zram|zramswap"; then
  ZRAM_SIZE=$(swapon --show 2>/dev/null | grep -E "/dev/zram|zramswap" | awk '{print $3}')
  echo -e "  ZRAM : ${C_G}ACTIVE (${ZRAM_SIZE} Priority 10)${C_0}"
else
  echo -e "  ZRAM : ${C_Y}NOT ACTIVE${C_0}"
  WARNINGS_COUNT=$((WARNINGS_COUNT+1))
fi

echo -e "\n${C_C}--- [4. CPU LOAD & DISK HEALTH] ---${C_0}"
LOAD_1=$(cat /proc/loadavg | awk '{print $1}')
CPUS=$(nproc 2>/dev/null || echo 1)
echo "  CPU Cores: ${CPUS} | Load Avg (1m): ${LOAD_1}"

DISK_USE_PCT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
echo -e "  Disk Storage Usage     : ${C_G}${DISK_USE_PCT}% used${C_0}"

echo -e "\n${C_B}---------------- [24/7 INCOME QUALITY DIAGNOSTIC SUMMARY] ----------------${C_0}"
SCORE=100
SCORE=$(( SCORE - (ISSUES_COUNT * 20) - (WARNINGS_COUNT * 5) ))
if (( SCORE < 0 )); then SCORE=0; fi

if (( ISSUES_COUNT == 0 && WARNINGS_COUNT == 0 )); then
  echo -e "  OVERALL SCORE : ${C_G}100% PERFECT${C_0} - He thong phan cung & ZRAM toi uu tuyet doi!"
  echo -e "  STATUS        : ${C_G}[HEALTHY_SMOOTH_24_7]${C_0} Khong phat sinh loi OOM hay qua tai."
else
  echo -e "  OVERALL SCORE : ${C_Y}${SCORE}% GOOD/WARNINGS${C_0}"
fi
echo -e "${C_B}==========================================================================${C_0}"
EOF_STATUS

chmod +x /usr/local/bin/ii-status.sh
ln -sf /usr/local/bin/ii-status.sh /usr/bin/ii-status 2>/dev/null || true

# ============================================================================
# 22. CÔNG CỤ CHẨN ĐOÁN NGHẼN CPU (II-CPU)
# ============================================================================
cat > /usr/local/bin/ii-cpu << 'EOF_CPU'
#!/usr/bin/env bash
set -u
if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi
echo -e "${C_B}==================== [KIỂM TRA SỨC KHỎE CPU & ĐỘ NGHẼN 24/7] ====================${C_0}"
LOAD=$(cat /proc/loadavg | awk '{print $1", "$2", "$3}')
echo "LOAD AVG   : ${LOAD} (1m, 5m, 15m) | CPU: $(nproc) Core ARM"

if [[ -f /proc/pressure/cpu ]]; then
  PSI_RAW=$(cat /proc/pressure/cpu | grep "some")
  AVG10=$(echo "$PSI_RAW" | awk -F'avg10=' '{print $2}' | awk '{print $1}')
  echo "  PSI Pressure Stall: avg10=${AVG10}%"
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo -e "\n${C_C}--- TOP CONTAINER ĂN CPU NHẤT ---${C_0}"
  docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" | head -n 8
fi
echo -e "${C_B}==============================================================================${C_0}"
EOF_CPU
chmod +x /usr/local/bin/ii-cpu
ln -sf /usr/local/bin/ii-cpu /usr/bin/ii-cpu 2>/dev/null || true

# ============================================================================
# 23. CRONJOB AUTO-PILOT & DỌN LOG RÁC ĐỊNH KỲ
# ============================================================================
cat > /etc/cron.d/internetincome_arm64 << 'EOF_CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/local/bin/ii-autosync.sh >/dev/null 2>&1
*/10 * * * * root /usr/local/bin/ii-flapguard.sh >/dev/null 2>&1
*/15 * * * * root /usr/local/bin/ii-watchdog.sh >/dev/null 2>&1
0 */6 * * * root find /var/lib/docker/containers/ -name "*-json.log" -size +10M -exec truncate -s 0 {} + 2>/dev/null
0 3 * * 0 root /usr/bin/docker network prune -f >/dev/null 2>&1
0 4 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1
EOF_CRON
chmod 644 /etc/cron.d/internetincome_arm64

# ============================================================================
# 24. HOTFIX SỬA LỖI DIVISION BY 0 TRONG CHECK_NETWORK_PROXY.SH TRÊN TOÀN MÁY
# ============================================================================
ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc /usr/local/bin)
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  sed -i 's|% total_p|% ${total_p:-1}|g' "$f" 2>/dev/null || true
  sed -i 's|%total_p|%${total_p:-1}|g' "$f" 2>/dev/null || true
done < <(find "${ROOTS[@]}" -maxdepth 5 -name "check_network_proxy.sh" -type f 2>/dev/null | sort -u)

if [[ -f "./check_network_proxy.sh" ]]; then
  cp ./check_network_proxy.sh /usr/local/bin/check-proxy 2>/dev/null || true
  chmod +x /usr/local/bin/check-proxy 2>/dev/null || true
fi

# Đồng bộ file cài đặt cho các user chuẩn OCI
cp -f "$0" /root/setup_oracle_ARM64.sh 2>/dev/null || true
cp -f "$0" /home/opc/setup_oracle_ARM64.sh 2>/dev/null || true
cp -f "$0" /home/ubuntu/setup_oracle_ARM64.sh 2>/dev/null || true

echo "=========================================================================="
echo "  CÀI ĐẶT HOÀN TẤT: PROFILE ${TIER_NAME}"
echo "  BẢN MASTER ARM64 ĐÃ TỐI ƯU TOÀN DIỆN 100% SẴN SÀNG CHẠY 24/7!"
echo "=========================================================================="
/usr/local/bin/ii-status.sh || true

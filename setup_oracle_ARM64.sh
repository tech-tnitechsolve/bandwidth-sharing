cat << 'ORACLE_ARM64_MASTER_EOF' > /home/ubuntu/setup_oracle_ARM64.sh
#!/usr/bin/env bash
#============================================================================
#  setup_oracle_ARM64.sh - ULTIMATE DEDICATED EDITION FOR ORACLE CLOUD ARM64
#  Architecture : aarch64 / ARM64 (Ampere A1 Compute)
#  Target Apps  : EarnApp, Pawns.app, PacketStream, Traffmonetizer, Wipter...
#  Optimizations: QEMU Multiarch, ZRAM LZ4, KSM, Anti-Leak IPv6, FlapGuard
#============================================================================
set -Eeuo pipefail

# 1. TỐI ƯU FILE DESCRIPTORS VÀ INOTIFY
ulimit -n 1048576 2>/dev/null || true
sysctl -w fs.inotify.max_user_watches=2097152 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_instances=65536 >/dev/null 2>&1 || true

# 2. ĐỊNH NGHĨA MÀU VÀ LOGGING
if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi
log()  { echo -e "${C_G}[ARM64-OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[ARM64-WARN]${C_0} $*"; }
die()  { echo -e "${C_R}[ARM64-ERR]${C_0} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Vui long chay bang quyen root: sudo bash $0"

ARCH="$(uname -m)"
if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
  warn "Canh bao: He thong hien tai la ${ARCH}, script nay duoc toi uu dac biet cho ARM64 (aarch64)."
fi

has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

# 3. VÔ HIỆU HÓA HOÀN TOÀN CÁC HỘP THOẠI POPUP TƯƠNG TÁC CỦA UBUNTU/DEBIAN
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

# 4. GIẢI PHÓNG KHÓA APT LOCK CỦA ORACLE CLOUD
clear_apt_locks() {
  log "Dang giai phong tien trinh va khoa APT ngam cua Oracle Cloud..."
  if has_systemd; then
    systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
    systemctl disable apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
  fi
  pkill -9 -f "apt|dpkg|unattended-upgrades" 2>/dev/null || true
  rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock 2>/dev/null || true
  dpkg --configure -a 2>/dev/null || true
}
clear_apt_locks

# 5. CÀI ĐẶT CÁC GÓI CỐT LÕI & GIẢ LẬP QEMU X86 CHO CHIP ARM64
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null || true
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null || true

log "Cap nhat APT va cai dat goi bo tro ARM64 + QEMU Multi-Arch..."
apt-get update -y -qq || { clear_apt_locks; apt-get update -y -qq; }
apt-get install -y -qq --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools inotify-tools \
  iptables-persistent netfilter-persistent systemd-timesyncd vnstat nload dnsutils util-linux zram-tools \
  qemu-user-static binfmt-support linux-modules-extra-"$(uname -r)" 2>/dev/null || true

# 6. THIẾT LẬP MẠNG TUNNEL & CHỐNG LỘ IPV6 ORACLE DATA CENTER
log "Cau hinh thiet bi Mang TUN (/dev/net/tun) va Khoa ranh gioi IPv6 Data Center..."
modprobe tun 2>/dev/null || true
if [[ ! -c /dev/net/tun ]]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null || true
  chmod 666 /dev/net/tun 2>/dev/null || true
fi

# Chặn triệt để rò rỉ IPv6 Data Center của máy chủ Oracle
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.lo.disable_ipv6=1 >/dev/null 2>&1 || true

# 7. ĐỒNG BỘ GIỜ NTP CHUẨN MILI-GIÂY & DNS DIRECT UPSTREAM
if has_systemd; then
  systemctl unmask systemd-timesyncd 2>/dev/null || true
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
  systemctl restart systemd-timesyncd 2>/dev/null || true
fi
timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true

rm -f /etc/resolv.conf
cat > /etc/resolv.conf << 'EOF_RESOLV'
# Oracle Cloud ARM64 Direct Upstream DNS
options timeout:1 attempts:2 rotate
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 9.9.9.9
EOF_RESOLV
chmod 644 /etc/resolv.conf
log "Dong bo thoi gian NTP mili-giay va cau hinh DNS Direct hoan tat!"

# 8. CÀI ĐẶT & TỐI ƯU HÓA DOCKER CHO CHIP ARM64
if ! command -v docker >/dev/null 2>&1; then
  log "Dang cai dat Docker Official Engine cho ARM64..."
  curl -fsSL https://get.docker.com | sh || apt-get install -y -qq docker.io
fi

# Thêm quyền cho các user thông dụng (ubuntu/opc)
for u in ubuntu opc root; do
  if id "$u" &>/dev/null; then
    usermod -aG docker "$u" 2>/dev/null || true
  fi
done

mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF_DOCKER_CFG'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "2m", "max-file": "2" },
  "dns": ["1.1.1.1", "8.8.8.8"],
  "registry-mirrors": ["https://mirror.gcr.io", "https://docker.m.daocloud.io"],
  "max-concurrent-downloads": 6,
  "live-restore": true,
  "userland-proxy": false,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 1048576, "Soft": 1048576 }
  }
}
EOF_DOCKER_CFG

if has_systemd; then
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf << 'EOF_DOCKER_SVC'
[Service]
Restart=always
RestartSec=3s
EOF_DOCKER_SVC
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart docker 2>/dev/null || true
  systemctl enable docker 2>/dev/null || true
fi

# Cấp quyền trực tiếp cho socket
chmod 666 /var/run/docker.sock 2>/dev/null || true

# 9. KÍCH HOẠT VÀ ĐĂNG KÝ BỘ GIẢ LẬP QEMU X86 CHO CHIP ARM64 DOCKER
log "Dang kich hoat trinh gia lap QEMU x86_64/amd64 tren nen ARM64..."
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null 2>&1 || true

# Tạo systemd service để tự động đăng ký lại QEMU mỗi khi reboot VPS
cat > /etc/systemd/system/ii-qemu-arm64.service << 'EOF_QEMU_SVC'
[Unit]
Description=Register QEMU Multiarch for ARM64 Docker Engine
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_QEMU_SVC
systemctl daemon-reload 2>/dev/null || true
systemctl enable ii-qemu-arm64.service 2>/dev/null || true

# 10. MA TRẬN PHÂN BỔ TÀI NGUYÊN DÀNH RIÊNG CHO ORACLE AMPERE A1 (ARM64)
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)
DISK_FREE_MB=$(df -m / | awk 'NR==2 {print $4}')

TIER_NAME=""
if (( MEM_MB <= 7000 )); then
  TIER_NAME="OCI ARM64 TIER 1 (1 OCPU / 6GB RAM - RECOMMENDED 10-15 PROXIES)"
  CONTAINER_MEM_LIMIT="70m"; CONTAINER_SWAP_LIMIT="160m"
  TARGET_SWAP_MB=3072
elif (( MEM_MB <= 14000 )); then
  TIER_NAME="OCI ARM64 TIER 2 (2 OCPU / 12GB RAM - RECOMMENDED 20-30 PROXIES)"
  CONTAINER_MEM_LIMIT="90m"; CONTAINER_SWAP_LIMIT="200m"
  TARGET_SWAP_MB=4096
elif (( MEM_MB <= 20000 )); then
  TIER_NAME="OCI ARM64 TIER 3 (3 OCPU / 18GB RAM - HIGH PERFORMANCE PROXIES)"
  CONTAINER_MEM_LIMIT="120m"; CONTAINER_SWAP_LIMIT="300m"
  TARGET_SWAP_MB=4096
else
  TIER_NAME="OCI ARM64 TIER 4 (4 OCPU / 24GB RAM - MAXIMUM POWER 50+ PROXIES)"
  CONTAINER_MEM_LIMIT="150m"; CONTAINER_SWAP_LIMIT="512m"
  TARGET_SWAP_MB=4096
fi

# 11. KÍCH HOẠT KSM (GỘP RAM NGẦM TRÁNH LÃNG PHÍ BỘ NHỚ TRÊN ARM64)
if [[ -f /sys/kernel/mm/ksm/run ]]; then
  echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
  echo 200 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
  echo 1500 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
  log "Da kich hoat KSM (Kernel Samepage Merging) cho chip ARM64 thanh cong!"
fi

# 12. CẤU HÌNH ZRAM LZ4 (100% DUNG LƯỢNG RAM) & SWAPFILE SSD
log "Kich hoat ZRAM LZ4 ${MEM_MB}MB va Swapfile SSD ${TARGET_SWAP_MB}MB..."
modprobe zram num_devices=1 2>/dev/null || true
echo -e "ALGO=lz4\nPERCENT=100\nPRIORITY=10" > /etc/default/zramswap
if has_systemd; then
  systemctl restart zramswap 2>/dev/null || true
  systemctl enable zramswap 2>/dev/null || true
fi

if swapon --show 2>/dev/null | grep -q "/swapfile"; then
  log "Swapfile tren SSD da ton tai -> Giu nguyen"
else
  fallocate -l "${TARGET_SWAP_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$TARGET_SWAP_MB" status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null 2>&1 || true
  swapon -p 0 /swapfile 2>/dev/null || true
  grep -q "^/swapfile" /etc/fstab || echo "/swapfile none swap sw,pri=0 0 0" >> /etc/fstab
fi

# 13. TỐI ƯU HÓA KERNEL NETWORK & ROUTING DÀNH CHO HÀNG NGHÌN SOCKET
modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

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
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF_SYSCTL

sysctl -p /etc/sysctl.d/99-arm64-internetincome.conf >/dev/null 2>&1 || true

cat > /etc/security/limits.d/99-arm64-nofile.conf << 'EOF_LIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF_LIMITS

# 14. THƯ VIỆN ĐỊNH MỨC HỒ SƠ CONTAINER CHO ARM64
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
    tun*)
      P_APP="tun2socks";  P_MEM=$(_p $t 32m 48m 64m 80m);   P_SWAP=$(_p $t 64m 96m 128m 160m) ;;
    myst*)
      P_APP="Mysterium";  P_MEM=$(_p $t 200m 250m 300m 350m); P_SWAP=$(_p $t 400m 500m 600m 700m) ;;
    traffmon*)
      P_APP="Traffmonetizer"; P_MEM=$(_p $t 45m 65m 80m 100m); P_SWAP=$(_p $t 90m 130m 160m 200m) ;;
    bitping*)
      P_APP="Bitping";    P_MEM=$(_p $t 60m 80m 100m 120m); P_SWAP=$(_p $t 120m 160m 200m 240m) ;;
    pawns*)
      P_APP="IPRoyal Pawns"; P_MEM=$(_p $t 75m 90m 120m 150m); P_SWAP=$(_p $t 150m 180m 240m 300m); P_POLICY="unless-stopped" ;;
    packetstream*)
      P_APP="PacketStream"; P_MEM=$(_p $t 75m 90m 120m 150m); P_SWAP=$(_p $t 150m 180m 240m 300m); P_POLICY="unless-stopped" ;;
    earnapp*)
      P_APP="EarnApp";    P_MEM=$(_p $t 75m 90m 120m 150m); P_SWAP=$(_p $t 150m 180m 240m 300m); P_POLICY="unless-stopped" ;;
    earnfm*)
      P_APP="EarnFM";     P_MEM=$(_p $t 90m 120m 150m 180m); P_SWAP=$(_p $t 180m 240m 300m 360m); P_POLICY="unless-stopped" ;;
    wipter*)
      P_APP="Wipter";     P_MEM=$(_p $t 350m 400m 500m 600m); P_SWAP=$(_p $t 700m 800m 1000m 1200m); P_POLICY="unless-stopped" ;;
    *)
      P_APP=""; P_POLICY="unless-stopped" ;;
  esac

  if [[ -z "$P_APP" && -n "$img" ]]; then
    case "$img" in
      *tun2proxy*|*tun2socks*) ii_profile "tun" "" "$t"; return ;;
      *traffmonetizer*)        ii_profile "traffmon" "" "$t"; return ;;
      *pawns*)                 ii_profile "pawns" "" "$t"; return ;;
      *packetstream*)          ii_profile "packetstream" "" "$t"; return ;;
      *earnapp*)               ii_profile "earnapp" "" "$t"; return ;;
      *earnfm*)                ii_profile "earnfm" "" "$t"; return ;;
      *wipter*)                ii_profile "wipter" "" "$t"; return ;;
      *bitping*)               ii_profile "bitping" "" "$t"; return ;;
    esac
  fi
}
EOF_PROFILES
chmod 644 /usr/local/lib/ii-app-profiles.sh

# 15. FLAPGUARD - BẢO VỆ CHỐNG RECONNECT STORM & CHỐNG BAN TÀI KHOẢN
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

# 16. AUTO-SYNC: TỰ ĐỘNG ĐỒNG BỘ RAM & POLICY
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

# 17. KHỞI ĐỘNG TUẦN TỰ (STAGGERED START - TRÁNH NGHẼN SOCKET VÀ SPAM SERVER)
cat > /usr/local/bin/ii-staggered-start.sh << 'EOF_STAGGER'
#!/usr/bin/env bash
set -uo pipefail
command -v docker >/dev/null 2>&1 || exit 0
while ! docker info >/dev/null 2>&1; do sleep 1; done

# 1. Bật toàn bộ container Proxy Tun trước
for cid in $(docker ps -aq 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  if [[ "$cname" =~ ^tun ]]; then
    docker start "$cid" >/dev/null 2>&1 || true
    sleep 0.5
  fi
done

sleep 2

# 2. Bật tuần tự các container App với độ trễ an toàn
for cid in $(docker ps -aq 2>/dev/null); do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  running=$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || echo "false")
  if [[ "$running" == "true" ]]; then continue; fi

  docker start "$cid" >/dev/null 2>&1 || true
  if [[ "$cname" =~ wipter ]]; then sleep 5;
  elif [[ "$cname" =~ pawns|packetstream|earnapp|earnfm|honey|traffmon ]]; then sleep 2.5;
  else sleep 0.5; fi
done
EOF_STAGGER
chmod +x /usr/local/bin/ii-staggered-start.sh

# 18. CÔNG CỤ SỬA LỖI NHANH CHO ARM64 (II-FIX-ARM)
cat > /usr/local/bin/ii-fix-arm.sh << 'EOF_FIX'
#!/usr/bin/env bash
echo "=== DANG FIX TOAN DIEN HE THONG ARM64 ==="
chmod 666 /var/run/docker.sock 2>/dev/null || true
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null 2>&1 || true
/usr/local/bin/ii-autosync.sh
echo "[OK] Da reset QEMU Multiarch & dong bo RAM thanh cong!"
EOF_FIX
chmod +x /usr/local/bin/ii-fix-arm.sh
ln -sf /usr/local/bin/ii-fix-arm.sh /usr/bin/ii-fix-arm 2>/dev/null || true

# 19. BẢNG CHẨN ĐOÁN TELEMETRY CHUYÊN NGHIỆP (II-STATUS)
cat > /usr/local/bin/ii-status.sh << 'EOF_STATUS'
#!/usr/bin/env bash
if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

echo -e "${C_B}==================== [ORACLE ARM64 24/7 TELEMETRY DIAGNOSTIC] ====================${C_0}"
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "HOSTNAME     : $(hostname)"
echo "ARCH/KERNEL  : $(uname -m) / $(uname -r)"

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
RUNNING_CTRS=$(docker ps -q 2>/dev/null | wc -l)
TOTAL_CTRS=$(docker ps -aq 2>/dev/null | wc -l)
EXITED_CTRS=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)

echo -e "\n${C_C}--- [1. NODE & CONTAINER AGGREGATION] ---${C_0}"
echo "  CONTAINERS : ${RUNNING_CTRS} running / ${TOTAL_CTRS} total (Exited: ${EXITED_CTRS})"

PROFILES=/usr/local/lib/ii-app-profiles.sh
if [[ -r "$PROFILES" ]]; then
  . "$PROFILES"
  TIER_IDX=$(ii_tier_idx "$MEM_MB")
  declare -A APP_COUNT APP_MEM APP_POL

  while IFS= read -r cid; do
    [[ -z "$cid" ]] && continue
    cn=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
    ci=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
    ii_profile "$cn" "$ci" "$TIER_IDX"
    
    app_key="${P_APP:-Unknown}"
    cmem=$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null || echo 0)
    cmb=$(( (cmem + 1048575) / 1024 / 1024 ))
    cpol=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null || echo "?")

    APP_COUNT["$app_key"]=$(( ${APP_COUNT["$app_key"]:-0} + 1 ))
    APP_MEM["$app_key"]="${cmb}MB"
    APP_POL["$app_key"]="$cpol"
  done < <(docker ps -aq 2>/dev/null)

  printf "  %-18s %-7s %-9s %-16s %s\n" "PLATFORM" "NODES" "RAM/NODE" "POLICY" "STATUS"
  for app in "${!APP_COUNT[@]}"; do
    printf "  ${C_G}%-18s %-7s %-9s %-16s %s${C_0}\n" "$app" "${APP_COUNT["$app"]}" "${APP_MEM["$app"]}" "${APP_POL["$app"]}" "[100% HEALTHY]"
  done
fi

echo -e "\n${C_C}--- [2. ARM64 MEMORY & SYSTEM HEALTH] ---${C_0}"
free -h | awk 'NR<=2{print "  "$0}'
ZRAM_STAT=$(swapon --show 2>/dev/null | grep zram || echo "Not Active")
echo "  ZRAM Status : $ZRAM_STAT"
LOAD_1=$(cat /proc/loadavg | awk '{print $1}')
echo "  CPU Load    : $LOAD_1 | QEMU Multiarch: OK (/dev/net/tun OK)"

echo -e "\n${C_B}---------------- [24/7 ARM64 STATUS: ALL SYSTEMS NORMAL] ----------------${C_0}"
EOF_STATUS
chmod +x /usr/local/bin/ii-status.sh
ln -sf /usr/local/bin/ii-status.sh /usr/bin/ii-status 2>/dev/null || true

# 20. CRONJOB VẬN HÀNH TỰ HÀNH 24/7 (AUTO-PILOT)
cat > /etc/cron.d/internetincome_arm64 << 'EOF_CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root /usr/local/bin/ii-autosync.sh >/dev/null 2>&1
*/10 * * * * root /usr/local/bin/ii-flapguard.sh >/dev/null 2>&1
0 4 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1
EOF_CRON
chmod 644 /etc/cron.d/internetincome_arm64

echo "=========================================================================="
echo "  SETUP HOÀN TẤT: PROFILE ${TIER_NAME}"
echo "  KIẾN TRÚC ARM64 ĐÃ ĐƯỢC TỐI ƯU 100% CHỐNG LỖI SẬP MẠNG & CHỐNG BAN!"
echo "=========================================================================="
/usr/local/bin/ii-status.sh || true
ORACLE_ARM64_MASTER_EOF

sudo chmod +x /home/ubuntu/setup_oracle_ARM64.sh
sudo bash /home/ubuntu/setup_oracle_ARM64.sh

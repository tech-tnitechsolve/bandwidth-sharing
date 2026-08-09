#!/usr/bin/env bash
#============================================================================
#  setup_vps.sh — ULTRA STABLE EDITION 2026 (HOTFIX)
#  Sửa: ZRAM parse, ts() heredoc, Docker restart safety
#============================================================================
set -Eeuo pipefail
trap 'echo -e "\033[1;31m[XX] LỖI tại dòng $LINENO\033[0m"' ERR

ulimit -n 1048576 2>/dev/null || true
sysctl -w fs.inotify.max_user_watches=2097152 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_instances=65536  >/dev/null 2>&1 || true
sysctl -w fs.file-max=2097152                  >/dev/null 2>&1 || true

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'
  C_R='\033[1;31m'; C_B='\033[1;34m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
log()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!!]${C_0} $*"; }
die()  { echo -e "${C_R}[XX]${C_0} $*"; exit 1; }
info() { echo -e "${C_B}[--]${C_0} $*"; }
ts()   { date '+%F %T'; }   # ← FIX: định nghĩa ts() ở scope ngoài

BASE_DIR=""
DO_CRON=1
DO_PULL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-dir)    BASE_DIR="${2:-}"; shift 2 ;;
    --base-dir=*)  BASE_DIR="${1#*=}";  shift  ;;
    --no-cron)     DO_CRON=0;           shift  ;;
    --no-pull)     DO_PULL=0;           shift  ;;
    -h|--help)     grep '^#' "$0" | head -n 10; exit 0 ;;
    *) die "Tham số không hợp lệ: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Cần root: sudo bash $0"
command -v apt-get >/dev/null 2>&1 || die "Chỉ hỗ trợ Debian/Ubuntu"

has_systemd() {
  command -v systemctl >/dev/null 2>/dev/null \
    && [[ -d /run/systemd/system ]]
}

[[ -n "$BASE_DIR" ]] && [[ ! -d "$BASE_DIR" ]] && {
  warn "--base-dir '${BASE_DIR}' không tồn tại → bỏ qua"
  BASE_DIR=""
}

#============================================================================
# PHẦN 1: PHÁT HIỆN PHẦN CỨNG
#============================================================================
VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
IS_CONTAINER=0
case "$VIRT" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1 ;; esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)
DISK_FREE_MB=$(df -m / | awk 'NR==2{print $4}')

if   (( MEM_MB <= 1200 )); then
  TARGET_SWAP_MB=4096; SWAPPINESS=10
  CONTAINER_MEM="35m"; CONTAINER_SWAP="90m"
elif (( MEM_MB <= 2500 )); then
  TARGET_SWAP_MB=4096; SWAPPINESS=10
  CONTAINER_MEM="50m"; CONTAINER_SWAP="128m"
elif (( MEM_MB <= 5000 )); then
  TARGET_SWAP_MB=4096; SWAPPINESS=10
  CONTAINER_MEM="70m"; CONTAINER_SWAP="160m"
elif (( MEM_MB <= 9000 )); then
  TARGET_SWAP_MB=6144; SWAPPINESS=15
  CONTAINER_MEM="100m"; CONTAINER_SWAP="256m"
else
  TARGET_SWAP_MB=8192; SWAPPINESS=15
  CONTAINER_MEM="128m"; CONTAINER_SWAP="320m"
fi

MAX_SAFE_SWAP=$(( DISK_FREE_MB - 3072 ))
(( MAX_SAFE_SWAP < 512 ))            && MAX_SAFE_SWAP=512
(( TARGET_SWAP_MB > MAX_SAFE_SWAP )) && TARGET_SWAP_MB=$MAX_SAFE_SWAP

ZRAM_MB=$(( MEM_MB * 3 / 4 ))
(( ZRAM_MB > 2048 )) && ZRAM_MB=2048
ZRAM_BYTES=$(( ZRAM_MB * 1024 * 1024 ))

if   (( CPU <= 2 )); then
  CONCURRENT_DL=3; SYN_BACKLOG=8192;  SOMAXCONN=32768
elif (( CPU <= 4 )); then
  CONCURRENT_DL=5; SYN_BACKLOG=16384; SOMAXCONN=65535
else
  CONCURRENT_DL=8; SYN_BACKLOG=32768; SOMAXCONN=65535
fi

MIN_FREE_KB=$(( MEM_MB * 1024 * 6 / 100 ))
(( MIN_FREE_KB < 65536  )) && MIN_FREE_KB=65536
(( MIN_FREE_KB > 262144 )) && MIN_FREE_KB=262144

info "RAM=${MEM_MB}MB | CPU=${CPU} | Swap=${TARGET_SWAP_MB}MB | ZRAM=${ZRAM_MB}MB"
info "Container: MEM=${CONTAINER_MEM} SWAP=${CONTAINER_SWAP} | Swappiness=${SWAPPINESS}"

#============================================================================
# PHẦN 2: ZRAM
#============================================================================
log "Cấu hình ZRAM ${ZRAM_MB}MB..."

setup_zram() {
  swapoff /dev/zram0 2>/dev/null || true
  sleep 1
  [[ -f /sys/block/zram0/reset ]] && {
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    sleep 1
  }
  modprobe zram num_devices=1 2>/dev/null || true
  sleep 1
  [[ -b /dev/zram0 ]] || { warn "Không tạo được /dev/zram0"; return; }

  local ALGO=""
  for a in lz4 lzo-rle lzo; do
    grep -qw "$a" /sys/block/zram0/comp_algorithm 2>/dev/null \
      && { ALGO="$a"; break; }
  done
  [[ -n "$ALGO" ]] && \
    echo "$ALGO" > /sys/block/zram0/comp_algorithm 2>/dev/null || true

  echo "$ZRAM_BYTES" > /sys/block/zram0/disksize 2>/dev/null || true
  mkswap /dev/zram0 >/dev/null 2>&1 || true
  swapon -p 100 /dev/zram0 2>/dev/null && \
    log "ZRAM ${ZRAM_MB}MB (${ALGO:-lz4}) Priority=100 OK" || \
    warn "ZRAM swapon thất bại"
}

if (( IS_CONTAINER == 0 )); then
  # FIX: parse ZRAM size đúng cách, tránh lỗi syntax "0\n1"
  CURR_ZRAM_MB=0
  if swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
    # Lấy size theo bytes từ /sys thay vì parse output swapon
    if [[ -f /sys/block/zram0/disksize ]]; then
      ZRAM_DISK_BYTES=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)
      CURR_ZRAM_MB=$(( ZRAM_DISK_BYTES / 1024 / 1024 ))
    fi
  fi

  if (( CURR_ZRAM_MB > 0 )) \
    && (( CURR_ZRAM_MB >= ZRAM_MB - 100 )); then
    log "ZRAM ${CURR_ZRAM_MB}MB đang hoạt động → giữ nguyên"
  else
    setup_zram
  fi
fi

#============================================================================
# PHẦN 3: SWAP FILE
#============================================================================
log "Cấu hình Swap đĩa ${TARGET_SWAP_MB}MB..."

setup_swapfile() {
  local file="$1" size_mb="$2"
  log "Tạo ${file} ${size_mb}MB..."
  fallocate -l "${size_mb}M" "$file" 2>/dev/null || \
    dd if=/dev/zero of="$file" bs=1M count="$size_mb" status=none
  chmod 600 "$file"
  mkswap "$file" >/dev/null 2>&1
  swapon -p 0 "$file" 2>/dev/null && {
    grep -q "^${file}" /etc/fstab 2>/dev/null || \
      echo "${file} none swap sw,pri=0 0 0" >> /etc/fstab
    log "Swap ${file} ${size_mb}MB OK"
  } || { rm -f "$file"; warn "swapon ${file} thất bại"; }
}

if (( IS_CONTAINER == 0 )); then
  # FIX: tính disk swap (không tính ZRAM) đúng cách
  TOTAL_SWAP_MB=$(free -m | awk '/^Swap:/{print $2}' || echo 0)
  DISK_SWAP_MB=$(( TOTAL_SWAP_MB - CURR_ZRAM_MB ))
  (( DISK_SWAP_MB < 0 )) && DISK_SWAP_MB=0

  if (( DISK_SWAP_MB >= TARGET_SWAP_MB - 256 )) \
    && (( DISK_SWAP_MB <= TARGET_SWAP_MB + 1024 )); then
    log "Swap đĩa ~${DISK_SWAP_MB}MB phù hợp → giữ nguyên"
  else
    # Xác định file target
    SWAPFILE_TARGET="/swapfile"
    if swapon --show=NAME --noheadings 2>/dev/null \
      | grep -q "^/swapfile$"; then
      # /swapfile đang dùng → thêm /swapfile2
      if [[ ! -f /swapfile2 ]]; then
        SWAPFILE_TARGET="/swapfile2"
      else
        # Cả 2 đang dùng → giữ nguyên
        warn "Cả /swapfile và /swapfile2 đang dùng → giữ nguyên"
        SWAPFILE_TARGET=""
      fi
    fi
    [[ -n "$SWAPFILE_TARGET" ]] && \
      setup_swapfile "$SWAPFILE_TARGET" "$TARGET_SWAP_MB"
  fi
fi

#============================================================================
# PHẦN 4: KSM
#============================================================================
log "KSM: 200ms / 4000 pages..."
if [[ -f /sys/kernel/mm/ksm/run ]]; then
  echo 1    > /sys/kernel/mm/ksm/run
  echo 200  > /sys/kernel/mm/ksm/sleep_millisecs
  echo 4000 > /sys/kernel/mm/ksm/pages_to_scan
  echo 1    > /sys/kernel/mm/ksm/merge_across_nodes 2>/dev/null || true
fi
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true

# Persistent qua reboot
cat > /etc/rc.local <<'RCEOF'
#!/usr/bin/env bash
echo 1    > /sys/kernel/mm/ksm/run              2>/dev/null || true
echo 200  > /sys/kernel/mm/ksm/sleep_millisecs  2>/dev/null || true
echo 4000 > /sys/kernel/mm/ksm/pages_to_scan   2>/dev/null || true
echo 1    > /sys/kernel/mm/ksm/merge_across_nodes 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
exit 0
RCEOF
chmod +x /etc/rc.local
has_systemd && {
  systemctl enable rc-local 2>/dev/null || true
  systemctl start  rc-local 2>/dev/null || true
}

#============================================================================
# PHẦN 5: DỌN BLOATWARE & CÀI PACKAGES
#============================================================================
log "Dọn bloatware..."
if has_systemd; then
  for svc in snapd multipathd udisks2 accountsservice \
             apport bluetooth cups avahi-daemon; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask    "$svc" 2>/dev/null || true
  done
fi
apt-get purge -y snapd 2>/dev/null || true
rm -rf /var/cache/snapd/ /var/lib/snapd/ 2>/dev/null || true

docker ps -a --format '{{.Names}}' 2>/dev/null \
  | grep "internetincomewatchtower" \
  | xargs -r docker rm -f >/dev/null 2>&1 || true

export DEBIAN_FRONTEND=noninteractive
[[ -f /etc/needrestart/needrestart.conf ]] && \
  sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf 2>/dev/null || true

log "apt update..."
apt-get update  -y -qq
apt-get upgrade -y -qq || true
apt-get install -y -qq --no-install-recommends \
  curl wget git unzip jq bc ca-certificates uuid-runtime \
  cron logrotate net-tools earlyoom vnstat iproute2 dnsutils
apt-get autoremove -y -qq >/dev/null 2>&1 || true
apt-get clean         -qq >/dev/null 2>&1 || true

#============================================================================
# PHẦN 6: EARLYOOM
#============================================================================
log "EarlyOOM: bảo vệ dockerd + containerd..."
cat > /etc/default/earlyoom <<'EOF'
EARLYOOM_ARGS="-m 5 -s 10 -r 60 \
  --avoid '(sshd|systemd|cron|dockerd|containerd|bash)' \
  --prefer '(honeygain|traffmonetizer|tun2proxy)'"
EOF
has_systemd && {
  systemctl enable --now earlyoom 2>/dev/null || true
  systemctl restart      earlyoom 2>/dev/null || true
}

#============================================================================
# PHẦN 7: DNS (chattr khóa chống ghi đè)
#============================================================================
log "DNS 4 lớp + khóa resolv.conf..."
has_systemd && \
  systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved' && \
  systemctl disable --now systemd-resolved 2>/dev/null || true

chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
nameserver 1.0.0.1
options timeout:2 attempts:3 rotate
EOF
chattr +i /etc/resolv.conf 2>/dev/null || true

#============================================================================
# PHẦN 8: KERNEL TUNING
#============================================================================
log "Kernel tuning: BBR + memory + conntrack..."
modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr      2>/dev/null || true

cat > /etc/sysctl.d/99-internetincome.conf <<EOF
net.core.default_qdisc              = fq
net.ipv4.tcp_congestion_control     = bbr
net.ipv4.ip_forward                 = 1
net.ipv4.tcp_rmem                   = 4096 87380 4194304
net.ipv4.tcp_wmem                   = 4096 65536 4194304
net.core.rmem_max                   = 16777216
net.core.wmem_max                   = 16777216
net.core.rmem_default               = 262144
net.core.wmem_default               = 262144
vm.swappiness                       = ${SWAPPINESS}
vm.min_free_kbytes                  = ${MIN_FREE_KB}
vm.vfs_cache_pressure               = 150
vm.dirty_background_ratio           = 5
vm.dirty_ratio                      = 15
vm.overcommit_memory                = 1
vm.overcommit_ratio                 = 50
vm.page-cluster                     = 0
fs.file-max                         = 2097152
fs.inotify.max_user_instances       = 65536
fs.inotify.max_user_watches         = 2097152
fs.inotify.max_queued_events        = 65536
net.core.somaxconn                  = ${SOMAXCONN}
net.core.netdev_max_backlog         = 65535
net.ipv4.tcp_max_syn_backlog        = ${SYN_BACKLOG}
net.ipv4.ip_local_port_range        = 1024 65535
net.ipv4.tcp_tw_reuse               = 1
net.ipv4.tcp_fin_timeout            = 10
net.ipv4.tcp_keepalive_time         = 300
net.ipv4.tcp_keepalive_intvl        = 15
net.ipv4.tcp_keepalive_probes       = 5
net.ipv4.tcp_slow_start_after_idle  = 0
net.ipv4.tcp_no_metrics_save        = 1
net.netfilter.nf_conntrack_max                     = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 10
net.netfilter.nf_conntrack_udp_timeout             = 60
net.netfilter.nf_conntrack_udp_timeout_stream      = 180
net.netfilter.nf_conntrack_generic_timeout         = 120
net.ipv6.conf.all.disable_ipv6                     = 1
net.ipv6.conf.default.disable_ipv6                 = 1
net.ipv6.conf.lo.disable_ipv6                      = 1
EOF
sysctl --system >/dev/null 2>&1 || \
  sysctl -p /etc/sysctl.d/99-internetincome.conf >/dev/null 2>&1 || true
rm -f /etc/sysctl.d/99-vps-optimize.conf 2>/dev/null || true
log "Kernel tuning xong"

#============================================================================
# PHẦN 9: LIMITS & SYSTEMD
#============================================================================
mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/99-nofile.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65536
DefaultTasksMax=infinity
EOF

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-ii-limit.conf <<'EOF'
[Journal]
SystemMaxUse=20M
RuntimeMaxUse=10M
Compress=yes
EOF
has_systemd && {
  systemctl daemon-reload            2>/dev/null || true
  systemctl restart systemd-journald 2>/dev/null || true
}

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF
timedatectl set-ntp true                  2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true

#============================================================================
# PHẦN 10: PATCH ENGAGEUB REPO
#============================================================================
log "Patch engageub: RAM ${CONTAINER_MEM}/${CONTAINER_SWAP} + restart..."
auto_patch_engageub_repo() {
  local ROOTS=(/opt /root /home /srv)
  [[ -n "$BASE_DIR" ]] && ROOTS+=("$BASE_DIR")

  while IFS= read -r sh_file; do
    local d; d=$(dirname "$sh_file")
    if [[ -f "${d}/properties.conf" ]]; then
      sed -i "s/^MAX_MEMORY=.*/MAX_MEMORY=${CONTAINER_MEM}/" \
        "${d}/properties.conf" 2>/dev/null || true
      grep -q "^MAX_MEMORY=" "${d}/properties.conf" || \
        echo "MAX_MEMORY=${CONTAINER_MEM}" >> "${d}/properties.conf"
    fi
    [[ -f "$sh_file" ]] || continue
    [[ -f "${sh_file}.orig" ]] || cp "$sh_file" "${sh_file}.orig"
    sed -i \
      "s/--memory=\"[0-9]*[a-z]*\"/--memory=\"${CONTAINER_MEM}\"/g" \
      "$sh_file" 2>/dev/null || true
    sed -i \
      "s/--memory-swap=\"[0-9]*[a-z]*\"/--memory-swap=\"${CONTAINER_SWAP}\"/g" \
      "$sh_file" 2>/dev/null || true
    grep -q "\-\-restart" "$sh_file" || \
      sed -i \
        "s/docker run -d/docker run -d --restart=unless-stopped/g" \
        "$sh_file" 2>/dev/null || true
    grep -q "\-\-memory" "$sh_file" || \
      sed -i \
        "s/docker run -d/docker run -d --memory=\"${CONTAINER_MEM}\" --memory-swap=\"${CONTAINER_SWAP}\"/g" \
        "$sh_file" 2>/dev/null || true
  done < <(find "${ROOTS[@]}" \
    -maxdepth 4 -name internetIncome.sh -type f 2>/dev/null | sort -u)
}
auto_patch_engageub_repo

#============================================================================
# PHẦN 11: DOCKER — CẤU HÌNH AN TOÀN
# FIX QUAN TRỌNG: Chỉ restart Docker khi daemon.json THỰC SỰ thay đổi
# Sau restart: revive TẤT CẢ container kể cả exited
#============================================================================
if ! command -v docker >/dev/null 2>&1; then
  log "Cài Docker..."
  curl -fsSL https://get.docker.com | sh
else
  log "Docker: $(docker --version)"
fi

has_systemd && {
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5s
StartLimitIntervalSec=60
StartLimitBurst=5
EOF
  systemctl daemon-reload 2>/dev/null || true
}

NEW_DAEMON="$(cat <<EOF
{
  "log-driver"               : "json-file",
  "log-opts"                 : { "max-size": "2m", "max-file": "2" },
  "dns"                      : ["8.8.8.8", "1.1.1.1", "9.9.9.9"],
  "max-concurrent-downloads" : ${CONCURRENT_DL},
  "live-restore"             : true,
  "userland-proxy"           : false,
  "no-new-privileges"        : false,
  "default-ulimits"          : {
    "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 },
    "nproc" : { "Name": "nproc",  "Hard": 65536, "Soft": 65536 }
  },
  "storage-driver"           : "overlay2"
}
EOF
)"

DOCKER_RESTARTED=0

if [[ -f /etc/docker/daemon.json ]] \
  && printf '%s\n' "$NEW_DAEMON" | cmp -s - /etc/docker/daemon.json; then
  log "daemon.json không đổi → SKIP restart Docker ✅"
else
  warn "daemon.json thay đổi → Cần restart Docker"
  warn "Container sẽ tạm dừng ~30s rồi tự phục hồi"

  # Lưu danh sách container đang chạy TRƯỚC khi restart
  RUNNING_BEFORE=$(docker ps -q 2>/dev/null | tr '\n' ' ')
  ALL_CONTAINERS=$(docker ps -aq 2>/dev/null | tr '\n' ' ')

  [[ -f /etc/docker/daemon.json ]] && \
    cp -f /etc/docker/daemon.json \
       "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
  printf '%s\n' "$NEW_DAEMON" > /etc/docker/daemon.json

  if has_systemd; then
    systemctl restart docker 2>/dev/null && DOCKER_RESTARTED=1 || \
      warn "Docker restart thất bại"
  fi
fi

has_systemd && systemctl enable docker >/dev/null 2>&1 || true

# FIX: Revive container đúng cách sau restart
if (( DOCKER_RESTARTED == 1 )); then
  log "Chờ Docker daemon ổn định (20s)..."
  sleep 20

  # Kiểm tra Docker đã thật sự sẵn sàng
  RETRY=0
  until docker info >/dev/null 2>&1 || (( RETRY >= 10 )); do
    sleep 3; RETRY=$(( RETRY + 1 ))
  done

  log "Revive tất cả container (throttle 1.5s/container)..."
  REVIVED=0
  FAILED_LIST=()

  # Revive từ containernames.txt (nguồn chính)
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    if docker start "$cid" >/dev/null 2>&1; then
      REVIVED=$(( REVIVED + 1 ))
    else
      FAILED_LIST+=("$cid")
    fi
    sleep 1.5
  done < <(find /opt /root /home /srv \
    -maxdepth 4 -name containernames.txt \
    -type f 2>/dev/null \
    | xargs cat 2>/dev/null \
    | sort -u)

  # Revive container exited còn sót
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    docker start "$cid" >/dev/null 2>&1 && \
      REVIVED=$(( REVIVED + 1 )) || \
      FAILED_LIST+=("$cid")
    sleep 1.5
  done < <(docker ps -aq -f status=exited 2>/dev/null)

  sleep 5
  RUNNING_AFTER=$(docker ps -q 2>/dev/null | wc -l)
  log "Revive xong: ${REVIVED} started | ${#FAILED_LIST[@]} failed | ${RUNNING_AFTER} running"

  if (( ${#FAILED_LIST[@]} > 0 )); then
    warn "Container thất bại (${#FAILED_LIST[@]}):"
    for c in "${FAILED_LIST[@]}"; do
      warn "  → $c: $(docker inspect -f '{{.State.Error}}' "$c" 2>/dev/null || echo 'unknown')"
    done
  fi
fi

#============================================================================
# PHẦN 12: VNSTAT
#============================================================================
MAIN_IF=$(ip route 2>/dev/null \
  | grep default | awk '{print $5}' | head -n1 || echo "")
if [[ -f /etc/vnstat.conf ]] && [[ -n "$MAIN_IF" ]]; then
  sed -i "s/Interface \".*\"/Interface \"${MAIN_IF}\"/" /etc/vnstat.conf
  grep -q 'ExcludeInterface' /etc/vnstat.conf || \
    echo 'ExcludeInterface "veth* docker0 tun* tap* br-*"' \
    >> /etc/vnstat.conf
  has_systemd && {
    systemctl enable --now vnstat 2>/dev/null || true
    systemctl restart vnstat      2>/dev/null || true
  }
fi

#============================================================================
# PHẦN 13-14: TOOLS (ii-dropcache, ii-watchdog)
#============================================================================
log "Cài ii-dropcache.sh..."
cat > /usr/local/bin/ii-dropcache.sh <<'DCEOF'
#!/usr/bin/env bash
THRESHOLD_MB=150
LOG=/var/log/ii-dropcache.log
RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}' || echo 999)
if (( RAM_AVAIL < THRESHOLD_MB )); then
  sync
  echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
  RAM_AFTER=$(free -m | awk '/^Mem:/{print $7}' || echo 0)
  echo "[$(date '+%F %T')] Drop: ${RAM_AVAIL}MB → ${RAM_AFTER}MB" >> "$LOG"
fi
[[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > 200 )) && \
  { tail -100 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"; }
DCEOF
chmod +x /usr/local/bin/ii-dropcache.sh

log "Cài ii-watchdog.sh..."
cat > /usr/local/bin/ii-watchdog.sh <<'WDEOF'
#!/usr/bin/env bash
LOG=/var/log/ii-watchdog.log
MAX_PER_RUN=10
THROTTLE=2

RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}' || echo 999)
if (( RAM_AVAIL < 80 )); then
  echo "[$(date '+%F %T')] RAM=${RAM_AVAIL}MB<80 — hoãn, drop cache" >> "$LOG"
  sync && echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
  exit 0
fi

EXITED=$(docker ps -aq -f status=exited 2>/dev/null || true)
[[ -z "$EXITED" ]] && exit 0

COUNT=0; FAIL=0
for cid in $EXITED; do
  if docker start "$cid" >/dev/null 2>&1; then
    COUNT=$(( COUNT + 1 ))
  else
    FAIL=$(( FAIL + 1 ))
    echo "[$(date '+%F %T')] FAIL: $cid" >> "$LOG"
  fi
  sleep "$THROTTLE"
  (( COUNT + FAIL >= MAX_PER_RUN )) && break
done

(( COUNT > 0 || FAIL > 0 )) && \
  echo "[$(date '+%F %T')] +${COUNT} revived | ${FAIL} failed | RAM=${RAM_AVAIL}MB" \
  >> "$LOG"

[[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > 1000 )) && \
  { tail -500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"; }
WDEOF
chmod +x /usr/local/bin/ii-watchdog.sh

#============================================================================
# PHẦN 15: ii-restart-all.sh
# FIX: Dùng date trực tiếp thay vì hàm ts() trong heredoc
#============================================================================
log "Cài ii-restart-all.sh..."
EXTRA_DIR="${BASE_DIR:-}"

cat > /usr/local/bin/ii-restart-all.sh <<RSEOF
#!/usr/bin/env bash
LOG=/var/log/ii-restart.log
ROOTS=(/opt /root /home /srv)
[[ -n "${EXTRA_DIR}" ]] && ROOTS+=("${EXTRA_DIR}")

{
echo "[\$(date '+%F %T')] ===== ii-restart-all START ====="

RAM_AVAIL=\$(free -m | awk '/^Mem:/{print \$7}' || echo 999)
if (( RAM_AVAIL < 100 )); then
  echo "[\$(date '+%F %T')] RAM=\${RAM_AVAIL}MB thấp — chạy watchdog thay thế"
  /usr/local/bin/ii-watchdog.sh
  exit 0
fi

mapfile -t FILES < <(
  find "\${ROOTS[@]}" -maxdepth 4 \
    -name containernames.txt -type f 2>/dev/null | sort -u
)
(( \${#FILES[@]} == 0 )) && {
  echo "[\$(date '+%F %T')] Không thấy folder engageub"
  exit 0
}

TOTAL=0
for cn in "\${FILES[@]}"; do
  d=\$(dirname "\$cn")
  [[ -f "\${d}/internetIncome.sh" ]] || continue
  n=\$(grep -c . "\$cn" 2>/dev/null || echo 0)
  TOTAL=\$(( TOTAL + n ))
  echo "[\$(date '+%F %T')] >>> \${d} (\${n} containers)..."
  while IFS= read -r cid; do
    [[ -n "\$cid" ]] || continue
    docker restart --time 10 "\$cid" >/dev/null 2>&1 || \
      docker start "\$cid" >/dev/null 2>&1 || true
    sleep 2
  done < "\$cn"
  sleep 5
done

sync && echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
RAM_AFTER=\$(free -m | awk '/^Mem:/{print \$7}' || echo 0)
STILL=\$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
echo "[\$(date '+%F %T')] DONE: \${TOTAL} ctrs | Exited: \${STILL} | RAM: \${RAM_AFTER}MB"
} >> "\$LOG" 2>&1

[[ -f "\$LOG" ]] && (( \$(wc -l < "\$LOG") > 2000 )) && \
  { tail -1000 "\$LOG" > "\${LOG}.tmp" && mv "\${LOG}.tmp" "\$LOG"; }
RSEOF
chmod +x /usr/local/bin/ii-restart-all.sh

#============================================================================
# PHẦN 16: LOGROTATE
#============================================================================
cat > /etc/logrotate.d/internetincome <<'EOF'
/var/log/ii-*.log {
  daily
  rotate 5
  compress
  delaycompress
  missingok
  notifempty
  size 10M
  copytruncate
}
EOF

#============================================================================
# PHẦN 17: CRON STACK
#============================================================================
install_cron_stack() {
  log "Cài cron: watchdog 3 phút + bảo trì 2 lần/ngày..."
  cat > /etc/cron.d/internetincome <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Watchdog: hồi sinh container exited mỗi 3 phút
*/3 * * * * root /usr/local/bin/ii-watchdog.sh

# Drop cache: mỗi 10 phút nếu RAM thấp
*/10 * * * * root /usr/local/bin/ii-dropcache.sh

# Bảo trì: 2 lần/ngày (traffic thấp nhất)
15 4  * * * root /usr/local/bin/ii-restart-all.sh
15 16 * * * root /usr/local/bin/ii-restart-all.sh

# Dọn image rác: Chủ nhật 05:30
30 5  * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1

# KSM persistent sau reboot
@reboot root sleep 10 && \
  echo 1 > /sys/kernel/mm/ksm/run && \
  echo 200 > /sys/kernel/mm/ksm/sleep_millisecs && \
  echo 4000 > /sys/kernel/mm/ksm/pages_to_scan && \
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
EOF
  chmod 644 /etc/cron.d/internetincome
  has_systemd && \
    systemctl enable --now cron 2>/dev/null || \
    systemctl enable --now crond 2>/dev/null || true
  log "Cron OK"
}
(( DO_CRON == 1 )) && install_cron_stack

#============================================================================
# PHẦN 18: ii-status.sh
#============================================================================
log "Cài ii-status.sh (6 mức cảnh báo)..."
cat > /usr/local/bin/ii-status.sh <<'SSEOF'
#!/usr/bin/env bash
ROOTS=("$@")
(( ${#ROOTS[@]} == 0 )) && ROOTS=(/opt /root /home /srv)

echo "==================== [INTERNETINCOME VPS AI-DIAGNOSTIC REPORT] ===================="
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "HOSTNAME     : $(hostname)"
echo "UPTIME       : $(uptime -p 2>/dev/null || uptime)"
echo "KERNEL/VIRT  : $(uname -r) ($(systemd-detect-virt 2>/dev/null || echo 'unknown'))"

echo -e "\n--- [1. CONTAINERS] ---"
found=0
while IFS= read -r cn; do
  d=$(dirname "$cn")
  [[ -f "${d}/internetIncome.sh" ]] || continue
  found=1
  total=$(grep -c . "$cn" 2>/dev/null || echo 0)
  running=0
  while IFS= read -r c; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$c" \
      2>/dev/null)" == "true" ]] && running=$(( running + 1 ))
  done < "$cn"
  missing=$(( total - running ))
  mark=""
  (( missing > 0 )) && mark=" <-- [WARNING: THIẾU ${missing}]"
  printf "  %-46s %4s/%-4s running%s\n" "$d" "$running" "$total" "$mark"
done < <(find "${ROOTS[@]}" \
  -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)
(( found == 0 )) && echo "  (Chưa thấy folder InternetIncome)"

RUNNING_CTRS=$(docker ps -q  2>/dev/null | wc -l)
TOTAL_CTRS=$(docker ps -aq   2>/dev/null | wc -l)
EXITED_CTRS=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
echo "  TOTAL: ${RUNNING_CTRS} running / ${TOTAL_CTRS} total (Exited: ${EXITED_CTRS})"

echo -e "\n--- [2. CPU] ---"
echo "  Load: $(cat /proc/loadavg 2>/dev/null || echo '?')"
top -bn1 2>/dev/null | grep "%Cpu" | awk '{print "  " $0}' || true

echo -e "\n--- [3. RAM & SWAP] ---"
free -h | awk \
  '/^Mem:/ {printf "  RAM : Total %s | Used %s | Free %s | Avail %s\n",$2,$3,$4,$7}
   /^Swap:/{printf "  Swap: Total %s | Used %s | Free %s\n",$2,$3,$4}'
echo "  Swap Devices:"
swapon --show 2>/dev/null | awk \
  'NR>1{printf "    %s (Pri=%s Used=%s)\n",$1,$5,$4}' || true
if [[ -f /sys/kernel/mm/ksm/pages_shared ]]; then
  P=$(cat /sys/kernel/mm/ksm/pages_shared 2>/dev/null || echo 0)
  echo "  KSM Saved: ~$(( P * 4 / 1024 ))MB (${P} pages)"
fi

echo -e "\n--- [4. SWAP PAGING] ---"
vmstat 1 2 2>/dev/null | tail -1 | awk \
  '{printf "  r=%s b=%s | si=%sKB/s so=%sKB/s | cs=%s/s wa=%s%%\n",
    $1,$2,$7,$8,$12,$16}'

echo -e "\n--- [5. PSI] ---"
[[ -f /proc/pressure/memory ]] && \
  cat /proc/pressure/memory | awk '{print "  " $0}' || \
  echo "  (PSI không hỗ trợ)"

echo -e "\n--- [6. NETWORK] ---"
ss -s 2>/dev/null | grep "^TCP:" | awk '{print "  " $0}' || true
CC=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CM=$(cat /proc/sys/net/netfilter/nf_conntrack_max   2>/dev/null || echo 524288)
PCT=$(( CC * 100 / CM ))
CMARK=""; (( PCT > 80 )) && CMARK=" ← WARNING >80%!"
echo "  Conntrack: ${CC}/${CM} (${PCT}%)${CMARK}"

echo -e "\n--- [7. STORAGE] ---"
df -h / | awk 'NR==2{printf "  Disk /: %s/%s (%s full)\n",$3,$2,$5}'
echo "  Inotify: $(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo '?')"

echo -e "\n--- [8. WATCHDOG LOG] ---"
if [[ -f /var/log/ii-watchdog.log ]]; then
  tail -5 /var/log/ii-watchdog.log | awk '{print "  " $0}'
else
  echo "  (Chưa có log)"
fi

echo -e "\n---------------- [AI DIAGNOSTIC SUMMARY] ----------------"
RAM_MB=$(free -m | awk '/^Mem:/{print $7}'  || echo 999)
SWAP_F=$(free -m | awk '/^Swap:/{print $4}' || echo 999)
SWAP_U=$(free -m | awk '/^Swap:/{print $3}' || echo 0)
PSI_F=$(grep "full" /proc/pressure/memory 2>/dev/null \
  | awk '{print $2}' | cut -d= -f2 || echo 0)
PSI_S=$(grep "some" /proc/pressure/memory 2>/dev/null \
  | awk '{print $2}' | cut -d= -f2 || echo 0)
PSI_I=${PSI_F%.*}
SI_SO=$(vmstat 1 1 2>/dev/null | tail -1 | awk '{print $7+$8}' || echo 0)
IDLE=$(top -bn1 2>/dev/null | grep "%Cpu" \
  | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]/ && $(i+1)~/id/) print $i}' \
  | head -1 | tr -d '%' || echo 100)
IDLE_I=${IDLE%.*}
LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)

printf "  %-14s: %s\n" "RAM Avail"   "${RAM_MB}MB"
printf "  %-14s: %sMB free / %sMB used\n" "Swap" "$SWAP_F" "$SWAP_U"
printf "  %-14s: full=%s%% some=%s%%\n" "PSI Memory" "$PSI_F" "$PSI_S"
printf "  %-14s: %s KB/s\n" "Swap I/O" "$SI_SO"
printf "  %-14s: %s%%\n" "CPU Idle" "$IDLE_I"
printf "  %-14s: %s\n" "Load 1min" "$LOAD1"
echo ""

if   (( RAM_MB < 30 )) && (( SWAP_F < 200 )); then
  S="💀 CRITICAL — RAM+Swap cạn! Crash ngay!"; A="docker stop bớt 50 container ngay!"
elif (( EXITED_CTRS > 5 )); then
  S="🔴 DEAD CONTAINERS — ${EXITED_CTRS} chết!"; A="sudo /usr/local/bin/ii-watchdog.sh"
elif (( PSI_I >= 15 )); then
  S="🔴 THRASHING — PSI=${PSI_F}% Swap=${SI_SO}KB/s"; A="Giảm container HOẶC nâng RAM"
elif (( PSI_I >= 5 )) || (( SI_SO > 5000 )); then
  S="🟡 PRESSURE — PSI=${PSI_F}% Swap=${SI_SO}KB/s"; A="Theo dõi thêm 30 phút"
elif (( RAM_MB < 120 )); then
  S="🟡 LOW RAM — ${RAM_MB}MB còn lại"; A="Watchdog đang bảo vệ. Monitor thêm"
elif (( IDLE_I < 20 )); then
  S="🟡 CPU BUSY — Idle=${IDLE_I}% Load=${LOAD1}"; A="Kiểm tra: top -b -n1 | head -20"
else
  S="🟢 HEALTHY — Hệ thống ổn định 24/7"; A="Không cần hành động gì"
fi

echo "  STATUS : ${S}"
echo "  ACTION : ${A}"
echo "=========================================================================="
SSEOF
chmod +x /usr/local/bin/ii-status.sh

#============================================================================
# HOÀN TẤT
#============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║      SETUP ULTRA STABLE HOTFIX — HOÀN TẤT ✅       ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  ii-status.sh      — Chẩn đoán 6 mức               ║"
echo "║  ii-watchdog.sh    — Revive container mỗi 3 phút    ║"
echo "║  ii-dropcache.sh   — Drop cache thông minh          ║"
echo "║  ii-restart-all.sh — Bảo trì 04:15 & 16:15         ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  sudo ii-status.sh                  — Kiểm tra      ║"
echo "║  tail -f /var/log/ii-watchdog.log   — Monitor live  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
sleep 3
/usr/local/bin/ii-status.sh || true

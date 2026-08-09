#!/usr/bin/env bash
#============================================================================
#  setup_vps.sh — ULTRA STABLE EDITION 2026
#  Mục tiêu: Chạy nhiều IPs nhất, ổn định 24/7, zero-touch, tăng income
#  Hỗ trợ: Honeygain, Traffmonetizer, Tun2proxy trên Ubuntu/Debian KVM
#
#  Cách dùng:
#    sudo bash setup_vps.sh                    # Cài đầy đủ
#    sudo bash setup_vps.sh --base-dir /path   # Thêm thư mục custom
#    sudo bash setup_vps.sh --no-cron          # Bỏ qua cài cron
#    sudo bash setup_vps.sh --no-pull          # Bỏ qua git pull
#============================================================================
set -Eeuo pipefail
trap 'echo -e "\033[1;31m[XX] LỖI tại dòng $LINENO — Thoát!\033[0m"' ERR

#============================================================================
# PHẦN 0: KHỞI TẠO — GIỚI HẠN HỆ THỐNG & THAM SỐ
#============================================================================
ulimit -n 1048576 2>/dev/null || true
sysctl -w fs.inotify.max_user_watches=2097152  >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_instances=65536  >/dev/null 2>&1 || true
sysctl -w fs.file-max=2097152                  >/dev/null 2>&1 || true

#--- Màu log ---
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

#--- Tham số dòng lệnh ---
BASE_DIR=""
DO_CRON=1
DO_PULL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-dir)    BASE_DIR="${2:-}"; shift 2 ;;
    --base-dir=*)  BASE_DIR="${1#*=}";  shift  ;;
    --no-cron)     DO_CRON=0;           shift  ;;
    --no-pull)     DO_PULL=0;           shift  ;;
    -h|--help)     grep '^#' "$0" | head -n 20; exit 0 ;;
    *) die "Tham số không hợp lệ: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Cần chạy bằng root: sudo bash $0"
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
# PHẦN 1: PHÁT HIỆN PHẦN CỨNG & TÍNH TOÁN THAM SỐ TỐI ƯU
#============================================================================
VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
IS_CONTAINER=0
case "$VIRT" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1 ;; esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)
DISK_FREE_MB=$(df -m / | awk 'NR==2{print $4}')

info "=========================================================="
info "  VPS: $(hostname) | RAM: ${MEM_MB}MB | CPU: ${CPU} cores"
info "  Virt: ${VIRT} | Disk free: ${DISK_FREE_MB}MB"
info "=========================================================="

#--- Tính ZRAM size = 75% RAM vật lý (tối đa 2GB) ---
ZRAM_MB=$(( MEM_MB * 3 / 4 ))
(( ZRAM_MB > 2048 )) && ZRAM_MB=2048
ZRAM_BYTES=$(( ZRAM_MB * 1024 * 1024 ))

#--- Tính Swap file size theo RAM ---
# Công thức: RAM nhỏ cần swap lớn hơn tỷ lệ
if   (( MEM_MB <= 1200 )); then
  TARGET_SWAP_MB=4096; SWAPPINESS=10; CONTAINER_MEM="35m"; CONTAINER_SWAP="90m"
elif (( MEM_MB <= 2500 )); then
  TARGET_SWAP_MB=4096; SWAPPINESS=10; CONTAINER_MEM="50m"; CONTAINER_SWAP="128m"
elif (( MEM_MB <= 5000 )); then
  TARGET_SWAP_MB=4096; SWAPPINESS=10; CONTAINER_MEM="70m"; CONTAINER_SWAP="160m"
elif (( MEM_MB <= 9000 )); then
  TARGET_SWAP_MB=6144; SWAPPINESS=15; CONTAINER_MEM="100m"; CONTAINER_SWAP="256m"
else
  TARGET_SWAP_MB=8192; SWAPPINESS=15; CONTAINER_MEM="128m"; CONTAINER_SWAP="320m"
fi

#--- Giới hạn swap theo disk trống (giữ lại 3GB cho hệ thống) ---
MAX_SAFE_SWAP=$(( DISK_FREE_MB - 3072 ))
(( MAX_SAFE_SWAP < 512 ))            && MAX_SAFE_SWAP=512
(( TARGET_SWAP_MB > MAX_SAFE_SWAP )) && TARGET_SWAP_MB=$MAX_SAFE_SWAP

#--- Tính tham số network theo CPU ---
if   (( CPU <= 2 )); then
  CONCURRENT_DL=3; SYN_BACKLOG=8192;  SOMAXCONN=32768
elif (( CPU <= 4 )); then
  CONCURRENT_DL=5; SYN_BACKLOG=16384; SOMAXCONN=65535
else
  CONCURRENT_DL=8; SYN_BACKLOG=32768; SOMAXCONN=65535
fi

#--- min_free_kbytes = 6% RAM (giữ vùng đệm RAM tối thiểu) ---
MIN_FREE_KB=$(( MEM_MB * 1024 * 6 / 100 ))
(( MIN_FREE_KB < 65536  )) && MIN_FREE_KB=65536
(( MIN_FREE_KB > 262144 )) && MIN_FREE_KB=262144

info "  Cấu hình: Swap=${TARGET_SWAP_MB}MB | ZRAM=${ZRAM_MB}MB"
info "  Container limit: MEM=${CONTAINER_MEM} SWAP=${CONTAINER_SWAP}"
info "  Swappiness=${SWAPPINESS} | min_free=${MIN_FREE_KB}KB"

#============================================================================
# PHẦN 2: ZRAM — NÉN RAM TỐC ĐỘ CAO (ƯU TIÊN TRƯỚC SWAP ĐĨA)
#============================================================================
log "Cấu hình ZRAM ${ZRAM_MB}MB (lz4) — swap ảo tốc độ GB/s..."

setup_zram() {
  # Tắt zram cũ nếu có
  swapoff /dev/zram0 2>/dev/null || true
  # Reset về 0 trước khi cấu hình lại
  if [[ -f /sys/block/zram0/reset ]]; then
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    sleep 1
  fi

  # Nạp module
  modprobe zram num_devices=1 2>/dev/null || true
  sleep 1

  if [[ ! -b /dev/zram0 ]]; then
    warn "Không tạo được /dev/zram0 → bỏ qua ZRAM"
    return
  fi

  # Chọn thuật toán nén: lz4 > lzo-rle > lzo (theo thứ tự ưu tiên)
  ALGO=""
  for a in lz4 lzo-rle lzo; do
    if grep -qw "$a" /sys/block/zram0/comp_algorithm 2>/dev/null; then
      ALGO="$a"; break
    fi
  done
  [[ -n "$ALGO" ]] && echo "$ALGO" > /sys/block/zram0/comp_algorithm 2>/dev/null || true

  echo "$ZRAM_BYTES" > /sys/block/zram0/disksize 2>/dev/null || true
  mkswap /dev/zram0 >/dev/null 2>&1 || true

  # Priority 100: dùng ZRAM TRƯỚC swap đĩa (giảm I/O wait)
  swapon -p 100 /dev/zram0 2>/dev/null && \
    log "ZRAM ${ZRAM_MB}MB (${ALGO}) ready — Priority 100" || \
    warn "swapon ZRAM thất bại"
}

if (( IS_CONTAINER == 0 )); then
  if swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
    # Kiểm tra size có đúng không
    CURR_ZRAM=$(swapon --show=SIZE --noheadings /dev/zram0 2>/dev/null \
      | awk '{gsub(/[^0-9]/,"",$1); print int($1/1024)}' || echo 0)
    if (( CURR_ZRAM < ZRAM_MB - 100 )); then
      warn "ZRAM hiện tại ${CURR_ZRAM}MB < ${ZRAM_MB}MB → rebuild"
      setup_zram
    else
      log "ZRAM ${CURR_ZRAM}MB đang hoạt động → giữ nguyên"
    fi
  else
    setup_zram
  fi
fi

#============================================================================
# PHẦN 3: SWAP FILE — ĐỆM AN TOÀN KHI ZRAM ĐẦY
#============================================================================
log "Cấu hình Swap đĩa ${TARGET_SWAP_MB}MB (Priority 0 — dự phòng)..."

setup_swapfile() {
  local file="$1" size_mb="$2"
  log "Tạo ${file} ${size_mb}MB..."
  if ! fallocate -l "${size_mb}M" "$file" 2>/dev/null; then
    dd if=/dev/zero of="$file" bs=1M count="$size_mb" status=none
  fi
  chmod 600 "$file"
  mkswap "$file" >/dev/null 2>&1

  # Priority 0: swap đĩa dùng SAU ZRAM
  if swapon -p 0 "$file" 2>/dev/null; then
    grep -q "^${file}" /etc/fstab 2>/dev/null || \
      echo "${file} none swap sw,pri=0 0 0" >> /etc/fstab
    log "Swap ${file} ${size_mb}MB ready — Priority 0"
  else
    rm -f "$file"
    warn "swapon ${file} thất bại"
  fi
}

if (( IS_CONTAINER == 0 )); then
  CURR_SWAPFILE_MB=$(free -m 2>/dev/null \
    | awk '/^Swap:/{print $2}' || echo 0)
  ZRAM_MB_ACTUAL=$(swapon --show=SIZE --noheadings /dev/zram0 2>/dev/null \
    | awk '{gsub(/[^0-9]/,"",$1); print int($1/1024)}' || echo 0)
  DISK_SWAP_MB=$(( CURR_SWAPFILE_MB - ZRAM_MB_ACTUAL ))
  (( DISK_SWAP_MB < 0 )) && DISK_SWAP_MB=0

  if (( DISK_SWAP_MB >= TARGET_SWAP_MB - 256 )) \
    && (( DISK_SWAP_MB <= TARGET_SWAP_MB + 1024 )); then
    log "Swap đĩa ${DISK_SWAP_MB}MB phù hợp → giữ nguyên"
  else
    # Xác định file swap đĩa chưa dùng
    SWAPFILE_TARGET="/swapfile"
    if [[ -f /swapfile ]] \
      && swapon --show=NAME 2>/dev/null | grep -q "^/swapfile$"; then
      # /swapfile đang dùng, kiểm tra /swapfile2
      if [[ ! -f /swapfile2 ]]; then
        SWAPFILE_TARGET="/swapfile2"
      else
        SWAPFILE_TARGET="/swapfile"  # rebuild
        SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')
        RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
        if (( SWAP_USED < RAM_AVAIL - 300 )); then
          swapoff /swapfile 2>/dev/null || true
          sed -i '\|^/swapfile |d' /etc/fstab 2>/dev/null || true
          rm -f /swapfile
        else
          warn "Swap đang dùng ${SWAP_USED}MB, RAM chỉ còn ${RAM_AVAIL}MB → giữ nguyên"
          SWAPFILE_TARGET=""
        fi
      fi
    fi
    [[ -n "$SWAPFILE_TARGET" ]] && \
      setup_swapfile "$SWAPFILE_TARGET" "$TARGET_SWAP_MB"
  fi
fi

#============================================================================
# PHẦN 4: KSM — GỘP RAM NHÂN KERNEL (TIẾT KIỆM 20-40% RAM CHO CONTAINER)
#============================================================================
log "Kích hoạt KSM — gộp RAM giống nhau giữa ${CPU:+}200+ container..."

if [[ -f /sys/kernel/mm/ksm/run ]]; then
  echo 1    > /sys/kernel/mm/ksm/run
  echo 200  > /sys/kernel/mm/ksm/sleep_millisecs  # quét mỗi 200ms (nhanh 2.5x)
  echo 4000 > /sys/kernel/mm/ksm/pages_to_scan    # 4000 page/lần (mạnh 4x)
  # Gộp RAM across NUMA nodes nếu có
  echo 1 > /sys/kernel/mm/ksm/merge_across_nodes 2>/dev/null || true
  log "KSM active: 200ms interval, 4000 pages/scan"

  # Persistent qua reboot
  cat > /etc/rc.local <<'RCEOF'
#!/usr/bin/env bash
# KSM & THP persistent settings
echo 1    > /sys/kernel/mm/ksm/run              2>/dev/null || true
echo 200  > /sys/kernel/mm/ksm/sleep_millisecs  2>/dev/null || true
echo 4000 > /sys/kernel/mm/ksm/pages_to_scan   2>/dev/null || true
echo 1    > /sys/kernel/mm/ksm/merge_across_nodes 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
exit 0
RCEOF
  chmod +x /etc/rc.local
  # Kích hoạt rc.local service nếu có systemd
  if has_systemd; then
    systemctl enable rc-local 2>/dev/null || true
    systemctl start  rc-local 2>/dev/null || true
  fi
fi

# Tắt Transparent Hugepage — gây lag cho nhiều container nhỏ
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true

#============================================================================
# PHẦN 5: DỌN DẸP BLOATWARE & CÀI PACKAGES CẦN THIẾT
#============================================================================
log "Dọn dẹp dịch vụ OS ngốn RAM (snapd, multipathd, udisks2)..."
if has_systemd; then
  for svc in snapd multipathd udisks2 accountsservice \
             apport motd-news bluetooth cups avahi-daemon; do
    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    systemctl mask    "$svc" 2>/dev/null || true
  done
fi
apt-get purge -y snapd 2>/dev/null || true
rm -rf /var/cache/snapd/ /var/lib/snapd/ 2>/dev/null || true

log "Dọn Watchtower trùng lặp..."
docker ps -a --format '{{.Names}}' 2>/dev/null \
  | grep "internetincomewatchtower" \
  | xargs -r docker rm -f >/dev/null 2>&1 || true

export DEBIAN_FRONTEND=noninteractive
# Tắt needrestart hỏi restart
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

log "apt update + upgrade..."
apt-get update  -y -qq
apt-get upgrade -y -qq || true
apt-get install -y -qq --no-install-recommends \
  curl wget git unzip jq bc ca-certificates uuid-runtime \
  cron logrotate net-tools earlyoom vnstat nload \
  iproute2 iptables ipset dnsutils

apt-get autoremove -y -qq >/dev/null 2>&1 || true
apt-get clean         -qq >/dev/null 2>&1 || true

#============================================================================
# PHẦN 6: EARLYOOM — BẢO VỆ CHỐNG OOM-KILL DOCKER DAEMON
#============================================================================
log "Cấu hình EarlyOOM — bảo vệ dockerd + containerd khỏi bị kill..."

cat > /etc/default/earlyoom <<'EOF'
# Kích hoạt khi RAM còn 5% VÀ Swap còn 10%
# KHÔNG BAO GIỜ kill: sshd, systemd, cron, dockerd, containerd
# Ưu tiên kill: process nhỏ có thể tự restart (honeygain, traffmonetizer)
EARLYOOM_ARGS="-m 5 -s 10 -r 60 \
  --avoid '(sshd|systemd|cron|dockerd|containerd|bash)' \
  --prefer '(honeygain|traffmonetizer|tun2proxy)'"
EOF

if has_systemd; then
  systemctl enable --now earlyoom >/dev/null 2>&1 || true
  systemctl restart earlyoom      >/dev/null 2>&1 || true
fi

#============================================================================
# PHẦN 7: DNS 4 LỚP — KẾT NỐI NHANH & ĐỦ DỰ PHÒNG
#============================================================================
log "Cấu hình DNS 4 lớp (Google + Cloudflare + Quad9)..."

if has_systemd && systemctl list-unit-files 2>/dev/null \
  | grep -q '^systemd-resolved'; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
fi

# Chống ghi đè resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf

cat > /etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
nameserver 9.9.9.9
nameserver 1.0.0.1
options timeout:2 attempts:3 rotate
EOF

# Khóa file chống bị ghi đè bởi DHCP/NetworkManager
chattr +i /etc/resolv.conf 2>/dev/null || true

#============================================================================
# PHẦN 8: KERNEL TUNING — TCP BBR + MEMORY + NETWORK CHO 200+ CONTAINER
#============================================================================
log "Kernel tuning: TCP BBR + memory pressure + conntrack..."

modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr      2>/dev/null || true

cat > /etc/sysctl.d/99-internetincome.conf <<EOF
#========================================================
# INTERNETINCOME ULTRA STABLE KERNEL SETTINGS 2026
#========================================================

#--- TCP BBR: Tăng tốc băng thông proxy ---
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr

#--- IP Forward: BẮT BUỘC cho Tun2proxy/engageub ---
net.ipv4.ip_forward             = 1

#--- TCP Buffer: Chuẩn, tránh xé nhỏ gói proxy ---
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144

#--- Memory Management: Ưu tiên RAM, hạn chế swap ---
vm.swappiness            = ${SWAPPINESS}
vm.min_free_kbytes       = ${MIN_FREE_KB}
vm.vfs_cache_pressure    = 150
vm.dirty_background_ratio = 5
vm.dirty_ratio           = 15
vm.overcommit_memory     = 1
vm.overcommit_ratio      = 50
vm.page-cluster          = 0

#--- Inotify: BẮT BUỘC cho 200+ container ---
fs.file-max                      = 2097152
fs.inotify.max_user_instances    = 65536
fs.inotify.max_user_watches      = 2097152
fs.inotify.max_queued_events     = 65536

#--- Network Stack: Chống nghẽn kết nối proxy ---
net.core.somaxconn               = ${SOMAXCONN}
net.core.netdev_max_backlog      = 65535
net.ipv4.tcp_max_syn_backlog     = ${SYN_BACKLOG}
net.ipv4.ip_local_port_range     = 1024 65535
net.ipv4.tcp_tw_reuse            = 1
net.ipv4.tcp_fin_timeout         = 10
net.ipv4.tcp_keepalive_time      = 300
net.ipv4.tcp_keepalive_intvl     = 15
net.ipv4.tcp_keepalive_probes    = 5
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save     = 1
net.ipv4.tcp_moderate_rcvbuf     = 1

#--- Conntrack: 512K streams cho 200+ container ---
net.netfilter.nf_conntrack_max               = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait   = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait  = 10
net.netfilter.nf_conntrack_udp_timeout             = 60
net.netfilter.nf_conntrack_udp_timeout_stream      = 180
net.netfilter.nf_conntrack_generic_timeout         = 120

#--- IPv6: Tắt để tránh xung đột proxy ---
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6      = 1
EOF

# Áp dụng ngay lập tức
sysctl --system >/dev/null 2>&1 || \
  sysctl -p /etc/sysctl.d/99-internetincome.conf >/dev/null 2>&1 || true

# Xóa file cũ nếu tồn tại
rm -f /etc/sysctl.d/99-vps-optimize.conf 2>/dev/null || true

log "Kernel tuning xong"

#============================================================================
# PHẦN 9: GIỚI HẠN FILE & SYSTEMD
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

# Giới hạn journal log (không ngốn disk)
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-ii-limit.conf <<'EOF'
[Journal]
SystemMaxUse=20M
RuntimeMaxUse=10M
Compress=yes
EOF

if has_systemd; then
  systemctl daemon-reload              2>/dev/null || true
  systemctl restart systemd-journald   2>/dev/null || true
fi

# APT: tắt auto-reboot
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

# Timezone
timedatectl set-ntp true             2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true

#============================================================================
# PHẦN 10: PATCH ENGAGEUB REPO — KHÓA RAM + RESTART FLAG
#============================================================================
log "Patch engageub repo: khóa RAM ${CONTAINER_MEM}/${CONTAINER_SWAP} + restart flag..."

auto_patch_engageub_repo() {
  local ROOTS=(/opt /root /home /srv)
  [[ -n "$BASE_DIR" ]] && ROOTS+=("$BASE_DIR")

  while IFS= read -r sh_file; do
    local d
    d=$(dirname "$sh_file")

    # Patch properties.conf
    if [[ -f "${d}/properties.conf" ]]; then
      sed -i "s/^MAX_MEMORY=.*/MAX_MEMORY=${CONTAINER_MEM}/" \
        "${d}/properties.conf" 2>/dev/null || true
      grep -q "^MAX_MEMORY=" "${d}/properties.conf" || \
        echo "MAX_MEMORY=${CONTAINER_MEM}" >> "${d}/properties.conf"
    fi

    [[ -f "$sh_file" ]] || continue

    # Backup lần đầu
    [[ -f "${sh_file}.orig" ]] || cp "$sh_file" "${sh_file}.orig"

    # Patch --memory
    sed -i \
      "s/--memory=\"[0-9]*[a-z]*\"/--memory=\"${CONTAINER_MEM}\"/g" \
      "$sh_file" 2>/dev/null || true

    # Patch --memory-swap
    sed -i \
      "s/--memory-swap=\"[0-9]*[a-z]*\"/--memory-swap=\"${CONTAINER_SWAP}\"/g" \
      "$sh_file" 2>/dev/null || true

    # Thêm --restart=unless-stopped nếu chưa có
    if ! grep -q "\-\-restart" "$sh_file"; then
      sed -i \
        "s/docker run -d/docker run -d --restart=unless-stopped/g" \
        "$sh_file" 2>/dev/null || true
    fi

    # Thêm --memory nếu chưa có
    if ! grep -q "\-\-memory" "$sh_file"; then
      sed -i \
        "s/docker run -d/docker run -d --memory=\"${CONTAINER_MEM}\" --memory-swap=\"${CONTAINER_SWAP}\"/g" \
        "$sh_file" 2>/dev/null || true
    fi

  done < <(find "${ROOTS[@]}" \
    -maxdepth 4 -name internetIncome.sh -type f 2>/dev/null | sort -u)
}

auto_patch_engageub_repo

#============================================================================
# PHẦN 11: DOCKER — CÀI ĐẶT & CẤU HÌNH TỐI ƯU
#============================================================================
if ! command -v docker >/dev/null 2>&1; then
  log "Cài Docker..."
  curl -fsSL https://get.docker.com | sh
  log "Docker installed: $(docker --version)"
else
  log "Docker sẵn có: $(docker --version)"
fi

# Docker daemon tự restart khi crash
if has_systemd; then
  mkdir -p /etc/systemd/system/docker.service.d
  cat > /etc/systemd/system/docker.service.d/override.conf <<'EOF'
[Service]
Restart=always
RestartSec=5s
StartLimitIntervalSec=60
StartLimitBurst=5
EOF
  systemctl daemon-reload 2>/dev/null || true
fi

# daemon.json tối ưu
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
    "nofile" : { "Name": "nofile", "Hard": 65536, "Soft": 65536 },
    "nproc"  : { "Name": "nproc",  "Hard": 65536, "Soft": 65536 }
  },
  "storage-driver"           : "overlay2"
}
EOF
)"

DOCKER_RESTARTED=0
if [[ -f /etc/docker/daemon.json ]] \
  && printf '%s\n' "$NEW_DAEMON" | cmp -s - /etc/docker/daemon.json; then
  log "daemon.json không thay đổi → KHÔNG restart Docker"
else
  [[ -f /etc/docker/daemon.json ]] && \
    cp -f /etc/docker/daemon.json \
       "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
  printf '%s\n' "$NEW_DAEMON" > /etc/docker/daemon.json
  if has_systemd; then
    systemctl restart docker 2>/dev/null && DOCKER_RESTARTED=1 || \
      warn "Docker restart thất bại"
  fi
fi

if has_systemd; then
  systemctl enable docker >/dev/null 2>&1 || true
fi

# Revive container sau khi restart Docker daemon
if (( DOCKER_RESTARTED == 1 )); then
  log "Chờ Docker ổn định (15s)..."
  sleep 15

  log "Revive container từ containernames.txt (2s throttle/container)..."
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    docker start "$cid" >/dev/null 2>&1 || true
    sleep 2
  done < <(find /opt /root /home /srv \
    -maxdepth 4 -name containernames.txt -type f \
    -exec cat {} + 2>/dev/null | sort -u)

  sleep 5

  # Revive bất kỳ container exited nào còn sót
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    docker start "$cid" >/dev/null 2>&1 || true
    sleep 2
  done < <(docker ps -aq -f status=exited 2>/dev/null)

  log "Revive container xong"
fi

#============================================================================
# PHẦN 12: VNSTAT — GIÁM SÁT BĂNG THÔNG
#============================================================================
MAIN_IF=$(ip route 2>/dev/null \
  | grep default | awk '{print $5}' | head -n1 || echo "")

if [[ -f /etc/vnstat.conf ]] && [[ -n "$MAIN_IF" ]]; then
  sed -i "s/Interface \".*\"/Interface \"${MAIN_IF}\"/" /etc/vnstat.conf
  grep -q 'ExcludeInterface' /etc/vnstat.conf || \
    echo 'ExcludeInterface "veth* docker0 tun* tap* br-*"' \
    >> /etc/vnstat.conf
  if has_systemd; then
    systemctl enable --now vnstat 2>/dev/null || true
    systemctl restart vnstat      2>/dev/null || true
  fi
fi

#============================================================================
# PHẦN 13: CÔNG CỤ ii-dropcache.sh — DROP CACHE THÔNG MINH
#============================================================================
log "Cài ii-dropcache.sh — drop cache chỉ khi RAM thực sự thấp..."

cat > /usr/local/bin/ii-dropcache.sh <<'DCEOF'
#!/usr/bin/env bash
#--- Drop pagecache CHỈ KHI RAM avail < ngưỡng an toàn ---
THRESHOLD_MB=150
LOG=/var/log/ii-dropcache.log
ts() { date '+%F %T'; }

RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}' || echo 999)

if (( RAM_AVAIL < THRESHOLD_MB )); then
  # echo 1: chỉ drop pagecache (an toàn cho Docker filesystem)
  # KHÔNG dùng echo 3 (xóa dentries/inodes → làm container lag)
  sync
  echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
  RAM_AFTER=$(free -m | awk '/^Mem:/{print $7}' || echo 0)
  echo "[$(ts)] Drop cache: ${RAM_AVAIL}MB → ${RAM_AFTER}MB avail" >> "$LOG"
fi

# Rotate log (giữ 100 dòng)
if [[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > 200 )); then
  tail -100 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
DCEOF
chmod +x /usr/local/bin/ii-dropcache.sh

#============================================================================
# PHẦN 14: CÔNG CỤ ii-watchdog.sh — HỒI SINH CONTAINER THÔNG MINH
#============================================================================
log "Cài ii-watchdog.sh — hồi sinh container exited an toàn..."

cat > /usr/local/bin/ii-watchdog.sh <<'WDEOF'
#!/usr/bin/env bash
#============================================================
# ii-watchdog.sh: Phát hiện + hồi sinh container exited
# - Throttle 2s/container (tránh RAM spike)
# - Giới hạn 10 container/lần (tránh flood)
# - Hoãn nếu RAM < 80MB (tránh OOM vòng)
# - Ghi log súc tích
#============================================================
LOG=/var/log/ii-watchdog.log
MAX_PER_RUN=10
THROTTLE_SEC=2
ts() { date '+%F %T'; }

# Kiểm tra RAM trước khi hành động
RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}' || echo 999)
if (( RAM_AVAIL < 80 )); then
  echo "[$(ts)] RAM=${RAM_AVAIL}MB < 80MB — Hoãn restart, drop cache nhẹ" \
    >> "$LOG"
  sync && echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
  exit 0
fi

# Lấy danh sách container exited
EXITED=$(docker ps -aq -f status=exited 2>/dev/null || true)
[[ -z "$EXITED" ]] && exit 0

COUNT=0
FAILED=0
for cid in $EXITED; do
  NAME=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null \
    | tr -d '/' || echo "$cid")

  if docker start "$cid" >/dev/null 2>&1; then
    COUNT=$(( COUNT + 1 ))
  else
    FAILED=$(( FAILED + 1 ))
    echo "[$(ts)] FAIL start: ${NAME}" >> "$LOG"
  fi

  sleep "$THROTTLE_SEC"
  (( COUNT + FAILED >= MAX_PER_RUN )) && break
done

if (( COUNT > 0 )) || (( FAILED > 0 )); then
  echo "[$(ts)] Watchdog: +${COUNT} revived | ${FAILED} failed | RAM=${RAM_AVAIL}MB" \
    >> "$LOG"
fi

# Rotate log (giữ 500 dòng)
if [[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > 1000 )); then
  tail -500 "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
fi
WDEOF
chmod +x /usr/local/bin/ii-watchdog.sh

#============================================================================
# PHẦN 15: CÔNG CỤ ii-restart-all.sh — BẢO TRÌ 2 LẦN/NGÀY
#============================================================================
log "Cài ii-restart-all.sh — bảo trì định kỳ an toàn..."

EXTRA_DIR_ESCAPED="${BASE_DIR//\//\\/}"

cat > /usr/local/bin/ii-restart-all.sh <<RSEOF
#!/usr/bin/env bash
#============================================================
# ii-restart-all.sh: Bảo trì định kỳ — restart cuốn chiếu
# - 2s throttle/container + 5s nghỉ giữa mỗi folder
# - Drop pagecache nhẹ (echo 1) sau khi xong
# - Không restart nếu RAM quá thấp
#============================================================
LOG=/var/log/ii-restart.log
ROOTS=(/opt /root /home /srv)
[[ -n "${EXTRA_DIR_ESCAPED}" ]] && ROOTS+=("${BASE_DIR}")
ts() { date '+%F %T'; }

{
echo "[$(ts)] ===== ii-restart-all START ====="

RAM_AVAIL=\$(free -m | awk '/^Mem:/{print \$7}' || echo 999)
if (( RAM_AVAIL < 100 )); then
  echo "[$(ts)] RAM=\${RAM_AVAIL}MB tooLow — abort restart, chạy watchdog thay thế"
  /usr/local/bin/ii-watchdog.sh
  exit 0
fi

mapfile -t FILES < <(
  find "\${ROOTS[@]}" -maxdepth 4 \
    -name containernames.txt -type f 2>/dev/null | sort -u
)

if (( \${#FILES[@]} == 0 )); then
  echo "[$(ts)] Không thấy folder engageub nào"
  exit 0
fi

TOTAL=0
for cn in "\${FILES[@]}"; do
  d=\$(dirname "\$cn")
  [[ -f "\${d}/internetIncome.sh" ]] || continue

  n=\$(grep -c . "\$cn" 2>/dev/null || echo 0)
  TOTAL=\$(( TOTAL + n ))
  echo "[$(ts)] >>> \${d} (\${n} containers)..."

  while IFS= read -r cid; do
    [[ -n "\$cid" ]] || continue
    # Dùng restart thay vì stop+start để giữ trạng thái mạng
    docker restart --time 10 "\$cid" >/dev/null 2>&1 || \
      docker start "\$cid" >/dev/null 2>&1 || true
    sleep 2
  done < "\$cn"

  sleep 5  # Nghỉ giữa các folder
done

# Drop pagecache nhẹ
sync && echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
RAM_AFTER=\$(free -m | awk '/^Mem:/{print \$7}' || echo 0)

STILL=\$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
echo "[$(ts)] ===== DONE: \${TOTAL} containers | Exited còn: \${STILL} | RAM: \${RAM_AFTER}MB ====="
} >> "\$LOG" 2>&1

# Rotate log
if [[ -f "\$LOG" ]] && (( \$(wc -l < "\$LOG") > 2000 )); then
  tail -1000 "\$LOG" > "\${LOG}.tmp" && mv "\${LOG}.tmp" "\$LOG"
fi
RSEOF
chmod +x /usr/local/bin/ii-restart-all.sh

#============================================================================
# PHẦN 16: LOGROTATE — QUẢN LÝ LOG TỰ ĐỘNG
#============================================================================
log "Cài logrotate cho ii-*.log..."

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
# PHẦN 17: CRON STACK — TỰ ĐỘNG 24/7 ZERO-TOUCH
#============================================================================
install_cron_stack() {
  log "Cài cron stack: watchdog 3 phút + bảo trì 2 lần/ngày..."

  cat > /etc/cron.d/internetincome <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

#--- WATCHDOG: hồi sinh container exited mỗi 3 phút ---
*/3 * * * * root /usr/local/bin/ii-watchdog.sh

#--- DROP CACHE: chỉ khi RAM thấp, mỗi 10 phút ---
*/10 * * * * root /usr/local/bin/ii-dropcache.sh

#--- BẢO TRÌ: restart cuốn chiếu 2 lần/ngày ---
15 4  * * * root /usr/local/bin/ii-restart-all.sh
15 16 * * * root /usr/local/bin/ii-restart-all.sh

#--- DỌN IMAGE RÁC: Chủ nhật 05:30 ---
30 5  * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1

#--- KSM TUNING: Đảm bảo KSM luôn active sau reboot ---
@reboot root echo 1 > /sys/kernel/mm/ksm/run && \
             echo 200 > /sys/kernel/mm/ksm/sleep_millisecs && \
             echo 4000 > /sys/kernel/mm/ksm/pages_to_scan
EOF
  chmod 644 /etc/cron.d/internetincome

  if has_systemd; then
    systemctl enable --now cron >/dev/null 2>&1 || \
    systemctl enable --now crond >/dev/null 2>&1 || true
  else
    service cron start 2>/dev/null || true
  fi

  log "Cron stack đã cài xong"
}

(( DO_CRON == 1 )) && install_cron_stack

#============================================================================
# PHẦN 18: ii-status.sh — BÁO CÁO CHẨN ĐOÁN AI CHÍNH XÁC
#============================================================================
log "Cài ii-status.sh — báo cáo chẩn đoán 5 mức cảnh báo..."

cat > /usr/local/bin/ii-status.sh <<'SSEOF'
#!/usr/bin/env bash
#============================================================
# ii-status.sh: Báo cáo chẩn đoán hệ thống InternetIncome
# Gọi: sudo ii-status.sh [thư_mục_thêm ...]
#============================================================
ROOTS=("$@")
(( ${#ROOTS[@]} == 0 )) && ROOTS=(/opt /root /home /srv)

SEP="===================="

echo "${SEP} [INTERNETINCOME VPS AI-DIAGNOSTIC REPORT] ${SEP}"
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "HOSTNAME     : $(hostname)"
echo "UPTIME       : $(uptime -p 2>/dev/null || uptime)"
echo "KERNEL/VIRT  : $(uname -r) ($(systemd-detect-virt 2>/dev/null || echo 'unknown'))"

#--- [1] Containers ---
echo -e "\n--- [1. INTERNETINCOME FOLDERS & CONTAINERS] ---"
found=0
WARN_COUNT=0
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
  if (( missing > 0 )); then
    mark=" <-- [WARNING: THIẾU ${missing} CONTAINER]"
    WARN_COUNT=$(( WARN_COUNT + missing ))
  fi
  printf "  %-46s %4s/%-4s running%s\n" \
    "$d" "$running" "$total" "$mark"
done < <(find "${ROOTS[@]}" \
  -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)
(( found == 0 )) && echo "  (Chưa thấy folder InternetIncome nào)"

RUNNING_CTRS=$(docker ps -q  2>/dev/null | wc -l)
TOTAL_CTRS=$(docker ps -aq   2>/dev/null | wc -l)
EXITED_CTRS=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
echo "  TOTAL: ${RUNNING_CTRS} running / ${TOTAL_CTRS} total (Exited: ${EXITED_CTRS})"

#--- [2] CPU ---
echo -e "\n--- [2. CPU LOAD & I/O WAIT] ---"
echo "  Load Average : $(cat /proc/loadavg 2>/dev/null || echo '?')"
top -bn1 2>/dev/null | grep "%Cpu" | awk '{print "  " $0}' || true

#--- [3] RAM & Swap ---
echo -e "\n--- [3. RAM, ZRAM & SWAP] ---"
free -h | awk \
  '/^Mem:/ {printf "  RAM  : Total %s | Used %s | Free %s | Avail %s\n",
    $2,$3,$4,$7}
   /^Swap:/{printf "  Swap : Total %s | Used %s | Free %s\n",$2,$3,$4}'
echo "  Active Swap Devices:"
swapon --show 2>/dev/null | awk \
  'NR>1{printf "    - %s (%s, Priority %s, Used %s)\n",$1,$3,$5,$4}' || true

# KSM stats
if [[ -f /sys/kernel/mm/ksm/pages_shared ]]; then
  PAGES_SHARED=$(cat /sys/kernel/mm/ksm/pages_shared 2>/dev/null || echo 0)
  SAVED_MB=$(( PAGES_SHARED * 4 / 1024 ))
  echo "  KSM Saved    : ~${SAVED_MB}MB (${PAGES_SHARED} pages merged)"
fi

#--- [4] Swap Paging ---
echo -e "\n--- [4. SWAP PAGING (si/so) & RUN QUEUE] ---"
vmstat 1 2 2>/dev/null | tail -n 1 | awk \
  '{printf "  r=%s | b=%s | si=%s KB/s | so=%s KB/s | cs=%s/s | wa=%s%%\n",
    $1,$2,$7,$8,$12,$16}'

#--- [5] PSI ---
echo -e "\n--- [5. MEMORY PRESSURE (PSI)] ---"
if [[ -f /proc/pressure/memory ]]; then
  cat /proc/pressure/memory | awk '{print "  " $0}'
else
  echo "  (PSI không được hỗ trợ bởi kernel này)"
fi

#--- [6] Network ---
echo -e "\n--- [6. NETWORK SOCKETS & CONNTRACK] ---"
ss -s 2>/dev/null | grep -E "^TCP:" | awk '{print "  " $0}' || true
CONN_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null \
  || echo 0)
CONN_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null \
  || echo 524288)
CONN_PCT=$(( CONN_COUNT * 100 / CONN_MAX ))
CONN_MARK=""
(( CONN_PCT > 80 )) && CONN_MARK=" ← [WARNING: >80% đầy!]"
echo "  Conntrack: ${CONN_COUNT} / ${CONN_MAX} (${CONN_PCT}%)${CONN_MARK}"

#--- [7] Storage ---
echo -e "\n--- [7. STORAGE & INOTIFY] ---"
df -h / | awk 'NR==2{
  printf "  Disk /: %s used / %s total (%s full, %s free)\n",
  $3,$2,$5,$4}'
WATCHES=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo '?')
echo "  Inotify Max Watches : ${WATCHES}"

#--- [8] Logs gần nhất ---
echo -e "\n--- [8. RECENT WATCHDOG LOG (5 dòng cuối)] ---"
if [[ -f /var/log/ii-watchdog.log ]]; then
  tail -5 /var/log/ii-watchdog.log | awk '{print "  " $0}'
else
  echo "  (Chưa có log watchdog)"
fi

#============================================================
# AI DIAGNOSTIC SUMMARY — 5 mức cảnh báo chính xác
#============================================================
echo -e "\n---------------- [AI DIAGNOSTIC SUMMARY] ----------------"

RAM_AVAIL_MB=$(free -m | awk '/^Mem:/{print $7}' || echo 999)
SWAP_FREE_MB=$(free -m | awk '/^Swap:/{print $4}' || echo 999)
SWAP_USED_MB=$(free -m | awk '/^Swap:/{print $3}' || echo 0)

PSI_FULL_10=$(grep "full" /proc/pressure/memory 2>/dev/null \
  | awk '{print $2}' | cut -d= -f2 || echo 0)
PSI_SOME_10=$(grep "some" /proc/pressure/memory 2>/dev/null \
  | awk '{print $2}' | cut -d= -f2 || echo 0)
PSI_INT=${PSI_FULL_10%.*}

SI_SO=$(vmstat 1 1 2>/dev/null | tail -1 \
  | awk '{print $7+$8}' || echo 0)

CPU_IDLE=$(top -bn1 2>/dev/null | grep "%Cpu" \
  | awk '{for(i=1;i<=NF;i++) if($i=="id,") print $(i-1)}' \
  | tr -d '%' || echo 100)
CPU_IDLE_INT=${CPU_IDLE%.*}

LOAD1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)

echo "  RAM Avail    : ${RAM_AVAIL_MB}MB"
echo "  Swap Used    : ${SWAP_USED_MB}MB | Free: ${SWAP_FREE_MB}MB"
echo "  PSI full/10s : ${PSI_FULL_10}%  |  some/10s: ${PSI_SOME_10}%"
echo "  Swap I/O     : ${SI_SO} KB/s"
echo "  CPU Idle     : ${CPU_IDLE_INT}%"
echo "  Load (1min)  : ${LOAD1}"
echo ""

# Phán đoán theo thứ tự ưu tiên từ nguy hiểm → ổn định
if (( RAM_AVAIL_MB < 30 )) && (( SWAP_FREE_MB < 200 )); then
  STATUS="💀 CRITICAL — RAM + Swap gần cạn! Nguy cơ crash toàn bộ container!"
  ACTION="Hành động ngay: docker stop bớt 30-50 container!"

elif (( EXITED_CTRS > 5 )); then
  STATUS="🔴 CONTAINERS_DEAD — ${EXITED_CTRS} container đã chết!"
  ACTION="Watchdog đang xử lý. Chạy: /usr/local/bin/ii-watchdog.sh"

elif (( PSI_INT >= 15 )); then
  STATUS="🔴 THRASHING — PSI Full=${PSI_FULL_10}% (>15%) Swap=${SI_SO}KB/s"
  ACTION="Giảm 20-30% container HOẶC nâng cấp RAM VPS"

elif (( PSI_INT >= 5 )) || (( SI_SO > 5000 )); then
  STATUS="🟡 MODERATE PRESSURE — PSI Full=${PSI_FULL_10}% Swap=${SI_SO}KB/s"
  ACTION="Theo dõi thêm. Xem xét giảm nhẹ container nếu kéo dài"

elif (( RAM_AVAIL_MB < 120 )); then
  STATUS="🟡 LOW RAM — Chỉ còn ${RAM_AVAIL_MB}MB. Cần theo dõi"
  ACTION="Hệ thống đang hoạt động nhưng dự phòng thấp"

elif (( CPU_IDLE_INT < 20 )); then
  STATUS="🟡 CPU BUSY — Idle chỉ ${CPU_IDLE_INT}%. Load=${LOAD1}"
  ACTION="CPU đang bận. Kiểm tra process ngốn CPU: top -b -n1"

else
  STATUS="🟢 HEALTHY OPTIMIZED — Hệ thống ổn định"
  ACTION="Không cần hành động. PSI=${PSI_FULL_10}% Swap=${SI_SO}KB/s RAM=${RAM_AVAIL_MB}MB"
fi

echo "  STATUS : ${STATUS}"
echo "  ACTION : ${ACTION}"
echo "=========================================================================="
SSEOF
chmod +x /usr/local/bin/ii-status.sh

#============================================================================
# HOÀN TẤT — CHẠY BÁO CÁO NGAY
#============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         SETUP ULTRA STABLE HOÀN TẤT THÀNH CÔNG!            ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Công cụ đã cài:                                            ║"
echo "║  • ii-status.sh     — Chẩn đoán AI (5 mức cảnh báo)        ║"
echo "║  • ii-watchdog.sh   — Hồi sinh container (mỗi 3 phút)      ║"
echo "║  • ii-dropcache.sh  — Drop cache thông minh (mỗi 10 phút)  ║"
echo "║  • ii-restart-all.sh — Bảo trì 04:15 & 16:15 mỗi ngày     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Lệnh theo dõi:                                             ║"
echo "║  sudo ii-status.sh          — Báo cáo toàn diện             ║"
echo "║  tail -f /var/log/ii-watchdog.log — Theo dõi watchdog live  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

/usr/local/bin/ii-status.sh || true

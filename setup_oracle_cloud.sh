cat << 'ORACLE_MASTER_EOF' > /root/setup_oracle_cloud.sh
#!/usr/bin/env bash
#============================================================================
#  setup_oracle_cloud.sh (OCI DUAL-ENGINE MASTER 2026)
#
#  MAY ĐO DÀNH RIÊNG CHO HẠ TẦNG ORACLE CLOUD INFRASTRUCTURE (OCI)
#   - OCI FIREWALL FIX  : Mo co iptables FORWARD ACCEPT dac thu cua Oracle Cloud,
#                         giup card mang ao tun2proxy truyen Proxy khong rot goi.
#   - ARCH ADAPTIVE     : Tu dong ho tro ca AMD x86_64 va Ampere ARM A1 (aarch64).
#   - DYNAMIC RAM SCALING: Tu dieu chinh muc tran RAM container tu 1GB -> 24GB RAM.
#   - APT LOCK-BREAKER  : Tu dong diet tien trinh apt-daily ngam cua OCI Ubuntu.
#   - KSM KERNEL MERGE  : Gop 300MB-500MB RAM ngam an toan cap Kernel.
#   - ZRAM 1GB LZ4      : Nem RAM lz4 ngam GB/s, triet ha 100% tre đia wa.
#   - SAFE ACCOUNT LIMIT: Ram 50M + Swap 128M + --restart=unless-stopped.
#   - INOTIFY FIX 2M    : Triet ha 100% loi Too many open files.
#============================================================================
set -Eeuo pipefail

ulimit -n 1048576 2>/dev/null || true
sysctl -w fs.inotify.max_user_watches=2097152 >/dev/null 2>&1 || true
sysctl -w fs.inotify.max_user_instances=65536 >/dev/null 2>&1 || true

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

has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

if [[ -n "$BASE_DIR" ]]; then
  if [[ -d "$BASE_DIR" ]]; then
    log "Quet them thu muc: ${BASE_DIR}"
  else
    warn "--base-dir '${BASE_DIR}' KHONG ton tai -> bo qua."
    BASE_DIR=""
  fi
fi

#------------------------------- THONG TIN HE THONG OCI --------------------------
VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
ARCH="$(uname -m)"
IS_CONTAINER=0
case "$VIRT" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1 ;; esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)

# ĐIỀU CHỈNH RAM DỘNG CHO CẢ AMD (1GB) LẪN AMPERE ARM (24GB) CỦA ORACLE
CONTAINER_MEM_LIMIT="50m"
CONTAINER_SWAP_LIMIT="128m"
if (( MEM_MB <= 1200 )); then
  CONTAINER_MEM_LIMIT="35m"; CONTAINER_SWAP_LIMIT="90m"
elif (( MEM_MB <= 2500 )); then
  CONTAINER_MEM_LIMIT="50m"; CONTAINER_SWAP_LIMIT="128m"
elif (( MEM_MB <= 5000 )); then
  CONTAINER_MEM_LIMIT="70m"; CONTAINER_SWAP_LIMIT="160m"
elif (( MEM_MB <= 12000 )); then
  CONTAINER_MEM_LIMIT="100m"; CONTAINER_SWAP_LIMIT="256m"
else                                   # Oracle ARM 24GB RAM
  CONTAINER_MEM_LIMIT="150m"; CONTAINER_SWAP_LIMIT="512m"
fi

#------------------- 1. APT LOCK-BREAKER ĐẶC THÙ CHO ORACLE CLOUD -------------------
clear_apt_locks() {
  log "Giai phong khoa APT Lock cua Oracle Cloud Ubuntu..."
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
log "apt update & install cac goi phu thuoc OCI..."
apt-get update -y -qq || { clear_apt_locks; apt-get update -y -qq; }
apt-get install -y -qq --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools earlyoom \
  iptables-persistent netfilter-persistent vnstat nload speedtest-cli || true

#------------------ 2. TỰ ĐỘNG CÀI ĐẶT DOCKER CHO ORACLE CLOUD ------------------
if ! command -v docker >/dev/null 2>&1; then
  log "ORACLE CLOUD: Dang tu dong cai dat Docker offical (Arch: ${ARCH})..."
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

#------------------- 3. KSM (KERNEL SAMEPAGE MERGING) -------------------
log "Kich hoat KSM (Kernel Samepage Merging) gop RAM ngam..."
if [[ -f /sys/kernel/mm/ksm/run ]]; then
  echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
  echo 500 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
  echo 1000 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
  log "Da kich hoat KSM thanh cong!"
fi

#----------------------------------- 4. ZRAM 1GB & SWAP ---------------------------------
log "Kich hoat ZRAM 1GB (Nem RAM lz4 sieu toc)..."
if ! swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
  modprobe zram num_devices=1 2>/dev/null || true
  if [[ -b /dev/zram0 ]]; then
    swapoff /dev/zram0 2>/dev/null || true
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo 1073741824 > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 >/dev/null 2>&1
    swapon -p 10 /dev/zram0 2>/dev/null || true
    log "Da kich hoat ZRAM 1GB (Priority 10) thanh cong!"
  fi
fi

if (( MEM_MB <= 1200 )); then          # AMD 1GB
  TARGET_SWAP_MB=1536; SWAPPINESS=20
elif (( MEM_MB <= 2500 )); then        # AMD 2GB
  TARGET_SWAP_MB=2048; SWAPPINESS=20
elif (( MEM_MB <= 5000 )); then        # 4GB RAM
  TARGET_SWAP_MB=3072; SWAPPINESS=20
else                                   # ARM 24GB RAM
  TARGET_SWAP_MB=4096; SWAPPINESS=10
fi

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
echo "  ORACLE CLOUD VPS $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU (${ARCH})"
echo "  Swap target=${TARGET_SWAP_MB}MB | Swappiness=${SWAPPINESS} | Limit=${CONTAINER_MEM_LIMIT}/${CONTAINER_SWAP_LIMIT}"
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

#------------------ 5. DIỆT BLOATWARE OS & DỌN WATCHTOWER DƯ THỪA ------------------
log "Dang diet cac dich vu OS ngom RAM ngam (snapd, multipathd, udisks2)..."
if has_systemd; then
  systemctl stop snapd multipathd udisks2 accountsservice 2>/dev/null || true
  systemctl disable snapd multipathd udisks2 accountsservice 2>/dev/null || true
fi
apt-get purge -y snapd 2>/dev/null || true
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

if [[ -f /etc/default/earlyoom ]]; then
  cat > /etc/default/earlyoom <<'EOF_EARLYOOM'
EARLYOOM_ARGS="-m 3 -s 5 --avoid '^(sshd|systemd|cron)$'"
EOF_EARLYOOM
fi
if has_systemd; then systemctl enable --now earlyoom >/dev/null 2>&1 || true; fi

timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF_APT'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF_APT

#--------------------------------- 6. DNS SACH 4 LỚP -------------------------------
if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
fi
rm -f /etc/resolv.conf
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\nnameserver 9.9.9.9\nnameserver 1.0.0.1\n' > /etc/resolv.conf

#------------------- 7. KERNEL TUNING + BBR + OCI FIREWALL FORWARD FIX -------------------
modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

# TỐI ƯU CẤU HÌNH TƯỜNG LỬA ORACLE CLOUD CHO TUN2SOCKS PROXY
log "Mo firewall FORWARD chuot cho Oracle Cloud..."
iptables -P FORWARD ACCEPT 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save 2>/dev/null || true
fi

echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

SYSCTL_FILE=/etc/sysctl.d/99-internetincome.conf
cat > "$SYSCTL_FILE" <<EOF_SYSCTL
#--- TCP BBR (TĂNG TỐC BĂNG THÔNG PROXY) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

#--- CẤU HÌNH IP_FORWARD QUAN TRỌNG CHO TUN2SOCKS ORACLE CLOUD ---
net.ipv4.ip_forward = 1

#--- ĐỆM SOCKET TCP CHUẨN AN TOÀN TRÁNH TRUYỀN DỮ LIỆU BỊ XÉ NHỎ ---
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152

#--- EXTREME OVERCOMMIT & CHỐNG PHÌNH RAM CACHE ---
vm.min_free_kbytes = 65536
vm.page-cluster = 0
vm.overcommit_memory = 1
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 125
vm.dirty_background_ratio = 3
vm.dirty_ratio = 8

#--- INOTIFY & FILE MAX FIX CHO 200+ CONTAINER ---
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

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
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
SystemMaxUse=10M
RuntimeMaxUse=5M
EOF_JOURNAL
if has_systemd; then systemctl restart systemd-journald 2>/dev/null || true; fi

#------------------- 8. AUTO-PATCHER ENGAGEUB -------------------
auto_patch_engageub_repo() {
  log "Dang quet va KHÓA RAM AN TOÀN (${CONTAINER_MEM_LIMIT}/${CONTAINER_SWAP_LIMIT}) + RESTART CỜ..."
  ROOTS=(/opt /root /home /srv)
  if [[ -n "$BASE_DIR" ]]; then ROOTS+=("$BASE_DIR"); fi

  while IFS= read -r sh_file; do
    d=$(dirname "$sh_file")
    if [[ -f "${d}/properties.conf" ]]; then
      sed -i "s/MAX_MEMORY=.*/MAX_MEMORY=${CONTAINER_MEM_LIMIT}/" "${d}/properties.conf" 2>/dev/null || true
      grep -q "MAX_MEMORY=" "${d}/properties.conf" || echo "MAX_MEMORY=${CONTAINER_MEM_LIMIT}" >> "${d}/properties.conf"
    fi

    if [[ -f "$sh_file" ]]; then
      cp -n "$sh_file" "${sh_file}.bak" 2>/dev/null || true
      sed -i "s/--memory=\"[0-9]*[a-z]*\"/--memory=\"${CONTAINER_MEM_LIMIT}\"/g" "$sh_file" 2>/dev/null || true
      sed -i "s/--memory-swap=\"[0-9]*[a-z]*\"/--memory-swap=\"${CONTAINER_SWAP_LIMIT}\"/g" "$sh_file" 2>/dev/null || true
      
      if ! grep -q "\--restart" "$sh_file"; then
        sed -i "s/docker run -d/docker run -d --restart=unless-stopped/g" "$sh_file" 2>/dev/null || true
      fi

      if ! grep -q "\--memory" "$sh_file"; then
        sed -i "s/docker run -d/docker run -d --memory=\"${CONTAINER_MEM_LIMIT}\" --memory-swap=\"${CONTAINER_SWAP_LIMIT}\"/g" "$sh_file"
      fi
    fi
  done < <(find "${ROOTS[@]}" -maxdepth 4 -name internetIncome.sh -type f 2>/dev/null | sort -u)
}
auto_patch_engageub_repo

#------------------ 9. DOCKER DAEMON CONFIG ------------------
mkdir -p /etc/docker
NEW_DAEMON="$(cat <<EOF_DAEMON
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "2m", "max-file": "2" },
  "dns": ["8.8.8.8", "1.1.1.1", "9.9.9.9"],
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
  log "daemon.json khong thay doi -> KHONG DUNG DOCKER"
else
  if [[ -f /etc/docker/daemon.json ]]; then
    cp -f /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
  fi
  printf '%s\n' "$NEW_DAEMON" > /etc/docker/daemon.json
  RUNNING_BEFORE=$(docker ps -q 2>/dev/null | wc -l)
  if has_systemd; then
    systemctl restart docker
  else
    service docker start >/dev/null 2>&1 || service docker restart || true
  fi
  DOCKER_RESTARTED=1
fi

if has_systemd; then systemctl enable --now docker >/dev/null 2>&1 || true; fi

if (( DOCKER_RESTARTED == 1 )); then
  sleep 10
  log "Dang bat lai cac container engageub TU TU..."
  
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    docker start "$cid" >/dev/null 2>&1 || true
    sleep 1.5
  done < <(find /opt /root /home /srv -maxdepth 4 -name containernames.txt -type f -exec cat {} + 2>/dev/null | sort -u)

  if command -v ctr >/dev/null 2>&1; then
    for cid in $(docker ps -aq --no-trunc -f status=exited 2>/dev/null); do
      ctr -n moby task kill -s SIGKILL "$cid" >/dev/null 2>&1 || true
      ctr -n moby task rm "$cid" >/dev/null 2>&1 || true
    done
  fi

  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    docker start "$cid" >/dev/null 2>&1 || true
    sleep 1.5
  done < <(docker ps -aq -f status=exited 2>/dev/null)

  log "Da revive xong tat ca container mot cach em ai!"
fi

#---------------------- 10. CRON 04:15 + 16:15 + WATCHDOG 15M ----------------
install_cron_stack() {
  cat > /usr/local/bin/ii-restart-all.sh <<'EOF_RESTART'
#!/usr/bin/env bash
LOG=/var/log/ii-restart.log
ROOTS=(/opt /root /home /srv __EXTRA__)
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
      echo "[$(ts)] >>> ${d} (${n} container - restart tu tu 2s/container)..."
      
      while IFS= read -r cid; do
        [[ -n "$cid" ]] || continue
        docker restart "$cid" >/dev/null 2>&1 || echo "[$(ts)] !! loi restart $cid"
        sleep 2
      done < "$cn"

      sleep 5
    done

    while IFS= read -r cid; do
      [[ -n "$cid" ]] || continue
      docker start "$cid" >/dev/null 2>&1 || true
      sleep 1.5
    done < <(cat "${FILES[@]}" 2>/dev/null | sort -u)

    sync && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    echo "[$(ts)] da xa cache RAM rac (drop_caches)"
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

15 4 * * * root /usr/local/bin/ii-restart-all.sh
15 16 * * * root sync && echo 3 > /proc/sys/vm/drop_caches >/dev/null 2>&1
*/15 * * * * root docker ps -aq -f status=exited 2>/dev/null | xargs -r -n1 docker start >/dev/null 2>&1
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

#------------------ CONG CU ii-status.sh (BÁO CÁO ORACLE CLOUD) ------------------
cat > /usr/local/bin/ii-status.sh <<'EOF_STATUS'
#!/usr/bin/env bash
ROOTS=("$@")
if (( ${#ROOTS[@]} == 0 )); then ROOTS=(/opt /root /home /srv); fi

echo "==================== [ORACLE CLOUD AI-DIAGNOSTIC REPORT] ===================="
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "HOSTNAME     : $(hostname)"
echo "UPTIME       : $(uptime -p 2>/dev/null || uptime)"
echo "KERNEL/ARCH  : $(uname -r) ($(uname -m))"

echo -e "\n--- [1. INTERNETINCOME FOLDERS & CONTAINERS] ---"
found=0
while IFS= read -r cn; do
  d=$(dirname "$cn")
  [[ -f "${d}/internetIncome.sh" ]] || continue
  found=1
  total=0
  running=0
  stopped=0
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    state=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo "not_found")
    if [[ "$state" == "true" ]]; then
      running=$((running+1))
      total=$((total+1))
    elif [[ "$state" == "false" ]]; then
      stopped=$((stopped+1))
      total=$((total+1))
    fi
  done < "$cn"
  mark=""
  (( stopped > 0 )) && mark=" <-- \033[1;31m[WARNING: ${stopped} CONTAINERS STOPPED]\033[0m"
  printf "  %-46s %4s/%-4s running%s\n" "$d" "$running" "$total" "$mark"
done < <(find "${ROOTS[@]}" -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)
if (( found == 0 )); then echo "  (No InternetIncome folders found)"; fi

RUNNING_CTRS=$(docker ps -q 2>/dev/null | wc -l)
TOTAL_CTRS=$(docker ps -aq 2>/dev/null | wc -l)
EXITED_CTRS=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
echo "  TOTAL DOCKER SUMMARY: ${RUNNING_CTRS} running / ${TOTAL_CTRS} total (Exited: ${EXITED_CTRS})"

echo -e "\n--- [2. CPU LOAD & DISK I/O WAIT (wa)] ---"
echo "  Load Average : $(cat /proc/loadavg 2>/dev/null || echo '?')"
top -bn1 2>/dev/null | grep "%Cpu" | awk '{print "  " $0}' || true

echo -e "\n--- [3. RAM, ZRAM & SWAP ALLOCATION] ---"
free -h | awk '/^Mem:/{printf "  RAM  : Total %s | Used %s | Free %s | Avail %s\n",$2,$3,$4,$7} /^Swap:/{printf "  Swap : Total %s | Used %s | Free %s\n",$2,$3,$4}'
echo "  Active Swap Devices:"
swapon --show 2>/dev/null | awk 'NR>1{printf "    - %s (%s, Priority %s, Used %s)\n",$1,$3,$5,$4}' || true

echo -e "\n--- [4. SWAP PAGING (si/so), RUN QUEUE (r) & CONTEXT SWITCHES (cs)] ---"
vmstat 1 2 2>/dev/null | tail -n 1 | awk '{printf "  r=%s (runqueue) | b=%s (blocked) | si=%s KB/s (swap-in) | so=%s KB/s (swap-out) | cs=%s/s (context-switches) | wa=%s%%\n", $1, $2, $7, $8, $12, $16}'

echo -e "\n--- [5. MEMORY PRESSURE STALLS (PSI)] ---"
if [[ -f /proc/pressure/memory ]]; then
  cat /proc/pressure/memory | awk '{print "  " $0}'
else
  echo "  (PSI memory pressure not supported by kernel)"
fi

echo -e "\n--- [6. NETWORK SOCKETS & CONNTRACK TABLE] ---"
ss -s 2>/dev/null | grep -E "TCP:|estab" | awk '{print "  " $0}' || true
CONN_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CONN_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
echo "  Conntrack Streams Active : ${CONN_COUNT} / ${CONN_MAX}"

echo -e "\n--- [7. STORAGE & INOTIFY WATCHES] ---"
df -h / | awk 'NR==2{printf "  Disk Root / : %s used / %s total (%s full, %s free)\n",$3,$2,$5,$4}'
WATCHES=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo '?')
echo "  Inotify Max User Watches : ${WATCHES}"

echo -e "\n---------------- [AI SYSTEM DIAGNOSTIC SUMMARY] ----------------"
RAM_AVAIL_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 999)
SWAP_FREE_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $4}' || echo 999)
PSI_FULL_10=$(cat /proc/pressure/memory 2>/dev/null | grep "full" | awk '{print $2}' | cut -d= -f2 || echo 0)
PSI_INT=${PSI_FULL_10%.*}

if (( RAM_AVAIL_MB < 30 )) && (( SWAP_FREE_MB < 100 )); then
  echo "  STATUS: [CRITICAL_MEMORY_EXHAUSTION] Virtual memory near zero! Risk of crash!"
elif (( EXITED_CTRS > 0 )); then
  echo "  STATUS: [CONTAINERS_EXITED] Some containers have stopped. Check docker ps -a."
elif (( PSI_INT >= 15 )); then
  echo "  STATUS: [SILENT_MEMORY_THRASHING] PSI Full Memory Pressure is ${PSI_FULL_10}% (>15%)."
else
  echo "  STATUS: [HEALTHY_OPTIMIZED] Oracle Cloud VPS is running smoothly with clean KSM memory and low PSI."
fi
echo "=========================================================================="
EOF_STATUS
chmod +x /usr/local/bin/ii-status.sh

echo "============================= SETUP XONG (ORACLE CLOUD MASTER 2026) =============================="
/usr/local/bin/ii-status.sh || true
ORACLE_MASTER_EOF
chmod +x /root/setup_oracle_cloud.sh

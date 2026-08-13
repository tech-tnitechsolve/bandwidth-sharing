cat << 'VM_MASTER_EOF' > setup_vm.sh
#!/usr/bin/env bash
#============================================================================
#  setup_vm.sh - SETUP MÁY ẢO CÁ NHÂN (12-15h/ngày - 2026 VM MASTER)
#
#  ĐẶC ĐIỂM DÀNH RIÊNG CHO MÁY ẢO PC WINDOWS:
#   - Tự động nén ZRAM & KSM: Giúp VM chiếm ít RAM thật của Windows hơn.
#   - Tự động BẬT LẠI toàn bộ container khi MỞ VM (@reboot autostart).
#   - Tự động Đồng bộ thời gian NTP khi khôi phục VM từ Windows Sleep.
#   - Giữ nguyên tùy chọn tự tắt máy theo giờ: --auto-off 23:30
#============================================================================
set -Eeuo pipefail

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_0=''
fi
log()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!!]${C_0} $*"; }
die()  { echo -e "${C_R}[XX]${C_0} $*"; exit 1; }

#--------------------------------- THAM SỐ -----------------------------------
AUTO_OFF=""
DO_PULL=1
BASE_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-off)   AUTO_OFF="${2:-}"; shift 2 ;;
    --auto-off=*) AUTO_OFF="${1#*=}"; shift ;;
    --base-dir)   BASE_DIR="${2:-}"; shift 2 ;;
    --base-dir=*) BASE_DIR="${1#*=}"; shift ;;
    --no-pull)    DO_PULL=0; shift ;;
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

#------------------------------- THÔNG TIN MÁY ẢO --------------------------
VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)

# GIỚI HẠN DOCKER THEO DUNG LƯỢNG RAM MÁY ẢO
CONTAINER_MEM_LIMIT="50m"
CONTAINER_SWAP_LIMIT="128m"
if (( MEM_MB <= 1200 )); then
  CONTAINER_MEM_LIMIT="35m"; CONTAINER_SWAP_LIMIT="90m"
elif (( MEM_MB <= 2500 )); then
  CONTAINER_MEM_LIMIT="50m"; CONTAINER_SWAP_LIMIT="128m"
elif (( MEM_MB <= 5000 )); then
  CONTAINER_MEM_LIMIT="70m"; CONTAINER_SWAP_LIMIT="160m"
else
  CONTAINER_MEM_LIMIT="100m"; CONTAINER_SWAP_LIMIT="256m"
fi

TARGET_SWAP_MB=$(( MEM_MB / 2 ))
if (( TARGET_SWAP_MB < 1024 )); then TARGET_SWAP_MB=1024; fi
if (( TARGET_SWAP_MB > 4096 )); then TARGET_SWAP_MB=4096; fi

if (( CPU <= 2 )); then
  CONCURRENT_DOWNLOADS=3; SYN_BACKLOG=8192
elif (( CPU <= 4 )); then
  CONCURRENT_DOWNLOADS=5; SYN_BACKLOG=16384
else
  CONCURRENT_DOWNLOADS=8; SYN_BACKLOG=32768
fi

echo "=============================================================="
echo "  VM $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU | Ao hoa: ${VIRT}"
echo "  Swap target=${TARGET_SWAP_MB}MB | Limit default=${CONTAINER_MEM_LIMIT}/${CONTAINER_SWAP_LIMIT}"
echo "=============================================================="

#--------------------------- 1. TỐI ƯU ZRAM & KSM CHO VM ------------------------
log "Kich hoat KSM (Gop RAM trung lap giup tiet khem RAM Host Windows)..."
if [[ -f /sys/kernel/mm/ksm/run ]]; then
  echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
  echo 300 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
  echo 1250 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
  log "Da kich hoat KSM thanh cong!"
fi

ZRAM_SIZE_BYTES=$(( MEM_MB * 1024 * 1024 ))
log "Kich hoat ZRAM ${MEM_MB}MB cho VM (Nem RAM sieu toc LZ4)..."
if ! swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
  modprobe zram num_devices=1 2>/dev/null || true
  if [[ -b /dev/zram0 ]]; then
    swapoff /dev/zram0 2>/dev/null || true
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo "$ZRAM_SIZE_BYTES" > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 >/dev/null 2>&1
    swapon -p 10 /dev/zram0 2>/dev/null || true
    log "Da kich hoat ZRAM ${MEM_MB}MB (Priority 10) thanh cong!"
  fi
fi

SWAPPINESS=100

#----------------------------------- 2. SWAPFILE ---------------------------------
if swapon --show=NAME --noheadings 2>/dev/null | grep -q "/swapfile"; then
  log "Da co swap đia /swapfile -> bo qua"
elif [[ "$VIRT" =~ ^(lxc|lxc-libvirt|openvz)$ ]]; then
  warn "May ${VIRT} (container) khong tao duoc swap -> bo qua"
else
  log "Tao swap đia ${TARGET_SWAP_MB}MB..."
  if ! fallocate -l "${TARGET_SWAP_MB}M" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count="$TARGET_SWAP_MB" status=none
  fi
  chmod 600 /swapfile
  if mkswap /swapfile >/dev/null 2>&1 && swapon -p 0 /swapfile 2>/dev/null; then
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw,pri=0 0 0' >> /etc/fstab
    log "Tao swap ${TARGET_SWAP_MB}MB thanh cong"
  else
    rm -f /swapfile
    warn "Kernel khong cho tao swap -> bo qua"
  fi
fi

#--------------------------- 3. APT & ĐỒNG BỘ THỜI GIAN ------------------------
export DEBIAN_FRONTEND=noninteractive
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF_APT'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF_APT

log "apt update & install goi phu thuoc cho VM..."
apt-get update -y -qq
apt-get install -y -qq --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools systemd-timesyncd vnstat nload speedtest-cli dnsutils || true

# TỰ ĐỘNG BỎ EARLYOOM ĐỂ TRANH KILL NHẦM CONTAINER DANG KIẾM TIỀN
if has_systemd; then
  systemctl stop snapd earlyoom 2>/dev/null || true
  systemctl disable snapd earlyoom 2>/dev/null || true
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
fi
apt-get purge -y snapd earlyoom 2>/dev/null || true

timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true

#--------------------------------- 4. DNS SACH -------------------------------
if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
fi
rm -f /etc/resolv.conf
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
log "resolv.conf -> 8.8.8.8 + 1.1.1.1"

#------------------------------- 5. KERNEL TUNING ----------------------------
modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

SYSCTL_FILE=/etc/sysctl.d/99-internetincome.conf
cat > "$SYSCTL_FILE" <<EOF_SYSCTL
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
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
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF_SYSCTL

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue
  sysctl -w "$line" >/dev/null 2>&1 || true
done < "$SYSCTL_FILE"
log "Kernel tuning xong ($SYSCTL_FILE)"

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

#---------------------------------- 6. DOCKER --------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Cai dat Docker..."
  curl -fsSL https://get.docker.com | sh
else
  log "Docker da co san: $(docker --version 2>/dev/null || echo '?')"
fi

# THÊM USER VÀO GROUP DOCKER ĐỂ DÙNG DOCKER KHÔNG CẦN SUDO
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  usermod -aG docker "${SUDO_USER}" 2>/dev/null || true
  log "Da them '${SUDO_USER}' vao group docker"
fi

auto_patch_engageub_repo() {
  log "Dang quet va PATCH RAM DOCKER VM (Chung: ${CONTAINER_MEM_LIMIT} | Mystnodes: 250m | Wipter: 350m)..."
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

      sed -i -E '/wipter/I s/--memory="[0-9]+[a-zA-Z]+"/--memory="350m"/g' "$sh_file" 2>/dev/null || true
      sed -i -E '/wipter/I s/--memory-swap="[0-9]+[a-zA-Z]+"/--memory-swap="600m"/g' "$sh_file" 2>/dev/null || true
    fi
  done < <(find "${ROOTS[@]}" -maxdepth 4 -name internetIncome.sh -type f 2>/dev/null | sort -u)
}
auto_patch_engageub_repo

if command -v docker >/dev/null 2>&1; then
  CTRS=$(docker ps -aq 2>/dev/null || true)
  if [[ -n "$CTRS" ]]; then
    docker update --restart=unless-stopped $CTRS >/dev/null 2>&1 || true
    for cid in $CTRS; do
      c_img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
      c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || true)
      if [[ "$c_img" =~ mysterium|myst ]] || [[ "$c_name" =~ mysterium|myst ]]; then
        docker update --memory="250m" --memory-swap="500m" "$cid" >/dev/null 2>&1 || true
      elif [[ "$c_img" =~ wipter ]] || [[ "$c_name" =~ wipter ]]; then
        docker update --memory="350m" --memory-swap="600m" "$cid" >/dev/null 2>&1 || true
      fi
    done
  fi
fi

mkdir -p /etc/docker
NEW_DAEMON="$(cat <<EOF_DAEMON
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "dns": ["8.8.8.8", "1.1.1.1"],
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
  log "daemon.json khong thay doi -> bo qua restart docker"
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

if (( DOCKER_RESTARTED == 1 )); then
  sleep 10
  find /opt /root /home /srv -maxdepth 4 -name containernames.txt -type f -exec cat {} + 2>/dev/null \
    | xargs -r docker start >/dev/null 2>&1 || true
  if command -v ctr >/dev/null 2>&1; then
    for cid in $(docker ps -aq --no-trunc -f status=exited 2>/dev/null); do
      ctr -n moby task kill -s SIGKILL "$cid" >/dev/null 2>&1 || true
      ctr -n moby task rm "$cid" >/dev/null 2>&1 || true
    done
  fi
  docker ps -aq -f status=exited 2>/dev/null | xargs -r -n1 docker start >/dev/null 2>&1 || true
fi

#------------------------------- 7. PRE-PULL IMAGE ---------------------------
if (( DO_PULL == 1 )); then
  log "Pre-pulling core docker images cho VM..."
  for img in "traffmonetizer/cli_v2:latest" "xjasonlyu/tun2socks:latest"; do
    docker pull "$img" >/dev/null 2>&1 || true
  done
else
  log "Bo qua pre-pull (--no-pull)"
fi

#--------------------- 8. AUTOSTART CONTAINER KHI MỞ VM ----------------------
cat > /usr/local/bin/ii-autostart.sh <<'EOS_AUTOSTART'
#!/usr/bin/env bash
LOG=/var/log/ii-autostart.log
sleep 30
ids=$(docker ps -aq 2>/dev/null || true)
[[ -z "$ids" ]] && exit 0
{
  echo "[$(date '+%F %T')] pass1: autostart $(echo "$ids" | wc -l) container sau khi mo VM"
  echo "$ids" | xargs -r -n1 docker start 2>&1
  sleep 15
  for cid in $(docker ps -aq --no-trunc -f status=exited 2>/dev/null); do
    ctr -n moby task kill -s SIGKILL "$cid" 2>/dev/null || true
    ctr -n moby task rm "$cid" 2>/dev/null || true
  done
  echo "[$(date '+%F %T')] pass2: revive container con Exited"
  docker ps -aq -f status=exited 2>/dev/null | xargs -r -n1 docker start 2>&1
} >> "$LOG" 2>&1
EOS_AUTOSTART
chmod +x /usr/local/bin/ii-autostart.sh

# FILE DIAGNOSTIC ii-status.sh TỐI ƯU CHO VM
cat > /usr/local/bin/ii-status.sh <<'EOF_STATUS'
#!/usr/bin/env bash
set -u

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

echo -e "${C_B}==================== [PERSONAL VM QUALITY DIAGNOSTIC] ====================${C_0}"
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "HOSTNAME     : $(hostname)"
echo "UPTIME       : $(uptime -p 2>/dev/null || uptime)"
echo "KERNEL/VIRT  : $(uname -r) ($(systemd-detect-virt 2>/dev/null || echo 'unknown'))"

ISSUES_COUNT=0
WARNINGS_COUNT=0

echo -e "\n${C_C}--- [1. NODE CONTAINERS & RAM LIMIT AUDIT] ---${C_0}"
ROOTS=("$@")
if (( ${#ROOTS[@]} == 0 )); then ROOTS=(/opt /root /home /srv); fi

found=0
while IFS= read -r cn; do
  d=$(dirname "$cn")
  [[ -f "${d}/internetIncome.sh" ]] || continue
  found=1
  total=0; running=0; stopped=0
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    state=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo "not_found")
    if [[ "$state" == "true" ]]; then
      running=$((running+1)); total=$((total+1))
    elif [[ "$state" == "false" ]]; then
      stopped=$((stopped+1)); total=$((total+1))
    fi
  done < "$cn"

  mark=""
  if (( stopped > 0 )); then
    mark="${C_R}[${stopped} STOPPED]${C_0}"
    ISSUES_COUNT=$((ISSUES_COUNT+stopped))
  else
    mark="${C_G}[100% HEALTHY]${C_0}"
  fi
  printf "  %-42s %3s/%-3s running  %b\n" "$d" "$running" "$total" "$mark"
done < <(find "${ROOTS[@]}" -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)

if (( found == 0 )); then echo "  (No InternetIncome folders found)"; fi

RUNNING_CTRS=$(docker ps -q 2>/dev/null | wc -l)
TOTAL_CTRS=$(docker ps -aq 2>/dev/null | wc -l)
EXITED_CTRS=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
echo "  TOTAL SUMMARY: ${RUNNING_CTRS} running / ${TOTAL_CTRS} total (Exited: ${EXITED_CTRS})"

echo -e "\n${C_C}--- [2. NETWORK & TIME SYNC] ---${C_0}"
NTP_STAT=$(timedatectl status 2>/dev/null | grep "NTP service" | awk '{print $3}' || echo "unknown")
if [[ "$NTP_STAT" == "active" || "$NTP_STAT" == "yes" ]]; then
  echo -e "  NTP Time Sync Status    : ${C_G}ACTIVE (Strict accuracy)${C_0}"
else
  echo -e "  NTP Time Sync Status    : ${C_Y}INACTIVE (${NTP_STAT})${C_0}"
  WARNINGS_COUNT=$((WARNINGS_COUNT+1))
fi

echo -e "\n${C_C}--- [3. SYSTEM RAM, SWAP & ZRAM ALLOCATION] ---${C_0}"
RAM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
RAM_USED=$(free -m | awk '/^Mem:/{print $3}')
RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
SWAP_TOTAL=$(free -m | awk '/^Swap:/{print $2}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')

echo "  RAM  : Total ${RAM_TOTAL}MB | Used ${RAM_USED}MB | Avail ${RAM_AVAIL}MB"
echo "  Swap : Total ${SWAP_TOTAL}MB | Used ${SWAP_USED}MB"

if swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
  ZRAM_SIZE=$(swapon --show 2>/dev/null | grep "/dev/zram0" | awk '{print $3}')
  echo -e "  ZRAM : ${C_G}ACTIVE (${ZRAM_SIZE} LZ4 Priority 10)${C_0}"
else
  echo -e "  ZRAM : ${C_Y}NOT ACTIVE${C_0}"
fi

echo -e "\n---------------- [VM QUALITY SUMMARY] ----------------"
if (( ISSUES_COUNT == 0 )); then
  echo -e "  STATUS        : ${C_G}[HEALTHY_SMOOTH_VM]${C_0} Personal VM is running perfectly!"
else
  echo -e "  STATUS        : ${C_R}[WARNING_ISSUES_FOUND]${C_0} Check stopped containers."
fi
echo -e "${C_B}=========================================================================="
EOF_STATUS

chmod +x /usr/local/bin/ii-status.sh
ln -sf /usr/local/bin/ii-status.sh /usr/bin/ii-status.sh 2>/dev/null || true
ln -sf /usr/local/bin/ii-status.sh /usr/bin/ii-status 2>/dev/null || true

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

{
  echo 'SHELL=/bin/bash'
  echo 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
  echo ''
  echo '# Sau khi MO VM: tu dong bat lai toan bo container'
  echo '@reboot root /usr/local/bin/ii-autostart.sh'
  echo '*/15 * * * * root docker ps -aq -f status=exited 2>/dev/null | xargs -r -n1 docker start >/dev/null 2>&1'
  echo '0 3 * * 0 root /usr/bin/docker network prune -f >/dev/null 2>&1'
  echo '15 3 * * 0 root /usr/bin/docker volume prune -f >/dev/null 2>&1'
  echo '30 5 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1'
  if [[ -n "$AUTO_OFF" ]]; then
    echo ''
    echo "# Tu TAT may dung gio (ban dat: ${AUTO_OFF})"
    echo "${OFF_M} ${OFF_H} * * * root /usr/sbin/poweroff"
  fi
} > /etc/cron.d/internetincome
chmod 644 /etc/cron.d/internetincome

if has_systemd; then
  systemctl enable --now cron >/dev/null 2>&1 || true
else
  service cron start >/dev/null 2>&1 || true
fi

log "Autostart: container tu chay lai moi khi MO VM (@reboot, log /var/log/ii-autostart.log)"
if [[ -n "$AUTO_OFF" ]]; then
  log "Auto-off: may se tu poweroff luc ${AUTO_OFF} hang ngay"
fi

#--------------------------------- TỔNG KẾT ----------------------------------
SW_DESC=$(swapon --show=SIZE --noheadings 2>/dev/null | paste -sd' ' -)
if [[ -z "$SW_DESC" ]]; then SW_DESC="khong co"; fi

echo
echo "============================= SETUP XONG (VM MASTER 2026) =============================="
echo "  Docker : $(docker --version 2>/dev/null || echo 'loi')"
echo "  Swap   : ${SW_DESC}"
echo "  Cron   : @reboot autostart + prune CN$( [[ -n "$AUTO_OFF" ]] && echo " + poweroff ${AUTO_OFF}" )"
echo "  Tool   : sudo ii-status.sh (xem nhanh folder/container/RAM/Disk)"
echo
/usr/local/bin/ii-status.sh || true
echo
echo "=========================================================================="
VM_MASTER_EOF
chmod +x setup_vm.sh

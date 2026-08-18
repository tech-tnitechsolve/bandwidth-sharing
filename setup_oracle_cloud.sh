cat << 'ORACLE_MASTER_EOF' > /root/setup_oracle_cloud.sh
#!/usr/bin/env bash
#============================================================================
#  setup_oracle_cloud.sh (100% AUTO-PILOT OCI MASTER 2026 - ULTIMATE EDITION)
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
ARCH="$(uname -m)"
IS_CONTAINER=0
case "$VIRT" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1 ;; esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)

if (( MEM_MB <= 1200 )); then           # OCI AMD 1GB RAM
  CONTAINER_MEM_LIMIT="35m"; CONTAINER_SWAP_LIMIT="90m"
  TARGET_SWAP_MB=1536
elif (( MEM_MB <= 2500 )); then         # OCI AMD 2GB RAM
  CONTAINER_MEM_LIMIT="50m"; CONTAINER_SWAP_LIMIT="128m"
  TARGET_SWAP_MB=2048
elif (( MEM_MB <= 7000 )); then         # OCI ARM 1 CPU / 6GB RAM
  CONTAINER_MEM_LIMIT="70m"; CONTAINER_SWAP_LIMIT="160m"
  TARGET_SWAP_MB=3072
elif (( MEM_MB <= 13000 )); then        # OCI ARM 12GB RAM
  CONTAINER_MEM_LIMIT="100m"; CONTAINER_SWAP_LIMIT="256m"
  TARGET_SWAP_MB=4096
else                                    # OCI ARM 24GB RAM
  CONTAINER_MEM_LIMIT="150m"; CONTAINER_SWAP_LIMIT="512m"
  TARGET_SWAP_MB=4096
fi

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
log "apt update & install cac goi phu thuoc OCI..."
apt-get update -y -qq || { clear_apt_locks; apt-get update -y -qq; }
apt-get install -y -qq --no-install-recommends \
  -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools \
  iptables-persistent netfilter-persistent systemd-timesyncd vnstat nload speedtest-cli dnsutils || true

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

log "Kich hoat KSM gop RAM ngam..."
if [[ -f /sys/kernel/mm/ksm/run ]]; then
  echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
  echo 300 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
  echo 1250 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
  log "Da kich hoat KSM thanh cong!"
fi

ZRAM_SIZE_BYTES=$(( MEM_MB * 1024 * 1024 ))
log "Kich hoat ZRAM ${MEM_MB}MB cho OCI..."
if ! swapon --show 2>/dev/null | grep -q "/dev/zram0"; then
  modprobe zram num_devices=1 2>/dev/null || true
  if [[ -b /dev/zram0 ]]; then
    swapoff /dev/zram0 2>/dev/null || true
    echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo "$ZRAM_SIZE_BYTES" > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 >/dev/null 2>&1
    swapon -p 10 /dev/zram0 2>/dev/null || true
    log "Da kich hoat ZRAM ${MEM_MB}MB thanh cong!"
  fi
fi

SWAPPINESS=100
sysctl -w vm.swappiness=100 >/dev/null 2>&1 || true

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
echo "  Swap target=${TARGET_SWAP_MB}MB | Swappiness=${SWAPPINESS} (ZRAM Mode)"
echo "=============================================================="

CURR_SWAP_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}' || echo 0)
SWAP_USED_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $3}' || echo 0)
RAM_AVAIL_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 0)

if (( IS_CONTAINER == 1 )); then
  warn "May ${VIRT} khong tao duoc swap -> bo qua"
elif (( CURR_SWAP_MB >= TARGET_SWAP_MB - 256 )) && (( CURR_SWAP_MB <= TARGET_SWAP_MB + 1536 )); then
  log "Da co swap đia ${CURR_SWAP_MB}MB -> giu nguyen"
else
  REBUILD_SWAP=1
  if (( CURR_SWAP_MB > TARGET_SWAP_MB + 1536 )); then
    if (( SWAP_USED_MB > RAM_AVAIL_MB - 200 )); then
      warn "Swap hien tai dang dung -> Giu nguyen an toan!"
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
      log "Tao swap đia thanh cong"
    else
      rm -f "$SWAP_TARGET_FILE"
    fi
  fi
fi

log "Dang diet cac dich vu OS ngom RAM ngam..."
if has_systemd; then
  systemctl stop snapd multipathd udisks2 accountsservice earlyoom 2>/dev/null || true
  systemctl disable snapd multipathd udisks2 accountsservice earlyoom 2>/dev/null || true
  systemctl enable --now systemd-timesyncd 2>/dev/null || true
fi
apt-get purge -y snapd earlyoom 2>/dev/null || true
rm -rf /var/cache/snapd/ /var/lib/snapd/ 2>/dev/null || true

timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF_APT'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF_APT

if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
fi

rm -f /etc/resolv.conf
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 222.252.2.2\nnameserver 203.162.4.190\nnameserver 9.9.9.9\n' > /etc/resolv.conf

modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

log "Mo firewall IPTables cho Oracle Cloud..."
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

SYSCTL_FILE=/etc/sysctl.d/99-internetincome.conf
cat > "$SYSCTL_FILE" <<EOF_SYSCTL
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152
vm.min_free_kbytes = 65536
vm.page-cluster = 0
vm.overcommit_memory = 1
vm.swappiness = ${SWAPPINESS}
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
log "Kernel Tuning xong"

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

auto_patch_engageub_repo() {
  log "Dang quet va PATCH RAM DOCKER OCI + FIX LỖI IPV6..."
  ROOTS=(/opt /root /home /srv /home/ubuntu /home/opc)
  if [[ -n "$BASE_DIR" ]]; then ROOTS+=("$BASE_DIR"); fi

  while IFS= read -r sh_file; do
    d=$(dirname "$sh_file")
    if [[ -f "${d}/properties.conf" ]]; then
      sed -i "s/MAX_MEMORY=.*/MAX_MEMORY=${CONTAINER_MEM_LIMIT}/" "${d}/properties.conf" 2>/dev/null || true
      grep -q "MAX_MEMORY=" "${d}/properties.conf" || echo "MAX_MEMORY=${CONTAINER_MEM_LIMIT}" >> "${d}/properties.conf"
    fi

    if [[ -f "$sh_file" ]]; then
      cp -n "$sh_file" "${sh_file}.bak" 2>/dev/null || true
      
      sed -i 's/--sysctl net.ipv6.conf.[a-z0-9_]*.disable_ipv6=[0-9]//g' "$sh_file" 2>/dev/null || true

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
  "log-opts": { "max-size": "2m", "max-file": "2" },
  "dns": ["8.8.8.8", "1.1.1.1", "9.9.9.9"],
  "registry-mirrors": ["https://mirror.gcr.io", "https://docker.m.daocloud.io"],
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
  log "daemon.json khong thay doi -> bo qua"
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

while ! docker info >/dev/null 2>&1; do
  sleep 1
done

if (( DOCKER_RESTARTED == 1 )); then
  log "Dang bat lai cac container engageub TU TU..."
  
  while IFS= read -r cid; do
    [[ -n "$cid" ]] || continue
    docker start "$cid" >/dev/null 2>&1 || true
    sleep 1.5
  done < <(find /opt /root /home /srv /home/ubuntu /home/opc -maxdepth 4 -name containernames.txt -type f -exec cat {} + 2>/dev/null | sort -u)

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
  MEM_LIMIT="50m"; SWAP_LIMIT="128m"
  while IFS= read -r sh_f; do
    d_path=$(dirname "$sh_f")
    [[ -f "${d_path}/properties.conf" ]] && sed -i "s/MAX_MEMORY=.*/MAX_MEMORY=${MEM_LIMIT}/" "${d_path}/properties.conf" 2>/dev/null || true
    if [[ -f "$sh_f" ]]; then
      sed -i 's/--sysctl net.ipv6.conf.[a-z0-9_]*.disable_ipv6=[0-9]//g' "$sh_f" 2>/dev/null || true
      grep -q "\--restart" "$sh_f" || sed -i "s/docker run -d/docker run -d --restart=unless-stopped/g" "$sh_f" 2>/dev/null || true
      grep -q "\--memory" "$sh_f" || sed -i "s/docker run -d/docker run -d --memory=\"${MEM_LIMIT}\" --memory-swap=\"${SWAP_LIMIT}\"/g" "$sh_f" 2>/dev/null || true

      sed -i "s/--memory=\"[0-9]*[a-z]*\"/--memory=\"${MEM_LIMIT}\"/g" "$sh_f" 2>/dev/null || true
      sed -i "s/--memory-swap=\"[0-9]*[a-z]*\"/--memory-swap=\"${SWAP_LIMIT}\"/g" "$sh_f" 2>/dev/null || true

      sed -i -E '/mysterium|myst/I s/--memory="[0-9]+[a-zA-Z]+"/--memory="250m"/g' "$sh_f" 2>/dev/null || true
      sed -i -E '/mysterium|myst/I s/--memory-swap="[0-9]+[a-zA-Z]+"/--memory-swap="500m"/g' "$sh_f" 2>/dev/null || true

      sed -i -E '/wipter/I s/--memory="[0-9]+[a-zA-Z]+"/--memory="350m"/g' "$sh_f" 2>/dev/null || true
      sed -i -E '/wipter/I s/--memory-swap="[0-9]+[a-zA-Z]+"/--memory-swap="600m"/g' "$sh_f" 2>/dev/null || true
    fi
  done < <(find "${ROOTS[@]}" -maxdepth 4 -name internetIncome.sh -type f 2>/dev/null | sort -u)

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

    docker update --restart=unless-stopped $(docker ps -aq 2>/dev/null || true) >/dev/null 2>&1 || true
    for cid in $(docker ps -aq 2>/dev/null); do
      c_img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
      c_name=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null || true)
      if [[ "$c_img" =~ mysterium|myst ]] || [[ "$c_name" =~ mysterium|myst ]]; then
        docker update --memory="250m" --memory-swap="500m" "$cid" >/dev/null 2>&1 || true
      elif [[ "$c_img" =~ wipter ]] || [[ "$c_name" =~ wipter ]]; then
        docker update --memory="350m" --memory-swap="600m" "$cid" >/dev/null 2>&1 || true
      fi
    done

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

15 4 * * 0 root /usr/local/bin/ii-restart-all.sh
*/15 * * * * root docker ps -aq -f status=exited 2>/dev/null | xargs -r -n1 docker start >/dev/null 2>&1
0 3 * * 0 root /usr/bin/docker network prune -f >/dev/null 2>&1
15 3 * * 0 root /usr/bin/docker volume prune -f >/dev/null 2>&1
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

cat > /usr/local/bin/ii-status.sh <<'EOF_STATUS'
#!/usr/bin/env bash
set -u

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

echo -e "${C_B}==================== [ORACLE CLOUD 24/7 QUALITY DIAGNOSTIC] ====================${C_0}"
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "HOSTNAME     : $(hostname)"
echo "UPTIME       : $(uptime -p 2>/dev/null || uptime)"
echo "KERNEL/ARCH  : $(uname -r) ($(uname -m))"

ISSUES_COUNT=0
WARNINGS_COUNT=0

# --- 1. DOCKER CONTAINERS & RAM AUDIT ---
echo -e "\n${C_C}--- [1. NODE CONTAINERS & RAM LIMIT AUDIT] ---${C_0}"
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

if (( found == 0 )); then echo "  (No InternetIncome folders found)"; fi

RUNNING_CTRS=$(docker ps -q 2>/dev/null | wc -l)
TOTAL_CTRS=$(docker ps -aq 2>/dev/null | wc -l)
EXITED_CTRS=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
echo "  TOTAL SUMMARY: ${RUNNING_CTRS} running / ${TOTAL_CTRS} total (Exited: ${EXITED_CTRS})"

# --- 2. NETWORK, PROXY & ROUTING HEALTH ---
echo -e "\n${C_C}--- [2. NETWORK, PROXY & ROUTING HEALTH] ---${C_0}"
IP_FWD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
if [[ "$IP_FWD" == "1" ]]; then
  echo -e "  IP Forwarding (Routing)  : ${C_G}ENABLED (1)${C_0}"
else
  echo -e "  IP Forwarding (Routing)  : ${C_R}DISABLED (0) <-- CRITICAL!${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
fi

NTP_STAT=$(timedatectl status 2>/dev/null | grep "NTP service" | awk '{print $3}' || echo "unknown")
if [[ "$NTP_STAT" == "active" || "$NTP_STAT" == "yes" ]]; then
  echo -e "  NTP Time Sync Status    : ${C_G}ACTIVE (Strict millisecond accuracy)${C_0}"
else
  echo -e "  NTP Time Sync Status    : ${C_Y}INACTIVE (${NTP_STAT})${C_0}"
  WARNINGS_COUNT=$((WARNINGS_COUNT+1))
fi

DNS_START=$(date +%s%N 2>/dev/null || echo 0)
DNS_RES=$(timeout 2 host google.com 1.1.1.1 2>/dev/null || timeout 2 host google.com 8.8.8.8 2>/dev/null || echo "")
DNS_END=$(date +%s%N 2>/dev/null || echo 0)
if [[ -n "$DNS_RES" ]]; then
  DNS_MS=$(( (DNS_END - DNS_START) / 1000000 ))
  echo -e "  DNS Resolution (Google) : ${C_G}OK (${DNS_MS}ms)${C_0}"
else
  echo -e "  DNS Resolution (Google) : ${C_Y}CHECK_TIMEOUT (Fallback active)${C_0}"
fi

HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}\t%{time_total}" --connect-timeout 2 --max-time 3 http://1.1.1.1 2>/dev/null || curl -o /dev/null -s -w "%{http_code}\t%{time_total}" --connect-timeout 2 --max-time 3 -k https://google.com 2>/dev/null || echo "000 0")
CODE=$(echo "$HTTP_CODE" | awk '{print $1}')
TIME=$(echo "$HTTP_CODE" | awk '{print $2}')
if [[ "$CODE" == "200" || "$CODE" == "301" || "$CODE" == "302" ]]; then
  echo -e "  Outbound Internet Latency: ${C_G}ONLINE (HTTP ${CODE} in ${TIME}s)${C_0}"
else
  echo -e "  Outbound Internet Latency: ${C_R}BLOCKED / TIMEOUT (No Internet)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
fi

CONN_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CONN_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
CONN_PCT=$(( CONN_COUNT * 100 / CONN_MAX ))
echo "  Conntrack Active Streams: ${CONN_COUNT} / ${CONN_MAX} (${CONN_PCT}% max)"

# --- 3. SYSTEM RAM, SWAP & ZRAM HEALTH ---
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
  echo -e "  ZRAM : ${C_G}ACTIVE (${ZRAM_SIZE} LZ4 Priority 10)${C_0}"
else
  echo -e "  ZRAM : ${C_Y}NOT ACTIVE (Performance penalty)${C_0}"
  WARNINGS_COUNT=$((WARNINGS_COUNT+1))
fi

# --- 4. CPU LOAD & DISK / FILESYSTEM HEALTH ---
echo -e "\n${C_C}--- [4. CPU, DISK I/O & FILESYSTEM HEALTH] ---${C_0}"
LOAD_1=$(cat /proc/loadavg | awk '{print $1}')
CPUS=$(nproc 2>/dev/null || echo 1)
echo "  CPU Cores: ${CPUS} | Load Avg (1m): ${LOAD_1}"

DISK_USE_PCT=$(df / | awk 'NR==2{print $5}' | tr -d '%')
if (( DISK_USE_PCT > 90 )); then
  echo -e "  Disk Storage Usage     : ${C_R}${DISK_USE_PCT}% used (FULL RISK!)${C_0}"
  ISSUES_COUNT=$((ISSUES_COUNT+1))
else
  echo -e "  Disk Storage Usage     : ${C_G}${DISK_USE_PCT}% used${C_0}"
fi

# --- 5. 24/7 INCOME STABILITY SUMMARY ---
echo -e "\n${C_B}---------------- [OCI INCOME DIAGNOSTIC SUMMARY] ----------------${C_0}"
SCORE=100
SCORE=$(( SCORE - (ISSUES_COUNT * 20) - (WARNINGS_COUNT * 5) ))
if (( SCORE < 0 )); then SCORE=0; fi

if (( ISSUES_COUNT == 0 && WARNINGS_COUNT == 0 )); then
  echo -e "  OVERALL SCORE : ${C_G}100% PERFECT${C_0} - Oracle Cloud VPS is 100% optimal!"
  echo -e "  STATUS        : ${C_G}[HEALTHY_SMOOTH_24_7]${C_0} No action required."
elif (( ISSUES_COUNT == 0 )); then
  echo -e "  OVERALL SCORE : ${C_Y}${SCORE}% GOOD${C_0} - System running fine with minor warnings."
  echo -e "  STATUS        : ${C_Y}[STABLE_WITH_WARNINGS]${C_0} Run 'sudo bash /root/setup_oracle_cloud.sh'."
else
  echo -e "  OVERALL SCORE : ${C_R}${SCORE}% UNSTABLE (${ISSUES_COUNT} Critical Issues Found!)${C_0}"
  echo -e "  STATUS        : ${C_R}[INCOME_RISK_DETECTED]${C_0} Run 'sudo bash /root/setup_oracle_cloud.sh'!"
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

cp -f /root/setup_oracle_cloud.sh /home/ubuntu/setup_oracle_cloud.sh 2>/dev/null || true
cp -f /root/setup_oracle_cloud.sh /home/opc/setup_oracle_cloud.sh 2>/dev/null || true

echo "============================= SETUP XONG (100% AUTO-PILOT OCI MASTER 2026 - ULTIMATE) =============================="
/usr/local/bin/ii-status.sh || true
ORACLE_MASTER_EOF

chmod +x /root/setup_oracle_cloud.sh /home/ubuntu/setup_oracle_cloud.sh 2>/dev/null || true
sudo bash /home/ubuntu/setup_oracle_cloud.sh

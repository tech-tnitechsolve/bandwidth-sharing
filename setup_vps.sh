#!/usr/bin/env bash
#============================================================================
#  setup_vps.sh (FINAL ULTIMATE MASTER 2026) - OPTIMIZED FOR ALL CASES
#
#  TU DONG HOA 100% ZERO-TOUCH CHO REPO: github.com/engageub/InternetIncome
#   - SOCKET BUFFER SIẾT: Siết tcp_rmem/tcp_wmem giảm 80% RAM ngầm Kernel.
#   - AUTO-PATCHER ENGAGEUB: Tu dong quet tat ca folder engageub/InternetIncome
#     va chen co --memory="40m" --memory-swap="40m" vao internetIncome.sh.
#   - TUN2SOCKS OPTIMIZE: Bat net.ipv4.ip_forward=1 cho card mang ao TUN.
#   - KILL RAM NGẦM: Tat userland-proxy, go snapd, tat THP, siet journald.
#   - TCP BBR: Bat thuat toan Google BBR tang toc do Proxy & thu nhap.
#   - WATCHDOG 15m: Quet va tu phuc hoi container chet ngam moi 15 phut.
#   - STAGGERED START: Bat/Restart container TU TU (nghi 1.5s/container).
#============================================================================
set -Eeuo pipefail

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

has_systemd() { command -v systemctl >/dev/null 2>/dev/null && [[ -d /run/systemd/system ]]; }

if [[ -n "$BASE_DIR" ]]; then
  if [[ -d "$BASE_DIR" ]]; then
    log "Quet them thu muc: ${BASE_DIR}"
  else
    warn "--base-dir '${BASE_DIR}' KHONG ton tai -> bo qua."
    BASE_DIR=""
  fi
fi

#------------------------------- THONG TIN HE THONG --------------------------
VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
IS_CONTAINER=0
case "$VIRT" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1 ;; esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)

CONTAINER_MEM_LIMIT="40m"
if (( MEM_MB <= 1200 )); then
  CONTAINER_MEM_LIMIT="35m"
elif (( MEM_MB <= 2500 )); then
  CONTAINER_MEM_LIMIT="40m"
elif (( MEM_MB <= 5000 )); then
  CONTAINER_MEM_LIMIT="60m"
else
  CONTAINER_MEM_LIMIT="80m"
fi

#----------------------------------- 1. SWAP ---------------------------------
if (( MEM_MB <= 1200 )); then          # ~1.0 GB RAM
  TARGET_SWAP_MB=1536; SWAPPINESS=10
elif (( MEM_MB <= 1700 )); then        # ~1.5 GB RAM
  TARGET_SWAP_MB=1536; SWAPPINESS=10
elif (( MEM_MB <= 2500 )); then        # ~2.0 GB RAM
  TARGET_SWAP_MB=2048; SWAPPINESS=10
elif (( MEM_MB <= 3500 )); then        # ~3.0 GB RAM
  TARGET_SWAP_MB=2048; SWAPPINESS=10
elif (( MEM_MB <= 5000 )); then        # ~4.0 GB RAM
  TARGET_SWAP_MB=3072; SWAPPINESS=15
elif (( MEM_MB <= 7000 )); then        # ~6.0 GB RAM
  TARGET_SWAP_MB=3072; SWAPPINESS=15
elif (( MEM_MB <= 10000 )); then       # ~8.0 GB RAM
  TARGET_SWAP_MB=4096; SWAPPINESS=20
elif (( MEM_MB <= 14000 )); then       # ~12.0 GB RAM
  TARGET_SWAP_MB=4096; SWAPPINESS=20
else                                   # >= 16.0 GB RAM
  TARGET_SWAP_MB=4096; SWAPPINESS=10
fi

DISK_FREE_MB=$(df -m / | awk 'NR==2 {print $4}')
MAX_SAFE_SWAP=$(( DISK_FREE_MB - 2048 ))
if (( MAX_SAFE_SWAP < 512 )); then MAX_SAFE_SWAP=512; fi
if (( TARGET_SWAP_MB > MAX_SAFE_SWAP )); then
  warn "Disk / con trong ${DISK_FREE_MB}MB -> gioi han Swap o ${MAX_SAFE_SWAP}MB de an toan"
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
echo "  VPS $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU | FINAL ULTIMATE MASTER"
echo "  Swap target=${TARGET_SWAP_MB}MB | Swappiness=${SWAPPINESS} | Container Limit=${CONTAINER_MEM_LIMIT}"
echo "=============================================================="

CURR_SWAP_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}' || echo 0)
SWAP_USED_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $3}' || echo 0)
RAM_AVAIL_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 0)

if (( IS_CONTAINER == 1 )); then
  warn "May ${VIRT} (container) thuong KHONG tao duoc swap -> bo qua"
elif (( CURR_SWAP_MB >= TARGET_SWAP_MB - 256 )) && (( CURR_SWAP_MB <= TARGET_SWAP_MB + 512 )); then
  log "Da co swap ${CURR_SWAP_MB}MB (Dat chi tieu ~${TARGET_SWAP_MB}MB) -> giu nguyen"
else
  REBUILD_SWAP=1
  if (( CURR_SWAP_MB > TARGET_SWAP_MB + 512 )); then
    if (( SWAP_USED_MB > RAM_AVAIL_MB - 200 )); then
      warn "Swap hien tai (${CURR_SWAP_MB}MB) dang dung ${SWAP_USED_MB}MB, RAM con trong ${RAM_AVAIL_MB}MB."
      warn "-> KHONG thu hoi Swap luc nay de TRANH SAP CONTAINER. Se ap dung Swappiness=${SWAPPINESS} truc tiep!"
      REBUILD_SWAP=0
    else
      log "Swap cu lon hon muc toi uu, RAM du an toan -> Tien hanh thu hoi & tao lai ${TARGET_SWAP_MB}MB..."
      swapoff -a 2>/dev/null || true
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
    if mkswap "$SWAP_TARGET_FILE" >/dev/null 2>&1 && swapon "$SWAP_TARGET_FILE" 2>/dev/null; then
      grep -q "^${SWAP_TARGET_FILE}" /etc/fstab || echo "${SWAP_TARGET_FILE} none swap sw 0 0" >> /etc/fstab
      log "Tao swap ${SWAP_TARGET_FILE} ${NEEDED_SWAP_MB}MB thanh cong"
    else
      rm -f "$SWAP_TARGET_FILE"
      warn "Kernel khong cho tao swap -> bo qua"
    fi
  fi
fi

#------------------ 2. DIỆT BLOATWARE OS ĐỂ GIẢM RAM NGẦM ------------------
log "Dang diet cac dich vu OS ngom RAM ngam (snapd, multipathd, udisks2)..."
if has_systemd; then
  systemctl stop snapd multipathd udisks2 accountsservice 2>/dev/null || true
  systemctl disable snapd multipathd udisks2 accountsservice 2>/dev/null || true
fi
apt-get purge -y snapd 2>/dev/null || true
rm -rf /var/cache/snapd/ /var/lib/snapd/ 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

log "apt update + upgrade..."
apt-get update -y -qq
apt-get upgrade -y -qq || true
apt-get install -y -qq --no-install-recommends \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools earlyoom \
  vnstat nload speedtest-cli
apt-get autoremove -y -qq >/dev/null 2>&1 || true

MAIN_IF=$(ip route 2>/dev/null | grep default | awk '{print $5}' | head -n1 || echo "")
if [[ -f /etc/vnstat.conf ]]; then
  if [[ -n "$MAIN_IF" ]]; then
    sed -i "s/Interface \".*\"/Interface \"$MAIN_IF\"/" /etc/vnstat.conf
  fi
  grep -q 'ExcludeInterface' /etc/vnstat.conf || echo 'ExcludeInterface "veth* docker0 tun* tap*"' >> /etc/vnstat.conf
  if has_systemd; then systemctl restart vnstat 2>/dev/null || true; fi
fi

if [[ -f /etc/default/earlyoom ]]; then
  cat > /etc/default/earlyoom <<'EOF'
EARLYOOM_ARGS="-m 3 -s 5 --avoid '^(sshd|systemd|cron)$'"
EOF
fi
if has_systemd; then systemctl enable --now earlyoom >/dev/null 2>&1 || true; fi

timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true

mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

#--------------------------------- 3. DNS SACH 4 LỚP -------------------------------
if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
fi
rm -f /etc/resolv.conf
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\nnameserver 9.9.9.9\nnameserver 1.0.0.1\n' > /etc/resolv.conf

#------------------- 4. KERNEL TUNING + BBR + TUN2SOCKS + SOCKET BUFFER SIẾT -------------------
modprobe nf_conntrack 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true

# Tat Transparent Huge Pages nguu ngoc gay phin RAM ngam
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

SYSCTL_FILE=/etc/sysctl.d/99-internetincome.conf
cat > "$SYSCTL_FILE" <<EOF
#--- TCP BBR (TĂNG TỐC BĂNG THÔNG PROXY) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

#--- CẤU HÌNH IP_FORWARD QUAN TRỌNG CHO TUN2SOCKS ENGAGEUB ---
net.ipv4.ip_forward = 1

#--- SIẾT BỘ NHỚ ĐỆM SOCKET TCP ĐỂ CHỐNG PHÌNH RAM NGẦM KERNEL ---
net.ipv4.tcp_rmem = 4096 16384 1048576
net.ipv4.tcp_wmem = 4096 16384 1048576

#--- EXTREME OVERCOMMIT & CHỐNG PHÌNH RAM CACHE ---
vm.overcommit_memory = 1
vm.swappiness = ${SWAPPINESS}
vm.vfs_cache_pressure = 125
vm.dirty_background_ratio = 3
vm.dirty_ratio = 8

#--- InternetIncome tuning ---
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
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
EOF

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue
  sysctl -w "$line" >/dev/null 2>&1 || true
done < "$SYSCTL_FILE"
log "Kernel Tuning + BBR + IP_Forward + Socket Buffer Siết xong"

if [[ -f /etc/sysctl.d/99-vps-optimize.conf ]]; then
  rm -f /etc/sysctl.d/99-vps-optimize.conf
fi

mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/99-nofile.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-ii-limit.conf <<'EOF'
[Journal]
SystemMaxUse=10M
RuntimeMaxUse=5M
EOF
if has_systemd; then systemctl restart systemd-journald 2>/dev/null || true; fi

#------------------- 5. AUTO-PATCHER ENGAGEUB: TỰ ĐỘNG KHÓA RAM CONTAINER -------------------
auto_patch_engageub_repo() {
  log "Dang quet va KHÓA RAM (${CONTAINER_MEM_LIMIT}) cho repo engageub/InternetIncome..."
  ROOTS=(/opt /root /home /srv)
  if [[ -n "$BASE_DIR" ]]; then ROOTS+=("$BASE_DIR"); fi

  while IFS= read -r sh_file; do
    d=$(dirname "$sh_file")
    if [[ -f "${d}/properties.conf" ]]; then
      if grep -q "MAX_MEMORY=" "${d}/properties.conf"; then
        sed -i "s/MAX_MEMORY=.*/MAX_MEMORY=${CONTAINER_MEM_LIMIT}/" "${d}/properties.conf"
      else
        echo "MAX_MEMORY=${CONTAINER_MEM_LIMIT}" >> "${d}/properties.conf"
      fi
      log "-> Da tu dong update MAX_MEMORY=${CONTAINER_MEM_LIMIT} tai ${d}/properties.conf"
    fi

    if [[ -f "$sh_file" ]]; then
      if ! grep -q "\--memory" "$sh_file"; then
        cp -n "$sh_file" "${sh_file}.bak" 2>/dev/null || true
        sed -i "s/docker run -d/docker run -d --memory=\"${CONTAINER_MEM_LIMIT}\" --memory-swap=\"${CONTAINER_MEM_LIMIT}\"/g" "$sh_file"
        log "-> Da tu dong patch co --memory=\"${CONTAINER_MEM_LIMIT}\" vao ${sh_file}"
      fi
    fi
  done < <(find "${ROOTS[@]}" -maxdepth 4 -name internetIncome.sh -type f 2>/dev/null | sort -u)
}
auto_patch_engageub_repo

#------------------ 6. DOCKER (TẮT USERLAND-PROXY DIỆT HÀNG TRĂM PROCESS ĐỌC PORT) ------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Cai dat Docker..."
  curl -fsSL https://get.docker.com | sh
else
  log "Docker da co san: $(docker --version 2>/dev/null || echo '?')"
fi

mkdir -p /etc/docker
NEW_DAEMON="$(cat <<EOF
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
EOF
)"

DOCKER_RESTARTED=0
if [[ -f /etc/docker/daemon.json ]] && printf '%s\n' "$NEW_DAEMON" | cmp -s - /etc/docker/daemon.json; then
  log "daemon.json khong thay doi -> KHONG DUNG DOCKER (Container giu nguyen 100%)"
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
docker info >/dev/null 2>&1 || die "Docker khong chay duoc - kiem tra ao hoa/kernel"

if (( DOCKER_RESTARTED == 1 )); then
  sleep 10
  log "Dang bat lai cac container engageub TU TU (nghi 1.5s/container chong nghen CPU)..."
  
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

RUNNING_AFTER=$(docker ps -q 2>/dev/null | wc -l)
log "Docker OK (userland-proxy=disabled | live-restore on)"

#------------------------------- 7. PRE-PULL IMAGE ---------------------------
if (( DO_PULL == 1 )); then
  for img in "traffmonetizer/cli_v2:latest" "xjasonlyu/tun2socks:latest"; do
    docker pull "$img" >/dev/null 2>&1 || true
  done
  docker pull ghcr.io/xjasonlyu/tun2socks:latest >/dev/null 2>&1 || true
fi

#---------------------- 8. CRON 04:15 + WATCHDOG 15M ----------------
install_cron_stack() {
  cat > /usr/local/bin/ii-restart-all.sh <<'EOS'
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
EOS
  if [[ -n "$BASE_DIR" ]]; then
    sed -i "s|__EXTRA__|\"${BASE_DIR}\"|" /usr/local/bin/ii-restart-all.sh
  else
    sed -i "s| __EXTRA__||" /usr/local/bin/ii-restart-all.sh
  fi
  chmod +x /usr/local/bin/ii-restart-all.sh

  cat > /etc/cron.d/internetincome <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 04:15 hang ngay: restart cuon chieu bao tri + drop cache RAM
15 4 * * * root /usr/local/bin/ii-restart-all.sh

# 15 phut/lan: WATCHDOG tu dong bat lai container bi chet ngam (Exited)
*/15 * * * * root docker ps -aq -f status=exited 2>/dev/null | xargs -r -n1 docker start >/dev/null 2>&1

# 05:30 chu nhat: don dẹp image rac
30 5 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1
EOF
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

#------------------ CONG CU ii-status.sh (CHECK CHO ENGAGEUB REPO) ------------------
cat > /usr/local/bin/ii-status.sh <<'EOS'
#!/usr/bin/env bash
ROOTS=("$@")
if (( ${#ROOTS[@]} == 0 )); then ROOTS=(/opt /root /home /srv); fi

echo "===== ENGAGEUB INTERNETINCOME STATUS ====="
found=0
while IFS= read -r cn; do
  d=$(dirname "$cn")
  [[ -f "${d}/internetIncome.sh" ]] || continue
  found=1
  total=$(grep -c . "$cn" 2>/dev/null || echo 0)
  running=0
  while IFS= read -r c; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]] && running=$((running+1))
  done < "$cn"
  mark=""
  (( running < total )) && mark="  <-- THIEU $((total-running))"
  printf "  %-46s %4s/%-4s running%s\n" "$d" "$running" "$total" "$mark"
done < <(find "${ROOTS[@]}" -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)
if (( found == 0 )); then echo "  (chua thay folder engageub/InternetIncome nao)"; fi

echo "----- TÀI NGUYÊN HỆ THỐNG ĐÃ TỐI ƯU DEEP RAM & SOCKETS -----"
RUNNING_CTRS=$(docker ps -q 2>/dev/null | wc -l)
TOTAL_CTRS=$(docker ps -aq 2>/dev/null | wc -l)
echo "  Docker    : ${RUNNING_CTRS} running / ${TOTAL_CTRS} total"
free -h | awk '/^Mem:/{printf "  RAM       : %s/%s dang dung (Con trong: %s)\n",$3,$2,$7} /^Swap:/{printf "  Swap      : %s/%s dang dung\n",$3,$2}'
df -h / | awk 'NR==2{printf "  Disk /    : %s/%s (%s)\n",$3,$2,$5}'

RAM_AVAIL_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}' || echo 999)
SWAP_FREE_MB=$(free -m 2>/dev/null | awk '/^Swap:/{print $4}' || echo 999)

echo -e "\n---------------- 🚀 TRẠNG THÁI ENGAGEUB INTERNETINCOME ----------------"
if (( RAM_AVAIL_MB < 30 )) && (( SWAP_FREE_MB < 100 )); then
  echo -e "  \033[1;31m[🚨 NGUY CƠ CRASH]\033[0m Bo nho ao sap can kiet! VPS co the bi sap neu nhoi them node!"
else
  echo -e "  \033[1;32m[🔥 OPTIMIZED SUCCESS]\033[0m Da triet ha RAM ngam OS & Socket Buffer! Dang chay ${RUNNING_CTRS} Container engageub rat muot!"
fi
EOS
chmod +x /usr/local/bin/ii-status.sh

echo "============================= SETUP XONG (FINAL ULTIMATE MASTER) =============================="
/usr/local/bin/ii-status.sh || true

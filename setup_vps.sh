#!/usr/bin/env bash
#============================================================================
#  setup_vps.sh (FINAL) - SETUP VPS CHAY 24/7 CHO INTERNETINCOME
#
#  TU DONG HOA 100% - chi can:  sudo bash setup_vps.sh
#   - KHONG tu tai source: ban tu copy folder InternetIncome vao VPS
#     (toi uu cho chay NHIEU folder InternetIncome tren 1 VPS).
#   - IDEMPOTENT: chay lai bao nhieu lan cung an toan. Chil restart docker
#     neu daemon.json THAT SU doi (lan dau); cac lan sau KHONG dung container.
#   - Cron 04:15 hang ngay: helper TU QUET folder trong /opt /root /home /srv
#     (khong can khai bao thu muc, khong hoi tay, folder them sau tu duoc nhan).
#   - Tu chua 3 benh docker da gap:
#       1) Exited (128) do race --network=container:tun* (moby/moby#50326)
#       2) "task ... already exists" do shim containerd ket (moby/moby#50040)
#       3) short ID khong giai duoc task containerd (bat buoc --no-trunc)
#
#  THAM SO (khong bat buoc):
#   --base-dir DIR   : quet THEM thu muc DIR ngoai 4 root mac dinh
#   --no-cron        : bo qua cron restart hang ngay
#   --no-pull        : bo qua pre-pull image docker
#   -h|--help        : xem huong dan
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

# Validate --base-dir (chong typo kieu /home/ubunt): ton tai moi dung
if [[ -n "$BASE_DIR" ]]; then
  if [[ -d "$BASE_DIR" ]]; then
    log "Quet them thu muc: ${BASE_DIR}"
  else
    warn "--base-dir '${BASE_DIR}' KHONG ton tai -> bo qua (kiem tra lai chinh ta)."
    warn "Luu y: mac dinh helper da tu quet /opt /root /home /srv, hau nhu KHONG can tham so nay."
    BASE_DIR=""
  fi
fi

#------------------------------- THONG TIN HE THONG --------------------------
VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
IS_CONTAINER=0
case "$VIRT" in lxc|lxc-libvirt|openvz) IS_CONTAINER=1 ;; esac

MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
CPU=$(nproc 2>/dev/null || echo 1)

SWAP_MB=$(( MEM_MB / 2 ))
if (( SWAP_MB < 1024 )); then SWAP_MB=1024; fi
if (( SWAP_MB > 8192 )); then SWAP_MB=8192; fi

if (( CPU <= 2 )); then
  CONCURRENT_DOWNLOADS=3; SYN_BACKLOG=8192
elif (( CPU <= 4 )); then
  CONCURRENT_DOWNLOADS=5; SYN_BACKLOG=16384
else
  CONCURRENT_DOWNLOADS=8; SYN_BACKLOG=32768
fi

echo "=============================================================="
echo "  VPS $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU | ao hoa: ${VIRT}"
echo "  swap=${SWAP_MB}MB | docker parallel downloads=${CONCURRENT_DOWNLOADS}"
echo "=============================================================="
if (( MEM_MB < 1800 )); then
  warn "RAM ${MEM_MB}MB kha nho -> voi stack nhieu app, mo MAX_MEMORY=256m va CPU=0.35 trong properties.conf tung folder"
fi

#----------------------------------- 1. SWAP ---------------------------------
if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
  log "Da co swap -> bo qua"
elif (( IS_CONTAINER == 1 )); then
  warn "May ${VIRT} (container) thuong KHONG tao duoc swap -> bo qua"
else
  if ! fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
  fi
  chmod 600 /swapfile
  if mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Tao swap ${SWAP_MB}MB thanh cong"
  else
    rm -f /swapfile
    warn "Kernel khong cho tao swap -> bo qua (van chay duoc)"
  fi
fi

#------------------------------ 2. APT KHONG HOI -----------------------------
export DEBIAN_FRONTEND=noninteractive
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

log "apt update + upgrade..."
apt-get update -y -qq
apt-get upgrade -y -qq || true
apt-get install -y -qq --no-install-recommends \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools earlyoom
apt-get autoremove -y -qq >/dev/null 2>&1 || true
log "Da cai goi co ban (curl/wget/git/jq/bc/cron/logrotate/earlyoom...)"

# Chong OOM lam treo may (earlyoom tu giet bot tre an RAM, cuu SSH)
if has_systemd; then systemctl enable --now earlyoom >/dev/null 2>&1 || true; fi
# Gio he thong phai dung (TLS/DoH loi neu gio sai) + mui gio VN de cron 04:15 chay dung 4h sang
timedatectl set-ntp true 2>/dev/null || true
timedatectl set-timezone Asia/Ho_Chi_Minh 2>/dev/null || true
# Khong tu reboot vi ban cap nhat (treo may 24/7 phai on dinh)
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF'
// InternetIncome VPS - khong tu khoi dong lai vi unattended-upgrades
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

#--------------------------------- 3. DNS SACH -------------------------------
if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
fi
rm -f /etc/resolv.conf
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
log "resolv.conf -> 8.8.8.8 + 1.1.1.1 (khong chattr, de linh hoat)"

#------------------------------- 4. KERNEL TUNING ----------------------------
modprobe nf_conntrack 2>/dev/null || true
SYSCTL_FILE=/etc/sysctl.d/99-internetincome.conf
cat > "$SYSCTL_FILE" <<EOF
#--- InternetIncome tuning (nhieu container SOCKS5/UDP) ---
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
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_slow_start_after_idle = 0

net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 180

vm.swappiness = 10
vm.vfs_cache_pressure = 50

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue
  sysctl -w "$line" >/dev/null 2>&1 || true
done < "$SYSCTL_FILE"
log "Kernel tuning xong ($SYSCTL_FILE - dong khong ho tro tu bo qua)"

# Tu dong don file sysctl cua setup.sh cu (tranh 2 nguon config chong lap)
if [[ -f /etc/sysctl.d/99-vps-optimize.conf ]]; then
  rm -f /etc/sysctl.d/99-vps-optimize.conf
  log "Da don /etc/sysctl.d/99-vps-optimize.conf (config cua setup.sh cu)"
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
SystemMaxUse=50M
RuntimeMaxUse=20M
EOF
if has_systemd; then systemctl restart systemd-journald 2>/dev/null || true; fi
log "Gioi han journald 50MB + nofile 1048576"

#---------------------------------- 5. DOCKER --------------------------------
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
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "dns": ["8.8.8.8", "1.1.1.1"],
  "max-concurrent-downloads": ${CONCURRENT_DOWNLOADS},
  "live-restore": true,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 }
  }
}
EOF
)"

# Chi viet lai + restart docker khi config THAT SU thay doi
# -> chay lai script nhieu lan KHONG lam dung container dang chay
DOCKER_RESTARTED=0
if [[ -f /etc/docker/daemon.json ]] && printf '%s\n' "$NEW_DAEMON" | cmp -s - /etc/docker/daemon.json; then
  log "daemon.json khong thay doi -> bo qua viet lai & restart docker"
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

# Revive 3 lop (chi can khi daemon vua restart):
#  L1: container dung --network=container:tun* thua race khi daemon restart -> Exited 128
#      (moby/moby#50326) -> start lai theo containernames.txt
#  L2: shim containerd ket -> loi start "task ... already exists" (moby/moby#50040)
#      -> ctr task kill/rm bang FULL ID (L3: --no-trunc) roi start lai
if (( DOCKER_RESTARTED == 1 )); then
  sleep 15
  find /opt /root /home /srv -maxdepth 4 -name containernames.txt -type f -exec cat {} + 2>/dev/null \
    | xargs -r docker start >/dev/null 2>&1 || true
  if command -v ctr >/dev/null 2>&1; then
    for cid in $(docker ps -aq --no-trunc -f status=exited 2>/dev/null); do
      ctr -n moby task kill -s SIGKILL "$cid" >/dev/null 2>&1 || true
      ctr -n moby task rm "$cid" >/dev/null 2>&1 || true
    done
  fi
  docker ps -aq -f status=exited 2>/dev/null | xargs -r -n1 docker start >/dev/null 2>&1 || true
  log "Da revive container Exited sau restart docker (ke ca task containerd ket)"
fi
RUNNING_AFTER=$(docker ps -q 2>/dev/null | wc -l)
log "Docker OK (log 10MBx3 | DNS 8.8.8.8+1.1.1.1 | live-restore on)"
if (( DOCKER_RESTARTED == 1 )) && (( ${RUNNING_BEFORE:-0} > 0 )); then
  if (( RUNNING_AFTER == RUNNING_BEFORE )); then
    log "Container dang chay duoc GIU NGUYEN qua restart docker: ${RUNNING_AFTER}/${RUNNING_BEFORE}"
  else
    warn "Container truoc=${RUNNING_BEFORE} sau=${RUNNING_AFTER} - kiem tra: docker ps -a"
  fi
fi

#------------------------------- 6. PRE-PULL IMAGE ---------------------------
if (( DO_PULL == 1 )); then
  for img in "traffmonetizer/cli_v2:latest" "xjasonlyu/tun2socks:latest"; do
    if docker pull "$img" >/dev/null 2>&1; then
      log "pull OK: $img"
    else
      warn "pull loi: $img (se tu pull lai luc --start)"
    fi
  done
  if docker pull ghcr.io/xjasonlyu/tun2socks:latest >/dev/null 2>&1; then
    log "pull OK: ghcr.io/xjasonlyu/tun2socks (du phong)"
  fi
else
  log "Bo qua pre-pull (--no-pull)"
fi

#---------------------- 7. CRON 04:15 (helper TU QUET folder) ----------------
# Thiet ke khong-BASE_DIR: helper tu tim containernames.txt trong 4 root moi lan
# chay -> khong hoi tay, khong typo, folder them sau tu dong duoc nhan.
install_cron_stack() {
  cat > /usr/local/bin/ii-restart-all.sh <<'EOS'
#!/usr/bin/env bash
# ii-restart-all.sh - TU QUET & restart MOI folder InternetIncome
# - Tim containernames.txt trong /opt /root /home /srv (toi 4 tang), sort -u chong trung.
# - Khong dung BASE_DIR co dinh -> folder them/xoa TU DONG duoc nhan dien moi lan chay.
# - Co don task containerd ket (loi "AlreadyExists", moby/moby#50040) + revive Exited.
LOG=/var/log/ii-restart.log
ROOTS=(/opt /root /home /srv __EXTRA__)
ts() { date '+%F %T'; }
HAVE_CTR=0; command -v ctr >/dev/null 2>&1 && HAVE_CTR=1

{
  echo "[$(ts)] ==================== ii-restart-all ===================="
  mapfile -t FILES < <(find "${ROOTS[@]}" -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)
  if (( ${#FILES[@]} == 0 )); then
    echo "[$(ts)] chua thay folder nao (chua --start hoac khong trong ${ROOTS[*]})"
  else
    # Don task containerd ket TRUOC de "docker restart" khoi gap loi AlreadyExists
    STUCK=$(docker ps -aq --no-trunc -f status=exited 2>/dev/null || true)
    if (( HAVE_CTR == 1 )) && [[ -n "$STUCK" ]]; then
      for cid in $STUCK; do
        ctr -n moby task kill -s SIGKILL "$cid" >/dev/null 2>&1
        ctr -n moby task rm "$cid" >/dev/null 2>&1
      done
      echo "[$(ts)] da don task containerd ket (neu co)"
    fi
    TOTAL=0
    for cn in "${FILES[@]}"; do
      d=$(dirname "$cn")
      [[ -f "${d}/internetIncome.sh" ]] || continue
      n=$(grep -c . "$cn" 2>/dev/null || echo 0)
      TOTAL=$((TOTAL+n))
      echo "[$(ts)] >>> ${d} (${n} container)"
      xargs -r -a "$cn" docker restart 2>&1 || echo "[$(ts)] !! loi restart tai ${d}"
      sleep 15
    done
    # Revive: container thuoc cac folder con Exited -> start lai
    # (docker start tren container dang chay = no-op, khong hai)
    sleep 10
    cat "${FILES[@]}" 2>/dev/null | xargs -r docker start >/dev/null 2>&1
    STILL=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
    echo "[$(ts)] xong: ${TOTAL} container / ${#FILES[@]} folder | con Exited: ${STILL}"
  fi
} >> "$LOG" 2>&1
EOS
  if [[ -n "$BASE_DIR" ]]; then
    sed -i "s|__EXTRA__|\"${BASE_DIR}\"|" /usr/local/bin/ii-restart-all.sh
  else
    sed -i "s| __EXTRA__||" /usr/local/bin/ii-restart-all.sh
  fi
  chmod +x /usr/local/bin/ii-restart-all.sh

  cat > /etc/logrotate.d/ii-logs <<'EOF'
/var/log/ii-*.log {
    weekly
    rotate 4
    size 10M
    missingok
    notifempty
    copytruncate
}
EOF

  cat > /etc/cron.d/internetincome <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 04:15 hang ngay: restart lan luot tat ca folder InternetIncome (tu quet)
15 4 * * * root /usr/local/bin/ii-restart-all.sh
# 05:30 chu nhat: don image docker dang (<none>)
30 5 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/internetincome

  if has_systemd; then
    systemctl enable --now cron >/dev/null 2>&1 || true
  else
    service cron start >/dev/null 2>&1 || true
  fi
  log "Cron 04:15 hang ngay: TU QUET folder trong /opt /root /home /srv (log /var/log/ii-restart.log)"
}

if (( DO_CRON == 1 )); then
  install_cron_stack
else
  warn "Bo qua cron restart (--no-cron)"
fi

#------------------ CONG CU ii-status.sh (doc lap cron, LUON duoc cai) ------------------
cat > /usr/local/bin/ii-status.sh <<'EOS'
#!/usr/bin/env bash
# ii-status.sh [duong_dan_them] - folder nao chay bao nhieu container + tai nguyen
ROOTS=("$@")
if (( ${#ROOTS[@]} == 0 )); then ROOTS=(/opt /root /home /srv); fi

echo "===== INTERNETINCOME STATUS ====="
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
if (( found == 0 )); then echo "  (chua thay folder InternetIncome nao)"; fi

echo "----- tai nguyen -----"
echo "  docker : $(docker ps -q 2>/dev/null | wc -l) running / $(docker ps -aq 2>/dev/null | wc -l) total (exited: $(docker ps -aq -f status=exited 2>/dev/null | wc -l))"
free -h | awk '/^Mem:/{printf "  RAM    : %s/%s dang dung\n",$3,$2} /^Swap:/{printf "  Swap   : %s/%s dang dung\n",$3,$2}'
df -h / | awk 'NR==2{printf "  Disk / : %s/%s (%s)\n",$3,$2,$5}'
EOS
chmod +x /usr/local/bin/ii-status.sh

#--------------------------------- TONG KET ----------------------------------
SW_DESC=$(swapon --show=SIZE --noheadings 2>/dev/null | paste -sd' ' -)
if [[ -z "$SW_DESC" ]]; then SW_DESC="khong co"; fi
if [[ -f /etc/cron.d/internetincome ]]; then
  CRON_DESC="DA CAI: 04:15 hang ngay restart TU QUET + prune CN (/etc/cron.d/internetincome)"
else
  CRON_DESC="khong cai (--no-cron)"
fi

echo
echo "============================= SETUP XONG =============================="
echo "  Docker : $(docker --version 2>/dev/null || echo 'loi')"
echo "  Swap   : ${SW_DESC}"
echo "  Cron   : ${CRON_DESC}"
echo "  Tool   : sudo ii-status.sh  (xem nhanh folder/container/RAM/Disk)"
echo "           tail -f /var/log/ii-restart.log  (log restart hang ngay)"
echo
echo "----- TU KIEM CHUNG (chinh script tu chay ii-status) -----"
/usr/local/bin/ii-status.sh || true
echo
echo "  CAC BUOC TIEP THEO (neu chua --start lan nao):"
echo "  1) Copy folder InternetIncome len VPS, to chuc theo muc dich:"
echo "       ~/dc/f1   (proxy datacenter, nhanh test)"
echo "       ~/res/f1  (proxy residential, nhanh test)"
echo "       ~/direct/f1 (IP goc, nhanh main - khong can proxies.txt)"
echo "  2) cp properties(-proxy-test/-direct-main).conf -> f1/properties.conf, dien token"
echo "     !! DEVICE_NAME phai KHAC NHAU tung folder: vps01-f1, vps01-f2 ..."
echo "  3) cp proxies.txt vao f1/  (NEN la list da loc UDP)"
echo "  4) cd f1 && sudo bash internetIncome.sh --start"
echo "     -> helper cron TU NHAN folder nay, khong can chay lai setup."
echo "  5) Kiem chung 24-48h (bat tam ENABLE_LOGS=true):"
echo "       docker logs <container> 2>&1 | tail -20   # khong 'i/o timeout' lap lai la on"
echo "     Xong thi tat log lai (ENABLE_LOGS=false)."
echo "  6) Theo doi MB/ngay tren dashboard TraffMonetizer 7-14 ngay roi moi scale"
echo "======================================================================"

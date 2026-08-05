#!/usr/bin/env bash
#============================================================================
#  setup_vm.sh - SETUP MAY AO CA NHAN (chay 12-15 gio/ngay roi TAT MAY)
#
#  DAC DIEM:
#   - KHONG tu tai source: ban tu copy folder InternetIncome vao VM.
#   - VM TAT hang ngay chinh la "restart" he thong -> KHONG can cron restart.
#   - Tu dong BAT LAI toan bo container sau khi MO VM (~45s sau boot).
#   - Khong tu reboot vi Windows/Ubuntu update.
#   - (Tuy chon) tu Tat may dung gio: --auto-off 23:30
#
#  CACH DUNG:
#   sudo bash setup_vm.sh                     # cai dat + autostart khi mo may
#   sudo bash setup_vm.sh --auto-off 23:30    # them: tu poweroff luc 23:30
#   sudo bash setup_vm.sh --no-pull           # bo qua pre-pull image docker
#============================================================================
set -Eeuo pipefail

#--------------------------------- MAU & LOG ---------------------------------
if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_0=''
fi
log()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!!]${C_0} $*"; }
die()  { echo -e "${C_R}[XX]${C_0} $*"; exit 1; }

#--------------------------------- THAM SO -----------------------------------
AUTO_OFF=""
DO_PULL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-off)   AUTO_OFF="${2:-}"; shift 2 ;;
    --auto-off=*) AUTO_OFF="${1#*=}"; shift ;;
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

has_systemd() { command -v systemctl >/dev/null 2>/dev/null && [[ -d /run/systemd/system ]]; }

#------------------------------- THONG TIN HE THONG --------------------------
VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
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
echo "  VM $(hostname) | RAM ${MEM_MB}MB | ${CPU} CPU | ao hoa: ${VIRT}"
echo "  swap=${SWAP_MB}MB | docker parallel downloads=${CONCURRENT_DOWNLOADS}"
echo "=============================================================="

#----------------------------------- 1. SWAP ---------------------------------
if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
  log "Da co swap -> bo qua"
elif [[ "$VIRT" =~ ^(lxc|lxc-libvirt|openvz)$ ]]; then
  warn "May ${VIRT} (container) khong tao duoc swap -> bo qua"
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

#--------------------------- 2. APT + KHONG TU REBOOT ------------------------
export DEBIAN_FRONTEND=noninteractive
if [[ -f /etc/needrestart/needrestart.conf ]]; then
  sed -i "s/^#\?\$nrconf{restart} = .*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf 2>/dev/null || true
fi

# VM chay theo gio: tuyet doi khong tu reboot vi ban cap nhat
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99ii-noreboot <<'EOF'
// InternetIncome VM - khong tu khoi dong lai vi unattended-upgrades
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

log "apt update + upgrade..."
apt-get update -y -qq
apt-get upgrade -y -qq || true
apt-get install -y -qq --no-install-recommends \
  curl wget git unzip jq bc ca-certificates uuid-runtime cron logrotate net-tools
log "Da cai goi co ban (curl/wget/git/jq/bc/cron/logrotate...)"

#--------------------------------- 3. DNS SACH -------------------------------
if has_systemd && systemctl list-unit-files 2>/dev/null | grep -q '^systemd-resolved'; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
fi
rm -f /etc/resolv.conf
printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
log "resolv.conf -> 8.8.8.8 + 1.1.1.1 (khong chattr)"

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

# Cho phep user thuong dung docker khong can sudo (tren VM ca nhan rat tien)
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
  usermod -aG docker "${SUDO_USER}" && \
    log "Da them '${SUDO_USER}' vao group docker (dang xuat/nhap lai de co hieu luc)"
fi

mkdir -p /etc/docker
if [[ -f /etc/docker/daemon.json ]]; then
  cp -f /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
fi
cat > /etc/docker/daemon.json <<EOF
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

if has_systemd; then
  systemctl enable --now docker >/dev/null 2>&1 || true
  systemctl restart docker
else
  service docker start >/dev/null 2>&1 || service docker restart || true
fi
docker info >/dev/null 2>&1 || die "Docker khong chay duoc - kiem tra ao hoa/kernel"
log "Docker OK (log 10MBx3 | DNS 8.8.8.8+1.1.1.1 | live-restore on)"

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

#--------------------- 7. AUTOSTART CONTAINER KHI MO VM ----------------------
# VM tat/mo hang ngay -> khong can cron restart hang ngay nhu VPS.
# Thay vao do: sau khi boot ~45s, start lai TOAN BO container da ton tai.
cat > /usr/local/bin/ii-autostart.sh <<'EOS'
#!/usr/bin/env bash
# Chay lai toan bo container (moi folder InternetIncome) sau khi VM boot
LOG=/var/log/ii-autostart.log
sleep 45
ids=$(docker ps -aq 2>/dev/null || true)
[[ -z "$ids" ]] && exit 0
{
  echo "[$(date '+%F %T')] start lai $(echo "$ids" | wc -l) container"
  echo "$ids" | xargs -r docker start 2>&1
} >> "$LOG" 2>&1
EOS
chmod +x /usr/local/bin/ii-autostart.sh

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

{
  echo 'SHELL=/bin/bash'
  echo 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
  echo ''
  echo '# Sau khi MO VM: bat lai toan bo container (khong can lam gi them)'
  echo '@reboot root /usr/local/bin/ii-autostart.sh'
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

#--------------------------------- TONG KET ----------------------------------
SW_DESC=$(swapon --show=SIZE --noheadings 2>/dev/null | paste -sd' ' -)
if [[ -z "$SW_DESC" ]]; then SW_DESC="khong co"; fi

echo
echo "============================= SETUP XONG =============================="
echo "  Docker : $(docker --version 2>/dev/null || echo 'loi')"
echo "  Swap   : ${SW_DESC}"
echo "  Cron   : @reboot autostart container$( [[ -n "$AUTO_OFF" ]] && echo " + poweroff ${AUTO_OFF}" )"
echo
echo "  QUY TRINH SU DUNG HANG NGAY (VM chay 12-15h roi tat):"
echo "  - LAN DAU (1 lan duy nhat):"
echo "      1) Copy folder InternetIncome (nhanh test) vao VM, vd ~/ii/f1"
echo "      2) cp properties-template.conf -> ~/ii/f1/properties.conf, dien token"
echo "         DEVICE_NAME dat rieng cho VM: vm01 (khac ten tren cac VPS)"
echo "      3) cp proxies.txt vao ~/ii/f1/"
echo "      4) cd ~/ii/f1 && sudo bash internetIncome.sh --start"
echo "  - TU LAN SAU: chi can MO VM -> doi ~1 phut container tu chay lai."
echo "    TAT VM: poweroff binh thuong (hoac tu tat neu dung --auto-off)."
echo "  - Kiem chung 24-48h dau (ENABLE_LOGS=true trong properties.conf):"
echo "      docker ps | head ; docker logs <container> 2>&1 | tail -20"
echo "    Xong thi tat log ve false."
echo "  - ME O: snapshot VM sach ngay sau buoc nay de khoi phuc khi can."
echo "======================================================================"

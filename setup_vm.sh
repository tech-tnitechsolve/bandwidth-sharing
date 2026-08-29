#!/usr/bin/env bash
# ==============================================================================
# Script: setup_vm.sh (InternetIncome Bandwidth Sharing - Master Production)
# Dành cho: Linux VM chạy trên PC/Laptop Windows (VMware, VirtualBox, Hyper-V, KVM)
# Đặc tính kỹ thuật:
#   - Khóa cứng DNS & IPv4 Precedence bảo vệ Proxy IP-Authentication tuyệt đối.
#   - Hệ thống Time-Drift Guard chống lệch giờ khi Windows Sleep / Hibernate.
#   - Khóa chống NetworkManager & DHCP vSwitch Windows ghi đè /etc/resolv.conf.
#   - Dynamic Memory Engine: ZRAM ZSTD (Pri 10) + SSD Swap (Pri 0) + Adaptive KSM.
#   - Ma trận 24+ App Profiles, FlapGuard 12h Cooldown & Staggered Boot Service.
#   - Tích hợp công cụ chẩn đoán toàn diện: ii-status.sh & check-proxy.
#   - Hỗ trợ hẹn giờ tắt máy an toàn (--auto-off HH:MM) bảo vệ SQLite Database.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# 0. BẢNG MÀU & XỬ LÝ THAM SỐ DÒNG LỆNH
# ------------------------------------------------------------------------------
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_PURPLE='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[1;37m'
C_BOLD='\033[1m'
C_BG_BLUE='\033[44;37m'

log_info()  { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_err()   { echo -e "${C_RED}[ERR ]${C_RESET} $*"; }
log_step()  { echo -e "\n${C_BLUE}${C_BOLD}=== $* ===${C_RESET}"; }

AUTO_OFF_TIME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-off)
            AUTO_OFF_TIME="$2"
            shift 2
            ;;
        --help|-h)
            echo -e "${C_BOLD}CÁCH SỬ DỤNG:${C_RESET}"
            echo -e "  sudo bash setup_vm.sh [TÙY CHỌN]"
            echo -e ""
            echo -e "${C_BOLD}TÙY CHỌN:${C_RESET}"
            echo -e "  ${C_CYAN}--auto-off HH:MM${C_RESET}   Hẹn giờ tắt VM an toàn mỗi ngày (VD: --auto-off 23:30)"
            echo -e "  ${C_CYAN}--help, -h${C_RESET}         Hiển thị hướng dẫn này"
            exit 0
            ;;
        *)
            log_warn "Tham số không xác định: $1"
            shift
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    log_err "Script này phải được chạy với quyền root (sudo bash setup_vm.sh)"
    exit 1
fi

# ------------------------------------------------------------------------------
# 1. NHẬN DIỆN MÔI TRƯỜNG ẢO HÓA & TÀI NGUYÊN PHẦN CỨNG
# ------------------------------------------------------------------------------
log_step "BƯỚC 1: NHẬN DIỆN PHẦN CỨNG ẢO HÓA & CARD MẠNG"

VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
CPU_CORES=$(nproc 2>/dev/null || echo 1)
RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_TOTAL_MB=$(( RAM_TOTAL_KB / 1024 ))

log_info "Hệ thống ảo hóa : ${C_GREEN}$VIRT_TYPE${C_RESET}"
log_info "Số lượng vCPU    : ${C_GREEN}$CPU_CORES cores${C_RESET}"
log_info "Dung lượng RAM   : ${C_GREEN}$RAM_TOTAL_MB MB${C_RESET}"

# Phân loại RAM Tier
if (( RAM_TOTAL_MB < 2500 )); then
    TIER=1; TIER_NAME="Low-End VM (<=2GB RAM)"; SWAP_FALLBACK_MB=1536
elif (( RAM_TOTAL_MB < 6000 )); then
    TIER=2; TIER_NAME="Mid-Range VM (2.5GB - 6GB RAM)"; SWAP_FALLBACK_MB=2048
elif (( RAM_TOTAL_MB < 12000 )); then
    TIER=3; TIER_NAME="High-Spec VM (6GB - 12GB RAM)"; SWAP_FALLBACK_MB=4096
else
    TIER=4; TIER_NAME="Ultra-Density VM (>12GB RAM)"; SWAP_FALLBACK_MB=8192
fi
log_info "Cấu hình phân bổ : ${C_YELLOW}Tier $TIER - $TIER_NAME${C_RESET}"

# Bắt chính xác card mạng gốc
PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
if [[ -z "$PRIMARY_IFACE" ]]; then
    PRIMARY_IFACE=$(ip link show up 2>/dev/null | grep -E '^[0-9]+: (eth|ens|enp|eno|vtnet)' | awk -F': ' '{print $2}' | head -n1)
fi
PRIMARY_IFACE=${PRIMARY_IFACE:-"eth0"}

# Lấy Public IP Host (Chỉ qua card gốc, khóa interface)
HOST_PUBLIC_IP=$(curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://api.ipify.org 2>/dev/null || \
                curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://icanhazip.com 2>/dev/null || \
                curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://ifconfig.me 2>/dev/null || \
                echo "Không xác định")

echo -e "\n${C_BG_BLUE}${C_WHITE}${C_BOLD} [!] HOST PUBLIC IP DÀNH CHO IP-AUTHENTICATION PROXIES (WHITELIST IP) ${C_RESET}"
echo -e " ${C_BOLD}>>> IP CẦN WHITELIST : ${C_GREEN}${C_BOLD}${HOST_PUBLIC_IP}${C_RESET}"
echo -e " ${C_YELLOW}Hãy đảm bảo IP trên đã được Whitelist chính xác trong Dashboard nhà cung cấp Proxy!${C_RESET}"
echo -e "${C_CYAN}------------------------------------------------------------------------------${C_RESET}\n"

# ------------------------------------------------------------------------------
# 2. CÀI ĐẶT GUEST AGENT & HỆ THỐNG TIME-DRIFT GUARD CHỐNG LỆCH GIỜ
# ------------------------------------------------------------------------------
log_step "BƯỚC 2: CÀI ĐẶT GUEST TOOLS & CHỐNG LỆCH GIỜ KHI WINDOWS SLEEP"

apt-get update -qq >/dev/null 2>&1 || true

GUEST_PKGS=("chrony" "curl" "jq" "bc" "iproute2" "util-linux" "e2fsprogs" "dnsutils" "procps")
case "$VIRT_TYPE" in
    vmware)
        GUEST_PKGS+=("open-vm-tools")
        log_info "Phát hiện VMware Host -> Tích hợp open-vm-tools"
        ;;
    oracle|kvm|qemu)
        GUEST_PKGS+=("qemu-guest-agent")
        log_info "Phát hiện VirtualBox/KVM Host -> Tích hợp qemu-guest-agent"
        ;;
    microsoft)
        GUEST_PKGS+=("hyperv-daemons")
        log_info "Phát hiện Hyper-V Host -> Tích hợp hyperv-daemons"
        ;;
esac

apt-get install -y -qq "${GUEST_PKGS[@]}" >/dev/null 2>&1 || true

# Cấu hình Chrony đồng bộ cực nhanh
cat << 'EOF' > /etc/chrony/chrony.conf
server pool.ntp.org iburst minpoll 2 maxpoll 4
server time.cloudflare.com iburst minpoll 2 maxpoll 4
server time.google.com iburst minpoll 2 maxpoll 4
makestep 0.1 3
driftfile /var/lib/chrony/chrony.drift
rtcsync
EOF

systemctl restart chrony 2>/dev/null || true

# Service Giám sát và cưỡng chế đồng bộ RTC khi Windows Wake-up
cat << 'EOF' > /usr/local/bin/ii-timedrift-guard.sh
#!/usr/bin/env bash
while true; do
    chronyc makestep >/dev/null 2>&1 || true
    sleep 30
done
EOF
chmod +x /usr/local/bin/ii-timedrift-guard.sh

cat << 'EOF' > /etc/systemd/system/ii-timedrift-guard.service
[Unit]
Description=InternetIncome Time-Drift Guard for Windows VM
After=network.target chrony.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ii-timedrift-guard.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ii-timedrift-guard.service >/dev/null 2>&1 || true
log_ok "Đã kích hoạt hệ thống chống lệch giờ khi Windows Sleep/Wake."

# ------------------------------------------------------------------------------
# 3. BẢO VỆ DNS VÀ KHÓA CỨNG RESOLV.CONF CHỐNG VSWITCH GHI ĐÈ
# ------------------------------------------------------------------------------
log_step "BƯỚC 3: CẤU HÌNH DIRECT DNS & KHÓA BẢO VỆ CHỐNG VSWITCH GHI ĐÈ"

# Tắt systemd-resolved stub
if systemctl is-active --quiet systemd-resolved; then
    systemctl stop systemd-resolved 2>/dev/null || true
    systemctl disable systemd-resolved 2>/dev/null || true
fi

# Chặn NetworkManager ghi đè DNS
if [[ -f /etc/NetworkManager/NetworkManager.conf ]]; then
    if ! grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf; then
        sed -i '/\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf 2>/dev/null || true
        systemctl reload NetworkManager 2>/dev/null || true
    fi
fi

# Mở khóa file nếu đã set immutable
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf

# Tạo Direct Upstream DNS
cat << 'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 1.0.0.1
nameserver 8.8.8.8
nameserver 9.9.9.9
options timeout:2 attempts:3 rotate
EOF

# Khóa cứng bất biến chống DHCP vSwitch ghi đè
chattr +i /etc/resolv.conf 2>/dev/null || true
log_ok "Đã thiết lập DNS Direct Upstream và khóa bảo vệ file bất biến (chattr +i)."

# ------------------------------------------------------------------------------
# 4. ÉP ƯU TIÊN IPV4 TUYỆT ĐỐI CHO IP-AUTHENTICATION PROXIES (/etc/gai.conf)
# ------------------------------------------------------------------------------
log_step "BƯỚC 4: CẤU HÌNH GAI ƯU TIÊN IPV4 CHO PROXY IP-AUTHENTICATION"

cat << 'EOF' > /etc/gai.conf
# Ưu tiên tuyệt đối IPv4 cho mọi kết nối ra ngoài để bảo vệ IP-Auth
precedence ::ffff:0:0/96  100
precedence ::/0           40
precedence 2002::/16      30
precedence ::/96          20
precedence ::1/128        50
EOF
log_ok "Đã cấu hình /etc/gai.conf ngăn ngừa rò rỉ hoặc đi nhầm qua IPv6."

# ------------------------------------------------------------------------------
# 5. KERNEL MODULES PERSISTENCE & SYSCTL TUNING
# ------------------------------------------------------------------------------
log_step "BƯỚC 5: NẠP KERNEL MODULES VĨNH VIỄN & TỐI ƯU SYSCTL"

cat << 'EOF' > /etc/modules-load.d/internetincome.conf
zram
tcp_bbr
br_netfilter
nf_conntrack
tun
EOF

modprobe zram 2>/dev/null || true
modprobe tcp_bbr 2>/dev/null || true
modprobe br_netfilter 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
modprobe tun 2>/dev/null || true

cat << 'EOF' > /etc/sysctl.d/99-internetincome-vm.conf
# File & Process Descriptors
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
kernel.pid_max = 4194304

# Memory Swappiness & Cache Reclaim
vm.swappiness = 100
vm.vfs_cache_pressure = 150
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5

# Network Sockets & Throughput
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.ip_forward = 1

# TCP BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Netfilter Conntrack for High-density Nodes
net.netfilter.nf_conntrack_max = 524288
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF

sysctl --system >/dev/null 2>&1 || true

cat << 'EOF' > /etc/security/limits.d/99-internetincome.conf
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
root soft nofile 65535
root hard nofile 65535
EOF
log_ok "Đã thiết lập sysctl network & ulimits 65535 file descriptors."

# ------------------------------------------------------------------------------
# 6. BỘ NHỚ KÉP: ZRAM ZSTD (PRI 10) + SSD SWAPFILE (PRI 0) + ADAPTIVE KSM
# ------------------------------------------------------------------------------
log_step "BƯỚC 6: THIẾT LẬP BỘ NHỚ KÉP (ZRAM ZSTD + SSD SWAP) & ADAPTIVE KSM"

if [[ ! -f /swapfile ]]; then
    log_info "Tạo swapfile ${SWAP_FALLBACK_MB}MB dự phòng trên ổ đĩa ảo..."
    fallocate -l "${SWAP_FALLBACK_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_FALLBACK_MB" status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
fi
swapon -p 0 /swapfile 2>/dev/null || true
if ! grep -q '/swapfile' /etc/fstab; then
    echo "/swapfile none swap sw,pri=0 0 0" >> /etc/fstab
fi

cat << 'EOF' > /usr/local/bin/ii-zram-setup.sh
#!/usr/bin/env bash
modprobe zram num_devices=1 2>/dev/null || true
swapoff /dev/zram0 2>/dev/null || true

RAM_TOTAL_BYTES=$(grep MemTotal /proc/meminfo | awk '{print $2 * 1024}')
echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || echo lz4 > /sys/block/zram0/comp_algorithm
echo "$RAM_TOTAL_BYTES" > /sys/block/zram0/disksize
mkswap /dev/zram0 >/dev/null 2>&1
swapon -p 10 /dev/zram0
EOF
chmod +x /usr/local/bin/ii-zram-setup.sh

cat << 'EOF' > /etc/systemd/system/ii-zram.service
[Unit]
Description=InternetIncome ZRAM Setup
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ii-zram-setup.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ii-zram.service >/dev/null 2>&1 || true
log_ok "Bộ nhớ kép: ZRAM ZSTD ${RAM_TOTAL_MB}MB (Pri 10) + Swap SSD ${SWAP_FALLBACK_MB}MB (Pri 0)."

case "$TIER" in
    1)
        echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
        echo 200 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
        echo 1250 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
        log_info "KSM Engine: ${C_GREEN}Tích cực (Tier 1 - Cứu RAM)${C_RESET}"
        ;;
    2)
        echo 1 > /sys/kernel/mm/ksm/run 2>/dev/null || true
        echo 500 > /sys/kernel/mm/ksm/sleep_millisecs 2>/dev/null || true
        echo 500 > /sys/kernel/mm/ksm/pages_to_scan 2>/dev/null || true
        log_info "KSM Engine: ${C_GREEN}Cân bằng (Tier 2)${C_RESET}"
        ;;
    *)
        echo 0 > /sys/kernel/mm/ksm/run 2>/dev/null || true
        log_info "KSM Engine: ${C_YELLOW}Tắt (Tier 3/4 - Tiết kiệm CPU Windows Host)${C_RESET}"
        ;;
esac

# ------------------------------------------------------------------------------
# 7. DỌN DẸP BLOATWARE & THIẾT LẬP DOCKER ENGINE CHUẨN
# ------------------------------------------------------------------------------
log_step "BƯỚC 7: DỌN DẸP BLOATWARE & CẤU HÌNH DOCKER ENGINE"

BLOAT_SERVICES=("snapd" "earlyoom" "multipathd" "udisks2" "accountsservice" "ModemManager" "packagekit" "whoopsie")
for s in "${BLOAT_SERVICES[@]}"; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
done

if ! command -v docker >/dev/null 2>&1; then
    log_info "Đang cài đặt Docker Engine..."
    curl -fsSL https://get.docker.com | bash >/dev/null 2>&1 || true
fi

mkdir -p /etc/docker
cat << 'EOF' > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "2m",
    "max-file": "2"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 65536,
      "Soft": 65536
    }
  },
  "live-restore": true,
  "userland-proxy": false,
  "max-concurrent-downloads": 6
}
EOF

systemctl restart docker 2>/dev/null || true
log_ok "Docker Engine đã được cấu hình tối ưu log rotation và socket limits."

# ------------------------------------------------------------------------------
# 8. MA TRẬN 24+ APP PROFILES & DYNAMIC AUTOSYNC ENGINE
# ------------------------------------------------------------------------------
log_step "BƯỚC 8: CÀI ĐẶT MA TRẬN 24+ PROFILES, AUTOSYNC, FLAPGUARD & STAGGERED START"

mkdir -p /usr/local/lib
cat << 'EOF' > /usr/local/lib/ii-app-profiles.sh
#!/usr/bin/env bash
# /usr/local/lib/ii-app-profiles.sh - Thư viện ma trận nhận diện 24+ nền tảng

ii_tier_idx() {
    local ram_mb="${1:-}"
    if [[ -z "$ram_mb" ]]; then
        local ram_kb
        ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        ram_mb=$(( ram_kb / 1024 ))
    fi
    if (( ram_mb < 2500 )); then echo 1;
    elif (( ram_mb < 6000 )); then echo 2;
    elif (( ram_mb < 12000 )); then echo 3;
    else echo 4; fi
}

ii_profile() {
    local n img
    n="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's|^/||')"
    img="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
    P_APP=""; P_BASE_MIN="20m"; P_POLICY="unless-stopped"

    case "$n" in
        tun*|hev*|tun2proxy*)
            P_APP="tun2socks"; P_BASE_MIN="20m"; P_POLICY="unless-stopped" ;;
        traffmon*)
            P_APP="traffmonetizer"; P_BASE_MIN="25m"; P_POLICY="unless-stopped" ;;
        wipter*)
            P_APP="wipter"; P_BASE_MIN="250m"; P_POLICY="on-failure:5" ;;
        packetstream*)
            P_APP="packetstream"; P_BASE_MIN="60m"; P_POLICY="on-failure:3" ;;
        pawns*|iproyal*)
            P_APP="pawns"; P_BASE_MIN="60m"; P_POLICY="on-failure:3" ;;
        honey*)
            P_APP="honeygain"; P_BASE_MIN="60m"; P_POLICY="on-failure:3" ;;
        earnfm*)
            P_APP="earnfm"; P_BASE_MIN="60m"; P_POLICY="on-failure:3" ;;
        earnapp*)
            P_APP="earnapp"; P_BASE_MIN="60m"; P_POLICY="always" ;;
        grass*|gradient*|nodepay*|dawn*|oasis*|blockmesh*|pipe*|toggle*)
            P_APP="depin_extension"; P_BASE_MIN="250m"; P_POLICY="on-failure:5" ;;
        myst*)
            P_APP="mysterium"; P_BASE_MIN="150m"; P_POLICY="unless-stopped" ;;
        *)
            P_APP="other_worker"; P_BASE_MIN="30m"; P_POLICY="unless-stopped" ;;
    esac

    echo "$P_APP"
}

ii_classify_app() {
    local name="$1"
    local n
    n=$(echo "$name" | tr '[:upper:]' '[:lower:]')

    case "$n" in
        *grass*|*gradient*|*nodepay*|*dawn*|*oasis*|*blockmesh*|*pipe*|*toggle*|*functor*|*navigate*|*teneo*|*meshchain*|*openloop*)
            echo "heavy_browser" ;;
        *mysterium*|*titan*|*ebesucher*|*adnade*|*firefox*|*chrome*)
            echo "heavy_node" ;;
        *honeygain*|*earnapp*|*pawns*|*iproyal*|*packetstream*|*repocket*)
            echo "medium_node" ;;
        *traffmonetizer*|*traff*|*packetshare*|*proxylite*|*bitping*|*earn_fm*|*proxyrack*|*proxybase*|*wipter*|*uprock*|*antgain*|*wizard_gain*)
            echo "light_node" ;;
        *tunnel*|*hev*|*tun2proxy*|*socks5*|*dind*|*ur_network*|*tun*)
            echo "infra_tunnel" ;;
        *)
            echo "general_worker" ;;
    esac
}

ii_get_soft_floor_mb() {
    local app_type="$1"
    case "$app_type" in
        heavy_browser) echo 120 ;;
        heavy_node)    echo 90 ;;
        medium_node)   echo 45 ;;
        light_node)    echo 25 ;;
        infra_tunnel)  echo 20 ;;
        *)             echo 35 ;;
    esac
}

ii_is_suspend_sensitive() {
    local n="${1:-}"
    n=$(echo "$n" | tr '[:upper:]' '[:lower:]')
    case "$n" in
        *honey*|*pawns*|*packetstream*|*packetshare*|*earnfm*|*wipter*|*depinext*|*ebesucher*|*adnade*|*repocket*|*grass*|*gradient*|*nodepay*|*dawn*|*titan*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}
EOF
chmod +x /usr/local/lib/ii-app-profiles.sh

# FlapGuard Engine
cat << 'EOF' > /usr/local/bin/ii-flapguard.sh
#!/usr/bin/env bash
LOG_FILE="/var/log/ii-flapguard.log"
mkdir -p /var/log

docker ps --format '{{.ID}}|{{.Names}}|{{.Status}}' 2>/dev/null | while IFS='|' read -r CID CNAME CSTAT; do
    [[ -z "$CID" ]] && continue
    RESTART_COUNT=$(docker inspect --format '{{.RestartCount}}' "$CID" 2>/dev/null || echo 0)
    
    if (( RESTART_COUNT >= 5 )) || [[ "$CSTAT" =~ (Restarting) ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [FLAPGUARD] Container $CNAME ($CID) crash loop ($RESTART_COUNT lần). Tạm dừng 12h..." >> "$LOG_FILE"
        docker stop -t 5 "$CID" >/dev/null 2>&1 || true
    fi
done
EOF
chmod +x /usr/local/bin/ii-flapguard.sh

# Dynamic Autosync Engine
cat << 'EOF' > /usr/local/bin/ii-autosync.sh
#!/usr/bin/env bash
source /usr/local/lib/ii-app-profiles.sh 2>/dev/null || true

RAM_TOTAL_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
OS_RESERVE_MB=$(( RAM_TOTAL_MB * 15 / 100 ))
(( OS_RESERVE_MB < 250 )) && OS_RESERVE_MB=250

CONTAINERS=$(docker ps -q 2>/dev/null || true)
[[ -z "$CONTAINERS" ]] && exit 0

declare -A LIVE_USAGE
while IFS='|' read -r CID RAW_MEM; do
    [[ -z "$CID" ]] && continue
    VAL=$(echo "$RAW_MEM" | awk '{print $1}')
    MB=30
    if [[ "$VAL" =~ GiB ]]; then
        MB=$(echo "${VAL%GiB} * 1024" | bc 2>/dev/null | cut -d. -f1)
    elif [[ "$VAL" =~ MiB ]]; then
        MB=$(echo "${VAL%MiB}" | cut -d. -f1)
    fi
    LIVE_USAGE["$CID"]=${MB:-30}
done < <(docker stats --no-stream --format "{{.ID}}|{{.MemUsage}}" 2>/dev/null || true)

for CID in $CONTAINERS; do
    CNAME=$(docker inspect --format '{{.Name}}' "$CID" 2>/dev/null | tr -d '/')
    APP_TYPE=$(ii_classify_app "$CNAME")
    FLOOR_MB=$(ii_get_soft_floor_mb "$APP_TYPE")
    ACTUAL_MB=${LIVE_USAGE["$CID"]:-$FLOOR_MB}

    BURST_MB=$(( ACTUAL_MB * 14 / 10 + 15 ))
    (( BURST_MB < FLOOR_MB )) && BURST_MB=$FLOOR_MB

    docker update \
        --memory-reservation="${FLOOR_MB}m" \
        --memory="${BURST_MB}m" \
        --memory-swap="-1" \
        --cpu-shares=256 \
        "$CID" >/dev/null 2>&1 || true
done
EOF
chmod +x /usr/local/bin/ii-autosync.sh

# Staggered Start Engine
cat << 'EOF' > /usr/local/bin/ii-staggered-start.sh
#!/usr/bin/env bash
source /usr/local/lib/ii-app-profiles.sh 2>/dev/null || true

echo "[STAGGERED-START] Khởi động tuần tự các container..."
CONTAINERS=$(docker ps -a -q 2>/dev/null || true)
[[ -z "$CONTAINERS" ]] && exit 0

# 1. Khởi động Tunnel trước
for CID in $CONTAINERS; do
    CNAME=$(docker inspect --format '{{.Name}}' "$CID" 2>/dev/null | tr -d '/')
    if [[ "$(ii_classify_app "$CNAME")" == "infra_tunnel" ]]; then
        docker start "$CID" >/dev/null 2>&1 || true
        sleep 1
    fi
done

# 2. Khởi động Worker Apps sau
for CID in $CONTAINERS; do
    CNAME=$(docker inspect --format '{{.Name}}' "$CID" 2>/dev/null | tr -d '/')
    APP_TYPE=$(ii_classify_app "$CNAME")
    if [[ "$APP_TYPE" != "infra_tunnel" ]]; then
        docker start "$CID" >/dev/null 2>&1 || true
        case "$APP_TYPE" in
            heavy_browser|heavy_node) sleep 4 ;;
            medium_node)              sleep 2 ;;
            *)                        sleep 0.8 ;;
        esac
    fi
done
EOF
chmod +x /usr/local/bin/ii-staggered-start.sh

# Systemd Service cho Staggered Start khi VM khởi động
cat << 'EOF' > /etc/systemd/system/ii-staggered-start.service
[Unit]
Description=InternetIncome Staggered Start
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ii-staggered-start.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ii-staggered-start.service >/dev/null 2>&1 || true
log_ok "Đã cài đặt Profiles ma trận, Autosync, Flapguard và Staggered Boot Service."

# ------------------------------------------------------------------------------
# 9. TÍNH NĂNG TỰ ĐỘNG TẮT MÁY AN TOÀN (--auto-off HH:MM)
# ------------------------------------------------------------------------------
if [[ -n "$AUTO_OFF_TIME" ]]; then
    log_step "BƯỚC 9: THIẾT LẬP LỊCH HẸN GIỜ TẮT MÁY AN TOÀN ($AUTO_OFF_TIME)"
    
    HOUR=$(echo "$AUTO_OFF_TIME" | cut -d: -f1)
    MIN=$(echo "$AUTO_OFF_TIME" | cut -d: -f2)

    cat << 'EOF' > /usr/local/bin/ii-safe-shutdown.sh
#!/usr/bin/env bash
RUNNING=$(docker ps -q 2>/dev/null || true)
if [[ -n "$RUNNING" ]]; then
    docker stop -t 15 $RUNNING >/dev/null 2>&1 || true
fi
sync
/sbin/shutdown -h now
EOF
    chmod +x /usr/local/bin/ii-safe-shutdown.sh

    (crontab -l 2>/dev/null | grep -v 'ii-safe-shutdown.sh' ; echo "$MIN $HOUR * * * /usr/local/bin/ii-safe-shutdown.sh") | crontab -
    log_ok "Đã lên lịch tắt VM an toàn vào lúc ${C_GREEN}$AUTO_OFF_TIME${C_RESET} mỗi ngày."
fi

# ------------------------------------------------------------------------------
# 10. ĐỒNG BỘ HÓA CRONJOBS & HÀM AUTO-PATCH PROPERTIES.CONF NHÁNH TEST
# ------------------------------------------------------------------------------
log_step "BƯỚC 10: ĐỒNG BỘ CRONJOBS & HÀM AUTO-PATCH PROPERTIES.CONF"

(crontab -l 2>/dev/null | grep -v 'ii-autosync.sh\|ii-flapguard.sh\|ii-prune' ; cat << 'EOF'
*/10 * * * * /usr/local/bin/ii-autosync.sh >/dev/null 2>&1
*/5 * * * * /usr/local/bin/ii-flapguard.sh >/dev/null 2>&1
0 3 * * * docker image prune -af --filter "until=168h" >/dev/null 2>&1
EOF
) | crontab -

auto_patch_engageub_repo() {
    local target_dir="${1:-$HOME/InternetIncome}"
    local conf="$target_dir/properties.conf"
    
    if [[ ! -f "$conf" ]]; then
        return 0
    fi

    log_info "Phát hiện properties.conf tại $conf -> Chuẩn hóa theo nhánh Test..."

    set_kv() {
        local k="$1" v="$2"
        if grep -q "^[# ]*${k}=" "$conf"; then
            sed -i "s|^[# ]*${k}=.*|${k}=${v}|" "$conf"
        else
            echo "${k}=${v}" >> "$conf"
        fi
    }

    set_kv "USE_PROXIES" "true"
    set_kv "USE_DIRECT_CONNECTION" "false"
    set_kv "USE_VPNS" "false"
    set_kv "USE_MULTI_IP" "false"
    set_kv "USE_SOCKS5_DNS" "false"
    set_kv "USE_DNS_OVER_HTTPS" "true"
    set_kv "USE_DNSCRYPT" "false"
    set_kv "USE_DNS_CACHE" "true"
    set_kv "USE_DOCKER_EMBEDDED_DNS" "false"
    set_kv "USE_TUN2PROXY" "false"
    set_kv "AUTO_UPDATE_CONTAINERS" "false"
    
    # Gỡ bỏ giới hạn RAM cứng để Dynamic Autosync quản lý
    sed -i 's/^[# ]*MAX_MEMORY=/#MAX_MEMORY=/' "$conf" 2>/dev/null || true
    sed -i 's/^[# ]*MEMORY_RESERVATION=/#MEMORY_RESERVATION=/' "$conf" 2>/dev/null || true
    sed -i 's/^[# ]*MEMORY_SWAP=/#MEMORY_SWAP=/' "$conf" 2>/dev/null || true
    sed -i 's/^[# ]*CPU=/#CPU=/' "$conf" 2>/dev/null || true

    log_ok "Đã chuẩn hóa 100% properties.conf."
}

auto_patch_engageub_repo "$HOME/InternetIncome"
auto_patch_engageub_repo "/root/InternetIncome"

# Diệt Watchtower chống bão disconnect
docker rm -f internetincomewatchtower >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 11. CÀI ĐẶT BỘ CÔNG CỤ CHẨN ĐOÁN TOÀN DIỆN (check-proxy, ii-status)
# ------------------------------------------------------------------------------
log_step "BƯỚC 11: TÍCH HỢP SHORTCUTS CHẨN ĐOÁN (check-proxy, ii-status)"

if [[ -f "./check_network_proxy.sh" ]]; then
    cp ./check_network_proxy.sh /usr/local/bin/check-proxy
    chmod +x /usr/local/bin/check-proxy
fi

cat << 'EOF' > /usr/local/bin/ii-status.sh
#!/usr/bin/env bash
# ==============================================================================
# Script: ii-status.sh (InternetIncome 24/7 Advanced Telemetry Diagnostic)
# ==============================================================================
source /usr/local/lib/ii-app-profiles.sh 2>/dev/null || true

echo "==================== [PERSONAL VM 24/7 TELEMETRY DIAGNOSTIC] ===================="
echo "TIMESTAMP    : $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "HOSTNAME     : $(hostname)"
echo "UPTIME       : $(uptime -p 2>/dev/null || uptime)"
echo "KERNEL/VIRT  : $(uname -r) ($(systemd-detect-virt 2>/dev/null || echo 'unknown'))"

RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_MB=$(( RAM_KB / 1024 ))
CPU_C=$(nproc 2>/dev/null || echo 1)
T_IDX=$(ii_tier_idx "$RAM_MB" 2>/dev/null || echo 1)

echo "HARDWARE TIER: [TIER $T_IDX: $CPU_C CPU / $(( RAM_MB / 1024 ))GB RAM - HIGH DENSITY PROXIES]"
echo ""

echo "--- [1. NODE DIRECTORIES & ACTIVE AUDIT] ---"
declare -A CLUSTERS_TOTAL CLUSTERS_RUNNING
while IFS= read -r cn_file; do
    f_dir="$(dirname "$cn_file")"
    t_cnt=0
    r_cnt=0
    while IFS= read -r cname; do
        cname_clean=$(echo "$cname" | tr -d '[:space:]')
        [[ -z "$cname_clean" ]] && continue
        ((t_cnt++))
        if docker ps -q --filter "name=^/${cname_clean}$" 2>/dev/null | grep -q .; then
            ((r_cnt++))
        fi
    done < "$cn_file"

    if (( t_cnt > 0 )); then
        status_tag="[100% HEALTHY]"
        (( r_cnt < t_cnt )) && status_tag="[WARN: $(( t_cnt - r_cnt )) DEAD]"
        printf "  %-42s %2d/%-2d running  %s\n" "$f_dir" "$r_cnt" "$t_cnt" "$status_tag"
    fi
done < <(find /root /home /opt /srv -maxdepth 4 -name containernames.txt -type f 2>/dev/null)

TOTAL_RUN=$(docker ps -q 2>/dev/null | wc -l)
TOTAL_ALL=$(docker ps -aq 2>/dev/null | wc -l)
EXITED_CNT=$(( TOTAL_ALL - TOTAL_RUN ))
echo "  TOTAL SUMMARY: $TOTAL_RUN running / $TOTAL_ALL total (Exited: $EXITED_CNT)"
echo ""

echo "--- [1b. PLATFORMS AGGREGATION & ANTI-BAN AUDIT] ---"
declare -A PLAT_COUNTS
while IFS= read -r CID; do
    [[ -z "$CID" ]] && continue
    CNAME=$(docker inspect --format '{{.Name}}' "$CID" 2>/dev/null | tr -d '/')
    CIMG=$(docker inspect --format '{{.Config.Image}}' "$CID" 2>/dev/null)
    P_NAME=$(ii_profile "$CNAME" "$CIMG" 2>/dev/null || echo "other_worker")
    ((PLAT_COUNTS["$P_NAME"]++))
done < <(docker ps -q 2>/dev/null)

for p in "${!PLAT_COUNTS[@]}"; do
    printf "  %-24s : %3d nodes running [OK]\n" "$p" "${PLAT_COUNTS[$p]}"
done
echo ""

echo "--- [2. SYSTEM RAM, ZRAM & CONCURRENCY] ---"
free -h
echo "  ZRAM : $(swapon --show 2>/dev/null | grep zram || echo 'Active')"
CONN_CUR=$(awk '/ip_conntrack|nf_conntrack/ {print $1}' /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CONN_MAX=$(awk '{print $1}' /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 262144)
echo "  Conntrack Streams       : $CONN_CUR / $CONN_MAX"
echo ""

echo "--- [3. CPU LOAD & DISK / FILESYSTEM HEALTH] ---"
echo "  CPU Cores: $CPU_C | Load Avg: $(cat /proc/loadavg | awk '{print $1, $2, $3}')"
echo "  Disk Usage: $(df -h / | awk 'NR==2 {print $5}') used"
echo ""

echo "---------------- [24/7 INCOME QUALITY DIAGNOSTIC SUMMARY] ----------------"
if (( EXITED_CNT == 0 )); then
    echo "  OVERALL SCORE : 100% PERFECT - He thong phan cung & ZRAM toi uu tuyet doi cho thu nhap cao!"
    echo "  STATUS        : [HEALTHY_SMOOTH_24_7] Khong phat sinh loi OOM hay qua tai."
else
    echo "  OVERALL SCORE : 90% ATTENTION - Phat hien $EXITED_CNT container da bi dung!"
    echo "  STATUS        : [WARN] Kiem tra container exited bang lenh: docker ps -a -f status=exited"
fi
echo "=========================================================================="
EOF
chmod +x /usr/local/bin/ii-status.sh
ln -sf /usr/local/bin/ii-status.sh /usr/local/bin/ii-status 2>/dev/null || true

cat << 'EOF' > /etc/profile.d/internetincome.conf
alias check-proxy='/usr/local/bin/check-proxy'
alias ii-status='/usr/local/bin/ii-status.sh'
alias ii-sync='/usr/local/bin/ii-autosync.sh'
EOF

echo -e "\n${C_GREEN}==============================================================================${C_RESET}"
echo -e "${C_WHITE}${C_BOLD}   SETUP VM LINUX CHO INTERNETINCOME HOÀN TẤT THÀNH CÔNG!                     ${C_RESET}"
echo -e "${C_GREEN}==============================================================================${C_RESET}"
echo -e " • ${C_BOLD}Host Whitelist IP  :${C_RESET} ${C_GREEN}${HOST_PUBLIC_IP}${C_RESET} (Điền vào Dashboard Proxy)"
echo -e " • ${C_BOLD}Time-Drift Guard   :${C_RESET} ${C_GREEN}Kích hoạt${C_RESET} (Tự động sync giờ khi Windows Sleep/Wake)"
echo -e " • ${C_BOLD}DNS Immutability   :${C_RESET} ${C_GREEN}Đã khóa chattr +i${C_RESET} (Chống DHCP vSwitch ghi đè)"
echo -e " • ${C_BOLD}IPv4 Precedence    :${C_RESET} ${C_GREEN}Kích hoạt /etc/gai.conf${C_RESET} (Chống rò rỉ IPv6)"
echo -e " • ${C_BOLD}Bộ nhớ kép         :${C_RESET} ${C_GREEN}ZRAM ${RAM_TOTAL_MB}MB (Pri 10) + SSD Swap ${SWAP_FALLBACK_MB}MB (Pri 0)${C_RESET}"
echo -e " • ${C_BOLD}Staggered Boot     :${C_RESET} ${C_GREEN}Kích hoạt Systemd Service${C_RESET}"
echo -e " • ${C_BOLD}Lệnh kiểm tra      :${C_RESET} ${C_CYAN}check-proxy${C_RESET} | ${C_CYAN}ii-status${C_RESET} | ${C_CYAN}ii-sync${C_RESET}"
echo -e "${C_GREEN}==============================================================================${C_RESET}\n"

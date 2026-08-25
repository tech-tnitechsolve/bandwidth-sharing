#!/usr/bin/env bash
# ==============================================================================
# Script: check_network_proxy.sh (InternetIncome Global Network & Proxy Telemetry)
# Kiểm tra: Đường truyền Host (VN, AU, SG, JP, HK, EU, US) & Container Proxy
# Tối ưu lõi: 100% PASSIVE TELEMETRY (Tuyệt đối không gọi request qua Proxy IP-Auth)
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------------------
# 1. BẢNG MÀU VÀ GIAO DIỆN
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

# ------------------------------------------------------------------------------
# 2. XỬ LÝ THAM SỐ DÒNG LỆNH
# ------------------------------------------------------------------------------
MODE_FAST=false
SAMPLE_INTERVAL=2

for arg in "$@"; do
    case "$arg" in
        --fast) MODE_FAST=true ;;
        --install)
            cp "$0" /usr/local/bin/check-proxy 2>/dev/null || sudo cp "$0" /usr/local/bin/check-proxy
            chmod +x /usr/local/bin/check-proxy 2>/dev/null || sudo chmod +x /usr/local/bin/check-proxy
            echo -e "${C_GREEN}✓ Đã cài đặt lệnh 'check-proxy' vào hệ thống!${C_RESET}"
            exit 0
            ;;
        --help|-h)
            echo "Cách dùng: bash check_network_proxy.sh [--fast] [--install]"
            exit 0
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo -e "${C_RED}LỖI: Script cần quyền root để đọc Network Namespace của container.${C_RESET}"
    echo -e "Vui lòng chạy lại với: ${C_YELLOW}sudo bash $0${C_RESET}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. KIỂM TRA CÔNG CỤ CẦN THIẾT
# ------------------------------------------------------------------------------
ensure_dependencies() {
    local missing_pkgs=()
    command -v curl >/dev/null 2>&1 || missing_pkgs+=("curl")
    command -v bc >/dev/null 2>&1 || missing_pkgs+=("bc")
    command -v ip >/dev/null 2>&1 || missing_pkgs+=("iproute2")
    command -v ss >/dev/null 2>&1 || missing_pkgs+=("iproute2")
    command -v nsenter >/dev/null 2>&1 || missing_pkgs+=("util-linux")

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq "${missing_pkgs[@]}" >/dev/null 2>&1 || true
    fi
}
ensure_dependencies

# ------------------------------------------------------------------------------
# 4. HÀM ĐỊNH DẠNG DỮ LIỆU
# ------------------------------------------------------------------------------
format_bytes() {
    local bytes=$1
    if (( $(echo "$bytes >= 1073741824" | bc -l 2>/dev/null || echo 0) )); then
        printf "%.2f GB" "$(echo "$bytes / 1073741824" | bc -l)"
    elif (( $(echo "$bytes >= 1048576" | bc -l 2>/dev/null || echo 0) )); then
        printf "%.2f MB" "$(echo "$bytes / 1048576" | bc -l)"
    elif (( $(echo "$bytes >= 1024" | bc -l 2>/dev/null || echo 0) )); then
        printf "%.2f KB" "$(echo "$bytes / 1024" | bc -l)"
    else
        printf "%d B" "$bytes"
    fi
}

format_rate() {
    local bytes_per_sec=$1
    local bits_per_sec
    bits_per_sec=$(echo "$bytes_per_sec * 8" | bc -l 2>/dev/null || echo 0)
    if (( $(echo "$bits_per_sec >= 1000000" | bc -l 2>/dev/null || echo 0) )); then
        printf "%.2f Mbps" "$(echo "$bits_per_sec / 1000000" | bc -l)"
    elif (( $(echo "$bits_per_sec >= 1000" | bc -l 2>/dev/null || echo 0) )); then
        printf "%.2f Kbps" "$(echo "$bits_per_sec / 1000" | bc -l)"
    else
        printf "%.0f bps" "$bits_per_sec"
    fi
}

# Lấy card mạng chính của Host
PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
if [[ -z "$PRIMARY_IFACE" ]]; then
    PRIMARY_IFACE=$(ip link show up 2>/dev/null | grep -E '^[0-9]+: (eth|ens|enp|eno|vtnet)' | awk -F': ' '{print $2}' | head -n1)
fi
PRIMARY_IFACE=${PRIMARY_IFACE:-"eth0"}

DEFAULT_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n1)
DEFAULT_GW=${DEFAULT_GW:-"Không xác định"}

# Lấy IP Public Host (Chỉ qua card mạng gốc, không qua proxy)
get_host_public_ip() {
    local ip=""
    local endpoints=("https://api.ipify.org" "https://icanhazip.com" "https://ifconfig.me")
    for ep in "${endpoints[@]}"; do
        ip=$(curl -s4 -m 3 --interface "$PRIMARY_IFACE" "$ep" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    echo "Không lấy được IP"
}

HOST_PUBLIC_IPV4=$(get_host_public_ip)

# ------------------------------------------------------------------------------
# 5. HIỂN THỊ THÔNG TIN HỆ THỐNG
# ------------------------------------------------------------------------------
clear
echo -e "${C_CYAN}==============================================================================${C_RESET}"
echo -e "${C_WHITE}${C_BOLD}   INTERNETINCOME BANDWIDTH & PROXY TELEMETRY AUDIT TOOL (TEST BRANCH)       ${C_RESET}"
echo -e "${C_CYAN}==============================================================================${C_RESET}"

ARCH=$(uname -m)
KERNEL=$(uname -r)
CPUS=$(nproc 2>/dev/null || echo 1)
UPTIME=$(uptime -p 2>/dev/null | sed 's/up //' || uptime)
VIRT=$(systemd-detect-virt 2>/dev/null || echo "Dedicated/Unknown")

RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
RAM_USED_KB=$(( RAM_TOTAL_KB - RAM_AVAIL_KB ))
RAM_TOTAL_MB=$(( RAM_TOTAL_KB / 1024 ))
RAM_USED_MB=$(( RAM_USED_KB / 1024 ))

ZRAM_DEV="/dev/zram0"
ZRAM_STATUS="${C_RED}Không kích hoạt${C_RESET}"
if [[ -b "$ZRAM_DEV" ]]; then
    ZRAM_SIZE_MB=$(cat /sys/block/zram0/disksize 2>/dev/null | awk '{print int($1/1048576)}')
    ZRAM_ALGO=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')
    ZRAM_STATUS="${C_GREEN}Kích hoạt (${ZRAM_SIZE_MB} MB, Thuật toán: ${ZRAM_ALGO:-zstd})${C_RESET}"
fi

TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "cubics")

echo -e " ${C_BOLD}1. THÔNG SỐ HỆ THỐNG & TÀI NGUYÊN:${C_RESET}"
echo -e "    • Phần cứng/Ảo hóa : ${C_GREEN}$VIRT${C_RESET} | Kiến trúc: ${C_GREEN}$ARCH${C_RESET} | CPU: ${C_GREEN}$CPUS cores${C_RESET}"
echo -e "    • Kernel / Uptime   : ${C_WHITE}$KERNEL${C_RESET} | ${C_WHITE}$UPTIME${C_RESET}"
echo -e "    • RAM Vật lý        : ${C_YELLOW}${RAM_USED_MB} MB / ${RAM_TOTAL_MB} MB${C_RESET} ($(( RAM_USED_MB * 100 / RAM_TOTAL_MB ))% đã dùng)"
echo -e "    • Bộ nhớ ZRAM       : $ZRAM_STATUS"
echo -e "    • TCP Congestion    : ${C_GREEN}$TCP_CC${C_RESET} $([[ "$TCP_CC" == "bbr" ]] && echo "✓" || echo "(Khuyến nghị BBR)")"
echo -e "    • Interface / GW    : ${C_WHITE}$PRIMARY_IFACE${C_RESET} | Default Gateway: ${C_WHITE}$DEFAULT_GW${C_RESET}"

# Hộp IP Whitelist nổi bật
echo -e ""
echo -e " ${C_BG_BLUE}${C_WHITE}${C_BOLD} [!] HOST PUBLIC IP DÀNH CHO IP-AUTHENTICATION PROXIES (WHITELIST IP) ${C_RESET}"
echo -e " ${C_BOLD} >>> IP HOST HIỆN TẠI : ${C_GREEN}${C_BOLD}${HOST_PUBLIC_IPV4}${C_RESET}"
echo -e " ${C_YELLOW} Hãy đảm bảo IP trên đã được Whitelist chính xác trong Dashboard nhà cung cấp Proxy!${C_RESET}"
echo -e "${C_CYAN}------------------------------------------------------------------------------${C_RESET}"

# ------------------------------------------------------------------------------
# 6. KIỂM TRA DNS HOST
# ------------------------------------------------------------------------------
echo -e " ${C_BOLD}2. KIỂM TRA CẤU HÌNH DNS HOST:${C_RESET}"
DNS_SERVERS=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
RESOLV_LINK=$(ls -l /etc/resolv.conf 2>/dev/null | awk '{print $NF}' || echo "/etc/resolv.conf")

echo -e "    • DNS Servers       : ${C_GREEN}${DNS_SERVERS:-Không tìm thấy}${C_RESET}"
echo -e "    • /etc/resolv.conf  : ${C_WHITE}$RESOLV_LINK${C_RESET}"

DNS_TEST_RESULT="${C_RED}Thất bại${C_RESET}"
if host -W 2 cloudflare.com >/dev/null 2>&1 || ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    DNS_TEST_RESULT="${C_GREEN}Hoạt động tốt (Direct Upstream)${C_RESET}"
fi
echo -e "    • Phân giải DNS Host: $DNS_TEST_RESULT"
echo -e "${C_CYAN}------------------------------------------------------------------------------${C_RESET}"

# ------------------------------------------------------------------------------
# 7. ĐỘ TRỄ LATENCY QUỐC TẾ (VN, AU, SG, JP, HK, EU, US) & TỐC ĐỘ GỐC HOST
# ------------------------------------------------------------------------------
if [[ "$MODE_FAST" == false ]]; then
    echo -e " ${C_BOLD}3. ĐỘ TRỄ (LATENCY) TỚI CÁC TRUNG TÂM MẠNG QUỐC TẾ & KHU VỰC:${C_RESET}"
    
    test_ping() {
        local name=$1
        local target=$2
        local res
        res=$(ping -c 2 -W 2 -I "$PRIMARY_IFACE" "$target" 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
        if [[ -n "$res" ]]; then
            printf "    • %-22s [%-15s] : ${C_GREEN}%6.1f ms${C_RESET}\n" "$name" "$target" "$res"
        else
            printf "    • %-22s [%-15s] : ${C_RED}Timeout / Blocked${C_RESET}\n" "$name" "$target"
        fi
    }

    test_ping "Việt Nam (VNPT Hub)"     "203.162.0.181"
    test_ping "Việt Nam (FPT Hub)"      "118.69.192.1"
    test_ping "Singapore (SG)"          "139.162.23.4"
    test_ping "Hong Kong (HK)"          "139.162.112.206"
    test_ping "Tokyo, Nhật Bản (JP)"    "139.162.65.37"
    test_ping "Sydney, Úc (AU)"         "139.162.244.17"
    test_ping "Frankfurt, Đức (EU)"     "139.162.130.8"
    test_ping "London, Anh (UK)"        "212.71.249.200"
    test_ping "US West (California, Mỹ)" "173.255.245.5"
    test_ping "US East (New York, Mỹ)"   "173.255.243.24"

    echo -e ""
    echo -e " ${C_BOLD}4. ĐO TỐC ĐỘ ĐƯỜNG TRUYỀN GỐC HOST (DOWNLOAD / UPLOAD DUPLEX):${C_RESET}"
    echo -e "    ${C_YELLOW}Đang đo tốc độ trực tiếp từ Host Interface (Cloudflare Edge)...${C_RESET}"
    
    DL_SPEED="Không đo được"
    UL_SPEED="Không đo được"

    # Download test 10MB
    DL_RAW=$(curl -s4 -m 5 --interface "$PRIMARY_IFACE" -w "%{speed_download}" -o /dev/null "https://speed.cloudflare.com/__down?bytes=10485760" 2>/dev/null || echo 0)
    if (( $(echo "$DL_RAW > 0" | bc -l 2>/dev/null || echo 0) )); then
        DL_SPEED=$(format_rate "$DL_RAW")
    fi

    # Upload test 2MB
    TMP_UL_FILE="/tmp/ii_up_sample.bin"
    head -c 2097152 /dev/urandom > "$TMP_UL_FILE" 2>/dev/null || true
    if [[ -f "$TMP_UL_FILE" ]]; then
        UL_RAW=$(curl -s4 -m 5 --interface "$PRIMARY_IFACE" -X POST --data-binary @"$TMP_UL_FILE" -w "%{speed_upload}" -o /dev/null "https://speed.cloudflare.com/__up" 2>/dev/null || echo 0)
        rm -f "$TMP_UL_FILE"
        if (( $(echo "$UL_RAW > 0" | bc -l 2>/dev/null || echo 0) )); then
            UL_SPEED=$(format_rate "$UL_RAW")
        fi
    fi

    echo -e "    • Direct Download : ${C_GREEN}${C_BOLD}$DL_SPEED${C_RESET}"
    echo -e "    • Direct Upload   : ${C_GREEN}${C_BOLD}$UL_SPEED${C_RESET}"
    echo -e "${C_CYAN}------------------------------------------------------------------------------${C_RESET}"
fi

# ------------------------------------------------------------------------------
# 8. PASSIVE CONTAINER & PROXY TELEMETRY (100% THỤ ĐỘNG - BẢO VỆ IP-AUTH)
# ------------------------------------------------------------------------------
echo -e " ${C_BOLD}5. KIỂM TRA CHI TIẾT CONTAINER INTERNETINCOME & PROXY TELEMETRY:${C_RESET}"
echo -e "    ${C_YELLOW}Phương pháp: Thu thập thụ động qua Kernel Namespace (Zero External Request)${C_RESET}"

CONTAINER_LIST=$(docker ps -a --format '{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null || true)

if [[ -z "$CONTAINER_LIST" ]]; then
    echo -e "\n    ${C_YELLOW}[!] Chưa có container InternetIncome nào đang chạy trên máy.${C_RESET}"
    echo -e "    ${C_WHITE}➔ Bạn hãy khởi chạy tool theo nhánh test:${C_RESET}"
    echo -e "       1. Điền ${C_CYAN}properties.conf${C_RESET} và danh sách proxy vào ${C_CYAN}proxies.txt${C_RESET}"
    echo -e "       2. Chạy ${C_CYAN}bash internetIncome.sh --start${C_RESET}"
    echo -e "       3. Gõ lại ${C_GREEN}check-proxy${C_RESET} để xem bảng dữ liệu lưu lượng từng proxy!"
    echo -e "${C_CYAN}==============================================================================${C_RESET}"
    exit 0
fi

echo -e "    ${C_YELLOW}Đang lấy mẫu dữ liệu lưu lượng trong $SAMPLE_INTERVAL giây...${C_RESET}"

echo -e ""
printf " ${C_BOLD}%-18s %-12s %-10s %-8s %-12s %-12s %-15s${C_RESET}\n" \
    "CONTAINER" "TRẠNG THÁI" "RAM DÙNG" "SOCKETS" "TỐC ĐỘ (KB/s)" "TỔNG DỮ LIỆU" "ĐÁNH GIÁ PROXY"
printf " %-18s %-12s %-10s %-8s %-12s %-12s %-15s\n" \
    "------------------" "------------" "----------" "--------" "------------" "------------" "---------------"

TOTAL_ACTIVE_NODES=0
TOTAL_IDLE_NODES=0
TOTAL_DEAD_NODES=0
TOTAL_CONTAINERS=0

declare -A T1_RX T1_TX CPIDS APP_NAMES APP_STATUS APP_MEM

read_container_net_bytes() {
    local pid=$1
    if [[ ! -d "/proc/$pid/net" ]]; then
        echo "0 0"
        return
    fi
    awk '
        /tun0:|tap0:/ { tun_rx += $2; tun_tx += $10; has_tun = 1 }
        /eth0:/       { eth_rx += $2; eth_tx += $10 }
        END {
            if (has_tun == 1) {
                print tun_rx+0, tun_tx+0
            } else {
                print eth_rx+0, eth_tx+0
            }
        }
    ' "/proc/$pid/net/dev" 2>/dev/null || echo "0 0"
}

# Lấy mẫu T1
while IFS='|' read -r CID CNAME CSTAT CIMG; do
    [[ -z "$CID" ]] && continue
    ((TOTAL_CONTAINERS++))
    
    CPID=$(docker inspect --format '{{.State.Pid}}' "$CID" 2>/dev/null || echo 0)
    CPIDS["$CID"]=$CPID
    APP_NAMES["$CID"]=$CNAME
    APP_STATUS["$CID"]=$CSTAT
    
    MEM_USAGE=$(docker stats --no-stream --format "{{.MemUsage}}" "$CID" 2>/dev/null | awk '{print $1}' || echo "N/A")
    APP_MEM["$CID"]=$MEM_USAGE

    if [[ "$CPID" -gt 0 ]]; then
        read -r r1 t1 < <(read_container_net_bytes "$CPID")
        T1_RX["$CID"]=$r1
        T1_TX["$CID"]=$t1
    else
        T1_RX["$CID"]=0
        T1_TX["$CID"]=0
    fi
done <<< "$CONTAINER_LIST"

sleep "$SAMPLE_INTERVAL"

# Tính toán T2 và hiển thị
while IFS='|' read -r CID CNAME CSTAT CIMG; do
    [[ -z "$CID" ]] && continue
    CPID=${CPIDS["$CID"]}
    MEM_STR=${APP_MEM["$CID"]:-"N/A"}
    
    DISP_NAME=$(echo "$CNAME" | cut -c1-18)
    
    if [[ "$CSTAT" =~ ^Up ]]; then
        if [[ "$CSTAT" =~ Restarting ]]; then
            DISP_STAT="${C_RED}Flapping${C_RESET}"
            ((TOTAL_DEAD_NODES++))
        else
            DISP_STAT="${C_GREEN}Running${C_RESET}"
        fi
    else
        DISP_STAT="${C_RED}Stopped${C_RESET}"
        ((TOTAL_DEAD_NODES++))
    fi

    ESTAB_SOCKETS=0
    DELTA_SPEED_KBS="0.0"
    TOTAL_DATA_STR="0 B"
    PROXY_HEALTH="${C_RED}Chết / Lỗi${C_RESET}"

    if [[ "$CPID" -gt 0 && -d "/proc/$CPID/net" ]]; then
        read -r r2 t2 < <(read_container_net_bytes "$CPID")
        
        # Đếm socket ESTABLISHED thực tế bên trong namespace (Thụ động 100%)
        ESTAB_SOCKETS=$(nsenter -t "$CPID" -n ss -tan state established 2>/dev/null | grep -vc 'Recv-Q' || echo 0)

        r1=${T1_RX["$CID"]:-0}
        t1=${T1_TX["$CID"]:-0}
        delta_rx=$(( r2 - r1 ))
        delta_tx=$(( t2 - t1 ))
        delta_total=$(( delta_rx + delta_tx ))
        [[ "$delta_total" -lt 0 ]] && delta_total=0

        DELTA_SPEED_KBS=$(echo "scale=1; ($delta_total / $SAMPLE_INTERVAL) / 1024" | bc -l 2>/dev/null || echo "0.0")
        sum_total=$(( r2 + t2 ))
        TOTAL_DATA_STR=$(format_bytes "$sum_total")

        # Đánh giá hoàn toàn thụ động (Zero External Request)
        if [[ "$ESTAB_SOCKETS" -gt 0 && $(echo "$DELTA_SPEED_KBS > 0" | bc -l 2>/dev/null || echo 0) -eq 1 ]]; then
            PROXY_HEALTH="${C_GREEN}Tốt (Active)${C_RESET}"
            ((TOTAL_ACTIVE_NODES++))
        elif [[ "$ESTAB_SOCKETS" -gt 0 ]]; then
            PROXY_HEALTH="${C_YELLOW}Chờ (Idle/Wait)${C_RESET}"
            ((TOTAL_IDLE_NODES++))
        elif [[ "$sum_total" -gt 1048576 ]]; then
            PROXY_HEALTH="${C_YELLOW}Tạm nghỉ (Sleep)${C_RESET}"
            ((TOTAL_IDLE_NODES++))
        else
            PROXY_HEALTH="${C_RED}Mất kết nối${C_RESET}"
            ((TOTAL_DEAD_NODES++))
        fi
    fi

    printf " %-18s %-21b %-10s %-8s %-12s %-12s %-24b\n" \
        "$DISP_NAME" "$DISP_STAT" "$MEM_STR" "$ESTAB_SOCKETS" "${DELTA_SPEED_KBS} K/s" "$TOTAL_DATA_STR" "$PROXY_HEALTH"

done <<< "$CONTAINER_LIST"

echo -e "${C_CYAN}------------------------------------------------------------------------------${C_RESET}"

# ------------------------------------------------------------------------------
# 9. TỔNG KẾT
# ------------------------------------------------------------------------------
echo -e " ${C_BOLD}6. TỔNG KẾT TÌNH TRẠNG PROXY & CHIA SẺ BĂNG THÔNG:${C_RESET}"
echo -e "    • Tổng số container đã quét  : ${C_WHITE}${C_BOLD}$TOTAL_CONTAINERS${C_RESET}"
echo -e "    • Nodes hoạt động tốt (Active): ${C_GREEN}${C_BOLD}$TOTAL_ACTIVE_NODES${C_RESET} container (Có socket & đang truyền data)"
echo -e "    • Nodes ở chế độ chờ (Idle)  : ${C_YELLOW}${C_BOLD}$TOTAL_IDLE_NODES${C_RESET} container (Proxy sống, chờ phân phối task)"
echo -e "    • Nodes lỗi / Mất kết nối   : ${C_RED}${C_BOLD}$TOTAL_DEAD_NODES${C_RESET} container (Cần kiểm tra IP-Auth hoặc Proxy)"

echo -e ""
echo -e " ${C_BOLD}7. HƯỚNG DẪN XỬ LÝ NHANH KHI GẶP LỖI:${C_RESET}"
if [[ "$TOTAL_DEAD_NODES" -gt 0 ]]; then
    echo -e "    ${C_RED}[!] Phát hiện $TOTAL_DEAD_NODES nodes không có kết nối:${C_RESET}"
    echo -e "    1. Kiểm tra Dashboard nhà cung cấp proxy: Đã whitelist đúng IP ${C_GREEN}${HOST_PUBLIC_IPV4}${C_RESET} chưa?"
    echo -e "    2. Kiểm tra log FlapGuard: ${C_WHITE}cat /var/log/ii-flapguard.log${C_RESET}"
    echo -e "    3. Khởi động lại hệ thống mạng nếu cần: ${C_WHITE}systemctl restart docker${C_RESET}"
else
    echo -e "    ${C_GREEN}✓ Toàn bộ hệ thống đang hoạt động tối ưu. Không phát sinh xung đột IP-Auth.${C_RESET}"
fi

echo -e "${C_CYAN}==============================================================================${C_RESET}"
echo -e " ${C_WHITE}Kiểm tra hoàn tất lúc: $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}\n"

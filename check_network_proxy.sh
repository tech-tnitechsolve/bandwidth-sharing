#!/usr/bin/env bash
# ==============================================================================
# Script: check_network_proxy.sh (InternetIncome Network & Proxy Telemetry Audit)
# Phiên bản: 3.0 - Chuẩn hóa cho nhánh Test & Tối ưu tuyệt đối cho IP-Auth Proxies
# Tính năng:
#   - 100% PASSIVE TELEMETRY: Không gọi request ra ngoài qua Proxy (Bảo vệ IP-Auth).
#   - Nhận diện chính xác IP Host Whitelist cho các loại Proxy IP-Authentication.
#   - Đo lường Socket ESTABLISHED, RX/TX Delta, ZRAM/RAM, DNS, Ping & Speed 2 chiều.
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
C_BG_GREEN='\033[42;30m'
C_BG_RED='\033[41;37m'

# ------------------------------------------------------------------------------
# 2. CẤU HÌNH VÀ THAM SỐ DÒNG LỆNH
# ------------------------------------------------------------------------------
MODE_FAST=false
MODE_ACTIVE_PROBE=false
SAMPLE_INTERVAL=2

show_help() {
    echo -e "${C_BOLD}CÁCH SỬ DỤNG:${C_RESET}"
    echo -e "  bash check_network_proxy.sh [TÙY CHỌN]"
    echo -e ""
    echo -e "${C_BOLD}TÙY CHỌN:${C_RESET}"
    echo -e "  ${C_CYAN}--fast${C_RESET}         Kiểm tra siêu tốc (Bỏ qua Speedtest & Latency toàn cầu)."
    echo -e "  ${C_CYAN}--probe${C_RESET}        Kích hoạt Egress IP Probe (Thăm dò IP qua container - Có delay an toàn)."
    echo -e "  ${C_CYAN}--install${C_RESET}      Cài đặt shortcut '${C_GREEN}check-proxy${C_RESET}' vào /usr/local/bin."
    echo -e "  ${C_CYAN}--help, -h${C_RESET}     Hiển thị hướng dẫn này."
    echo -e ""
    echo -e "${C_YELLOW}Lưu ý về IP-Auth:${C_RESET} Chế độ mặc định là ${C_GREEN}Passive 100%${C_RESET} (Không tạo request ra ngoài qua proxy,"
    echo -e "tránh bị nhà cung cấp proxy đánh dấu spam hoặc rate-limit)."
    exit 0
}

# Xử lý tham số
for arg in "$@"; do
    case "$arg" in
        --fast) MODE_FAST=true ;;
        --probe) MODE_ACTIVE_PROBE=true ;;
        --install)
            cp "$0" /usr/local/bin/check-proxy 2>/dev/null || sudo cp "$0" /usr/local/bin/check-proxy
            chmod +x /usr/local/bin/check-proxy 2>/dev/null || sudo chmod +x /usr/local/bin/check-proxy
            echo -e "${C_GREEN}✓ Đã cài đặt thành công! Bạn có thể gõ lệnh '${C_WHITE}check-proxy${C_GREEN}' ở bất kỳ đâu.${C_RESET}"
            exit 0
            ;;
        --help|-h) show_help ;;
        *) echo -e "${C_RED}Tùy chọn không hợp lệ: $arg${C_RESET}"; show_help ;;
    esac
done

# Kiểm tra quyền root
if [[ $EUID -ne 0 ]]; then
    echo -e "${C_RED}LỖI: Script cần quyền root để đọc Network Namespace của Container.${C_RESET}"
    echo -e "Vui lòng chạy lại với: ${C_YELLOW}sudo bash $0${C_RESET}"
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. KIỂM TRA VÀ CÀI ĐẶT CÔNG CỤ CẦN THIẾT
# ------------------------------------------------------------------------------
ensure_dependencies() {
    local missing_pkgs=()
    command -v curl >/dev/null 2>&1 || missing_pkgs+=("curl")
    command -v bc >/dev/null 2>&1 || missing_pkgs+=("bc")
    command -v jq >/dev/null 2>&1 || missing_pkgs+=("jq")
    command -v ip >/dev/null 2>&1 || missing_pkgs+=("iproute2")
    command -v ss >/dev/null 2>&1 || missing_pkgs+=("iproute2")
    command -v nsenter >/dev/null 2>&1 || missing_pkgs+=("util-linux")

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        echo -e "${C_YELLOW}Đang cài đặt các gói phụ trợ thiếu: ${missing_pkgs[*]}...${C_RESET}"
        apt-get update -qq >/dev/null 2>&1 || yum makecache -q >/dev/null 2>&1 || true
        apt-get install -y -qq "${missing_pkgs[@]}" >/dev/null 2>&1 || yum install -y -q "${missing_pkgs[@]}" >/dev/null 2>&1 || true
    fi
}
ensure_dependencies

# ------------------------------------------------------------------------------
# 4. HÀM TIỆN ÍCH ĐỊNH DẠNG & ĐO ĐẠC HỆ THỐNG
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

# Lấy card mạng chính và Default Gateway
PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
if [[ -z "$PRIMARY_IFACE" ]]; then
    PRIMARY_IFACE=$(ip link show up 2>/dev/null | grep -E '^[0-9]+: (eth|ens|enp|eno|vtnet)' | awk -F': ' '{print $2}' | head -n1)
fi
PRIMARY_IFACE=${PRIMARY_IFACE:-"eth0"}

DEFAULT_GW=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n1)
DEFAULT_GW=${DEFAULT_GW:-"Không xác định"}

# Lấy IP Public Host (Chỉ qua card mạng chính - Khóa cứng interface)
get_host_public_ip() {
    local ip=""
    local endpoints=(
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ifconfig.me"
        "https://ipecho.net/plain"
        "https://checkip.amazonaws.com"
    )
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
# 5. HIỂN THỊ HEADER & THÔNG TIN HỆ THỐNG
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

# RAM & ZRAM
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

# Congestion Control (BBR)
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
# 6. KIỂM TRA DNS & PHÂN GIẢI DIRECT TỪ HOST
# ------------------------------------------------------------------------------
echo -e " ${C_BOLD}2. KIỂM TRA CẤU HÌNH DNS HOST:${C_RESET}"
DNS_SERVERS=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
RESOLV_LINK=$(ls -l /etc/resolv.conf 2>/dev/null | awk '{print $NF}' || echo "/etc/resolv.conf")

echo -e "    • DNS Servers       : ${C_GREEN}${DNS_SERVERS:-Không tìm thấy}${C_RESET}"
echo -e "    • /etc/resolv.conf  : ${C_WHITE}$RESOLV_LINK${C_RESET}"

DNS_TEST_RESULT="${C_RED}Thất bại${C_RESET}"
if host -W 2 cloudflare.com >/dev/null 2>&1 || ping -c 1 -W 2 cloudflare.com >/dev/null 2>&1; then
    DNS_TEST_RESULT="${C_GREEN}Hoạt động tốt (Direct Upstream)${C_RESET}"
fi
echo -e "    • Phân giải DNS Host: $DNS_TEST_RESULT"
echo -e "${C_CYAN}------------------------------------------------------------------------------${C_RESET}"

# ------------------------------------------------------------------------------
# 7. KIỂM TRA ĐƯỜNG TRUYỀN & LATENCY TOÀN CẦU (NẾU KHÔNG DÙNG --FAST)
# ------------------------------------------------------------------------------
if [[ "$MODE_FAST" == false ]]; then
    echo -e " ${C_BOLD}3. ĐỘ TRỄ (LATENCY) TỪ HOST ĐẾN CÁC HUB CHÍNH:${C_RESET}"
    
    test_ping() {
        local name=$1
        local target=$2
        local res
        res=$(ping -c 2 -W 2 -I "$PRIMARY_IFACE" "$target" 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
        if [[ -n "$res" ]]; then
            printf "    • %-18s [%-15s] : ${C_GREEN}%6.1f ms${C_RESET}\n" "$name" "$target" "$res"
        else
            printf "    • %-18s [%-15s] : ${C_RED}Timeout / Blocked${C_RESET}\n" "$name" "$target"
        fi
    }

    test_ping "Cloudflare DNS" "1.1.1.1"
    test_ping "Google DNS"     "8.8.8.8"
    test_ping "Singapore Hub"  "1.0.0.1"
    test_ping "Tokyo Hub"      "103.102.166.224"
    test_ping "Frankfurt Hub"  "194.25.0.68"
    test_ping "US West (CA)"   "199.102.73.1"
    test_ping "US East (VA)"   "208.67.222.222"

    echo -e ""
    echo -e " ${C_BOLD}4. ĐO TỐC ĐỘ ĐƯỜNG TRUYỀN GỐC HOST (DOWNLOAD / UPLOAD DUPLEX):${C_RESET}"
    echo -e "    ${C_YELLOW}Đang đo tốc độ trực tiếp từ Host Interface (Cloudflare Edge)...${C_RESET}"
    
    DL_SPEED="Không đo được"
    UL_SPEED="Không đo được"

    # Download test 10MB (timeout 5s)
    DL_RAW=$(curl -s4 -m 5 --interface "$PRIMARY_IFACE" -w "%{speed_download}" -o /dev/null "https://speed.cloudflare.com/__down?bytes=10485760" 2>/dev/null || echo 0)
    if (( $(echo "$DL_RAW > 0" | bc -l 2>/dev/null || echo 0) )); then
        DL_SPEED=$(format_rate "$DL_RAW")
    fi

    # Upload test 2MB (timeout 5s)
    UL_PAYLOAD=$(head -c 2097152 /dev/zero 2>/dev/null || true)
    if [[ -n "$UL_PAYLOAD" ]]; then
        UL_RAW=$(curl -s4 -m 5 --interface "$PRIMARY_IFACE" -X POST -d "$UL_PAYLOAD" -w "%{speed_upload}" -o /dev/null "https://speed.cloudflare.com/__up" 2>/dev/null || echo 0)
        if (( $(echo "$UL_RAW > 0" | bc -l 2>/dev/null || echo 0) )); then
            UL_SPEED=$(format_rate "$UL_RAW")
        fi
    fi

    echo -e "    • Direct Download : ${C_GREEN}${C_BOLD}$DL_SPEED${C_RESET}"
    echo -e "    • Direct Upload   : ${C_GREEN}${C_BOLD}$UL_SPEED${C_RESET}"
    echo -e "${C_CYAN}------------------------------------------------------------------------------${C_RESET}"
fi

# ------------------------------------------------------------------------------
# 8. PASSIVE CONTAINER & PROXY TELEMETRY (CHÍNH XÁC CHO INTERNETINCOME)
# ------------------------------------------------------------------------------
echo -e " ${C_BOLD}5. KIỂM TRA CHI TIẾT CONTAINER INTERNETINCOME & PROXY TELEMETRY:${C_RESET}"
echo -e "    ${C_YELLOW}Phương pháp: Thu thập thụ động qua Kernel Namespace (Zero External Request)${C_RESET}"
echo -e "    ${C_YELLOW}Đang lấy mẫu dữ liệu lưu lượng trong $SAMPLE_INTERVAL giây...${C_RESET}"

CONTAINER_LIST=$(docker ps -a --format '{{.ID}}|{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null || true)

if [[ -z "$CONTAINER_LIST" ]]; then
    echo -e "\n    ${C_RED}Không tìm thấy container Docker nào đang chạy trên máy!${C_RESET}"
    echo -e "${C_CYAN}==============================================================================${C_RESET}"
    exit 0
fi

# In Header bảng
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

# Hàm đọc RX/TX tối ưu cho InternetIncome TUN/Bridge
read_container_net_bytes() {
    local pid=$1
    if [[ ! -d "/proc/$pid/net" ]]; then
        echo "0 0"
        return
    fi
    awk '
        # Nếu có tun0/tap0 (hev-socks5-tunnel / tun2proxy): Lấy tun0 làm chuẩn payload
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

# Lấy dữ liệu T1
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

# Chờ đúng khoảng thời gian mẫu
sleep "$SAMPLE_INTERVAL"

# Vòng lặp tính toán T2 và hiển thị
while IFS='|' read -r CID CNAME CSTAT CIMG; do
    [[ -z "$CID" ]] && continue
    CPID=${CPIDS["$CID"]}
    MEM_STR=${APP_MEM["$CID"]:-"N/A"}
    
    DISP_NAME=$(echo "$CNAME" | cut -c1-18)
    
    # Đánh giá trạng thái Docker
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

        # Đếm socket ESTABLISHED từ host vào namespace của container
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

        # Đánh giá sức khỏe Proxy hoàn toàn thụ động
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
        
        # Chỉ khi bật cờ --probe thủ công mới chạy Egress Probe
        if [[ "$MODE_ACTIVE_PROBE" == true && "$CSTAT" =~ ^Up ]]; then
            OUT_IP=$(timeout 3 nsenter -t "$CPID" -n curl -s4 -m 2 https://api.ipify.org 2>/dev/null || echo "Timeout")
            PROXY_HEALTH="${PROXY_HEALTH} (${OUT_IP})"
            sleep 0.2
        fi
    fi

    printf " %-18s %-21b %-10s %-8s %-12s %-12s %-24b\n" \
        "$DISP_NAME" "$DISP_STAT" "$MEM_STR" "$ESTAB_SOCKETS" "${DELTA_SPEED_KBS} K/s" "$TOTAL_DATA_STR" "$PROXY_HEALTH"

done <<< "$CONTAINER_LIST"

echo -e "${C_CYAN}------------------------------------------------------------------------------${C_RESET}"

# ------------------------------------------------------------------------------
# 9. TỔNG KẾT & KHUYẾN NGHỊ VẬN HÀNH
# ------------------------------------------------------------------------------
echo -e " ${C_BOLD}6. TỔNG KẾT TÌNH TRẠNG PROXY & CHIA SẺ BĂNG THÔNG:${C_RESET}"
echo -e "    • Tổng số container đã quét  : ${C_WHITE}${C_BOLD}$TOTAL_CONTAINERS${C_RESET}"
echo -e "    • Nodes hoạt động tốt (Active): ${C_GREEN}${C_BOLD}$TOTAL_ACTIVE_NODES${C_RESET} container (Đang có socket & phát sinh traffic)"
echo -e "    • Nodes ở chế độ chờ (Idle)  : ${C_YELLOW}${C_BOLD}$TOTAL_IDLE_NODES${C_RESET} container (Proxy sống, chờ nhà mạng phân phối task)"
echo -e "    • Nodes lỗi / Mất kết nối   : ${C_RED}${C_BOLD}$TOTAL_DEAD_NODES${C_RESET} container (Cần kiểm tra IP-Auth hoặc Proxy)"

echo -e ""
echo -e " ${C_BOLD}7. HƯỚNG DẪN XỬ LÝ NHANH KHI GẶP LỖI:${C_RESET}"
if [[ "$TOTAL_DEAD_NODES" -gt 0 ]]; then
    echo -e "    ${C_RED}[!] Phát hiện $TOTAL_DEAD_NODES nodes không có kết nối:${C_RESET}"
    echo -e "    1. Kiểm tra Dashboard nhà cung cấp proxy: Đã whitelist đúng IP ${C_GREEN}${HOST_PUBLIC_IPV4}${C_RESET} chưa?"
    echo -e "    2. Kiểm tra log FlapGuard: ${C_WHITE}cat /var/log/ii-flapguard.log${C_RESET}"
    echo -e "    3. Khởi động lại hệ thống mạng nếu cần: ${C_WHITE}systemctl restart docker${C_RESET}"
else
    echo -e "    ${C_GREEN}✓ Toàn bộ hệ thống đang hoạt động tối ưu. Không phát hiện xung đột IP-Auth.${C_RESET}"
fi

echo -e "${C_CYAN}==============================================================================${C_RESET}"
echo -e " ${C_WHITE}Kiểm tra hoàn tất lúc: $(date '+%Y-%m-%d %H:%M:%S')${C_RESET}\n"

#!/usr/bin/env bash
# ==============================================================================
# Script: check_network_proxy.sh (Phiên bản Anti-Block & Multi-Fallback)
# Tự động vượt Firewall / Cloudflare WAF / Anti-Bot / Chặn ICMP Ping
# Đo lường 100% dữ liệu thực tế cho Proxy IP-Authentication & Containers
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[!] Lỗi: Bắt buộc phải chạy script với quyền root:\033[0m"
    echo -e "    \033[1;32msudo bash $0\033[0m"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# User-Agent chuẩn trình duyệt tránh bị Cloudflare / WAF chặn
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

clear
echo -e "${CYAN}${BOLD}================================================================================${NC}"
echo -e "${GREEN}${BOLD}   HỆ THỐNG ĐO LƯỜNG ĐƯỜNG TRUYỀN & PROXY (PHIÊN BẢN CHỐNG CHẶN / ANTI-BLOCK)   ${NC}"
echo -e "${YELLOW}       (Tự động vượt qua Cloudflare WAF, Chặn ICMP Ping & Bóp gói Datacenter)   ${NC}"
echo -e "${CYAN}${BOLD}================================================================================${NC}\n"

# 1. CÀI ĐẶT CÔNG CỤ CẦN THIẾT
echo -e "${BLUE}[*] Đang đồng bộ công cụ đo lường...${NC}"
install_deps() {
    local pkgs=("$@")
    if command -v apt-get &>/dev/null; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q "${pkgs[@]}" >/dev/null 2>&1
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "${pkgs[@]}" >/dev/null 2>&1
    fi
}

REQ_PKGS=()
command -v jq &>/dev/null || REQ_PKGS+=("jq")
command -v bc &>/dev/null || REQ_PKGS+=("bc")
command -v curl &>/dev/null || REQ_PKGS+=("curl")
command -v wget &>/dev/null || REQ_PKGS+=("wget")
command -v tar &>/dev/null || REQ_PKGS+=("tar")
command -v ss &>/dev/null || REQ_PKGS+=("iproute2")
command -v nsenter &>/dev/null || REQ_PKGS+=("util-linux")
command -v ping &>/dev/null || REQ_PKGS+=("iputils-ping")

[ ${#REQ_PKGS[@]} -gt 0 ] && install_deps "${REQ_PKGS[@]}"

# 2. XÁC ĐỊNH GIAO DIỆN MẠNG & LẤY PUBLIC IPV4 BẰNG CƠ CHẾ DỰ PHÒNG 4 TẦNG
PRIMARY_IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
LOCAL_SRC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')

get_public_ipv4() {
    local ip=""
    ip=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" --max-time 4 https://api.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" --max-time 4 https://icanhazip.com 2>/dev/null | tr -d '\n')
    [ -z "$ip" ] && ip=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" --max-time 4 https://ifconfig.me 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" --max-time 4 https://checkip.amazonaws.com 2>/dev/null | tr -d '\n')
    echo "$ip"
}

PUBLIC_IPV4=$(get_public_ipv4)

# Lấy thông tin ISP bằng API không giới hạn rate-limit (ip-api.com)
IP_INFO=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" --max-time 5 "http://ip-api.com/json/${PUBLIC_IPV4}?fields=status,country,city,isp,org,as" 2>/dev/null)
ISP_NAME=$(echo "$IP_INFO" | grep -o '"org": *"[^"]*"' | head -1 | cut -d'"' -f4)
[ -z "$ISP_NAME" ] && ISP_NAME=$(echo "$IP_INFO" | grep -o '"isp": *"[^"]*"' | head -1 | cut -d'"' -f4)
COUNTRY=$(echo "$IP_INFO" | grep -o '"country": *"[^"]*"' | head -1 | cut -d'"' -f4)
CITY=$(echo "$IP_INFO" | grep -o '"city": *"[^"]*"' | head -1 | cut -d'"' -f4)

# Tỷ lệ TCP Retransmit của Kernel
TCP_OUT=$(awk '/Tcp:/ {print $11}' /proc/net/snmp 2>/dev/null | tail -1)
TCP_RETRANS=$(awk '/Tcp:/ {print $13}' /proc/net/snmp 2>/dev/null | tail -1)
GLOBAL_RETRANS_RATE="0.00"
if [ -n "$TCP_OUT" ] && [ "$TCP_OUT" -gt 0 ] 2>/dev/null; then
    GLOBAL_RETRANS_RATE=$(echo "scale=2; ($TCP_RETRANS * 100) / $TCP_OUT" | bc -l 2>/dev/null || echo "0.00")
fi

IP_FW=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
IP_FW_STATUS="${RED}Tắt (Container không NAT được!)${NC}"
[ "$IP_FW" -eq 1 ] 2>/dev/null && IP_FW_STATUS="${GREEN}Đã Bật (Sẵn sàng NAT IP Whitelist)${NC}"

echo -e "\n${PURPLE}${BOLD}--- [1] THÔNG TIN MẠNG GỐC & IP AUTHENTICATION ---${NC}"
echo -e " 🔑 ${BOLD}IP WHITELIST (Dùng cho Dashboard Proxy):${NC} ${GREEN}${BOLD}${PUBLIC_IPV4}${NC}"
printf "%-26s: %s (IP LAN: %s)\n" "Card mạng Outbound" "$PRIMARY_IFACE" "$LOCAL_SRC_IP"
printf "%-26s: %s (%s, %s)\n" "Nhà mạng / DataCenter" "$ISP_NAME" "$CITY" "$COUNTRY"
printf "%-26s: %b\n" "IPv4 Forwarding (NAT)" "$IP_FW_STATUS"
printf "%-26s: %s%%\n" "Tỷ lệ TCP Retransmission" "$GLOBAL_RETRANS_RATE"

# 3. ĐO ĐỘ TRỄ HYBRID (ICMP PING + TỰ ĐỘNG CHUYỂN TCP/HTTP PING NẾU BỊ CHẶN)
echo -e "\n${PURPLE}${BOLD}--- [2] ĐO ĐỘ TRỄ HYBRID (CHỐNG FIREWALL CHẶN PING ICMP) ---${NC}"
printf "${BOLD}%-24s | %-12s | %-12s | %-15s${NC}\n" "Khu vực Hub Proxy" "Độ trễ (Ping)" "Giao thức" "Trạng thái"
echo "------------------------------------------------------------------------"

test_hybrid_ping() {
    local region="$1"
    local icmp_target="$2"
    local http_target="$3"

    # Bước 1: Thử nghiệm ICMP Ping chuẩn
    local ping_cmd
    ping_cmd=$(ping -4 -I "$PRIMARY_IFACE" -c 5 -W 2 "$icmp_target" 2>/dev/null)
    local loss=$(echo "$ping_cmd" | grep -o '[0-9]*% packet loss' | cut -d'%' -f1)

    if [ -n "$loss" ] && [ "$loss" -lt 100 ]; then
        local avg_ping=$(echo "$ping_cmd" | tail -1 | awk -F '/' '{print $5}')
        [ -z "$avg_ping" ] && avg_ping=$(echo "$ping_cmd" | grep -o 'avg = [0-9.]*' | cut -d' ' -f3)
        printf "%-24s | ${GREEN}%-9s ms${NC} | %-12s | %b\n" "$region" "$avg_ping" "ICMP Ping" "${GREEN}Mở (Sạch)${NC}"
        return
    fi

    # Bước 2: Nếu ICMP Ping bị Datacenter chặn (100% loss) -> Chuyển sang đo TCP/HTTP Connect Latency
    local start_ms=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" -w "%{time_connect}" -o /dev/null --max-time 4 "$http_target" 2>/dev/null)
    if [ -n "$start_ms" ] && (( $(echo "$start_ms > 0" | bc -l 2>/dev/null || echo "0") )); then
        local tcp_ping=$(echo "scale=1; $start_ms * 1000" | bc 2>/dev/null)
        printf "%-24s | ${CYAN}%-9s ms${NC} | %-12s | %b\n" "$region" "$tcp_ping" "TCP/HTTP (Bypass)" "${YELLOW}Chặn ICMP (Đã vượt)${NC}"
    else
        printf "%-24s | ${RED}%-9s ms${NC} | %-12s | %b\n" "$region" "Timeout" "Failed" "${RED}Mất kết nối hoàn toàn${NC}"
    fi
}

test_hybrid_ping "1. US West (Los Angeles)"  "104.223.10.2"   "http://speedtest.fremont.linode.com"
test_hybrid_ping "2. US East (New York/NJ)"  "208.77.17.2"    "http://speedtest.newark.linode.com"
test_hybrid_ping "3. EU (Đức - Frankfurt)"   "91.107.223.4"   "http://speedtest.frankfurt.linode.com"
test_hybrid_ping "4. UK (Anh - London)"       "185.42.223.67"  "http://speedtest.london.linode.com"
test_hybrid_ping "5. FR (Pháp - OVH RBX)"     "185.125.63.14"  "http://rbx.proof.ovh.net"
test_hybrid_ping "6. Asia (Singapore)"        "1.0.0.1"        "http://speedtest.singapore.linode.com"

# 4. ĐO BĂNG THÔNG TRỰC TIẾP QUA LOOKING GLASS DATA CENTER (KHÔNG QUA CLOUDFLARE WAF)
echo -e "\n${PURPLE}${BOLD}--- [3] ĐO BĂNG THÔNG THỰC TẾ (TRỰC TIẾP QUA DATA CENTER LOOKING GLASS) ---${NC}"
echo -e "${YELLOW}File test được lấy trực tiếp từ hạ tầng Datacenter gốc (Bypass 100% Cloudflare/Captcha)...${NC}\n"
printf "${BOLD}%-24s | %-16s | %-16s | %-12s${NC}\n" "Vị trí máy chủ Test" "Tốc độ Download" "Hạ tầng Datacenter" "Trạng thái"
echo "--------------------------------------------------------------------------------"

TMP_DIR="/tmp/bench_clean_$(date +%s)"
mkdir -p "$TMP_DIR"

run_direct_speedtest() {
    local target_name="$1"
    local url="$2"
    local dc_name="$3"

    # Tải 10MB data trực tiếp qua HTTP bằng cURL với User-Agent chuẩn
    local speed_raw
    speed_raw=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" -w "%{speed_download} %{http_code}" -o /dev/null --max-time 8 "$url" 2>/dev/null)
    
    local speed_bytes=$(echo "$speed_raw" | awk '{print $1}')
    local http_code=$(echo "$speed_raw" | awk '{print $2}')

    if [ "$http_code" == "200" ] && [ -n "$speed_bytes" ] && [ "$speed_bytes" -gt 0 ]; then
        local dl_mbps=$(echo "scale=2; $speed_bytes * 8 / 1000000" | bc 2>/dev/null)
        printf "%-24s | ${GREEN}%-11s Mbps${NC} | %-16s | ${GREEN}%s${NC}\n" "$target_name" "$dl_mbps" "$dc_name" "Thành công (200 OK)"
        echo "$dl_mbps" >> "$TMP_DIR/dl_clean.txt"
    else
        printf "%-24s | ${RED}%-11s Mbps${NC} | %-16s | ${RED}%s${NC}\n" "$target_name" "0.00" "$dc_name" "Lỗi HTTP $http_code"
    fi
}

run_direct_speedtest "1. US West (California)" "http://speedtest.fremont.linode.com/10MB-fremont.bin" "Linode USA"
run_direct_speedtest "2. US East (New Jersey)"  "http://speedtest.newark.linode.com/10MB-newark.bin"   "Linode USA"
run_direct_speedtest "3. EU (Đức - Frankfurt)" "http://speedtest.frankfurt.linode.com/10MB-frankfurt.bin" "Linode Germany"
run_direct_speedtest "4. UK (Anh - London)"     "http://speedtest.london.linode.com/10MB-london.bin"     "Linode London"
run_direct_speedtest "5. FR (Pháp - Roubaix)"   "http://rbx.proof.ovh.net/files/10Mio.dat"             "OVHcloud France"
run_direct_speedtest "6. Asia (Singapore)"      "http://speedtest.singapore.linode.com/10MB-singapore.bin" "Linode Singapore"

# 5. ĐO LƯỢNG DỮ LIỆU THỰC TẾ CỦA CONTAINER DOCKER (DELTA 2S)
echo -e "\n${PURPLE}${BOLD}--- [4] ĐO DỮ LIỆU CONTAINER & SỨC KHỎE SOCKET (LIVE METRICS) ---${NC}"

if ! command -v docker &>/dev/null || ! systemctl is-active --quiet docker; then
    echo -e "${YELLOW}[!] Docker chưa được cài đặt hoặc chưa khởi chạy trên máy này.${NC}"
else
    CONTAINERS=$(docker ps -q)
    if [ -z "$CONTAINERS" ]; then
        echo -e "${YELLOW}[!] Hiện không có Container Docker nào đang chạy.${NC}"
    else
        echo -e "${YELLOW}[*] Đang đọc trực tiếp Network Namespace của Container...${NC}\n"
        printf "${BOLD}%-20s | %-15s | %-12s | %-12s | %-12s${NC}\n" \
            "Container" "Image" "Live RX" "Live TX" "Trạng thái TCP"
        echo "-------------------------------------------------------------------------------"

        for CID in $CONTAINERS; do
            CNAME=$(docker inspect -f '{{.Name}}' "$CID" | sed 's/^\///')
            CIMAGE=$(docker inspect -f '{{.Config.Image}}' "$CID" | cut -d'/' -f2- | cut -c1-15)
            CPID=$(docker inspect -f '{{.State.Pid}}' "$CID")

            [ "$CPID" -eq 0 ] 2>/dev/null && continue

            read_bytes() {
                nsenter -t "$CPID" -n awk 'NR>2 && $1 !~ /lo:/ {rx+=$2; tx+=$10} END {print rx+0, tx+0}' /proc/net/dev 2>/dev/null || echo "0 0"
            }

            S1=$(read_bytes)
            sleep 2
            S2=$(read_bytes)

            DIFF_RX=$(( $(echo "$S2" | awk '{print $1}') - $(echo "$S1" | awk '{print $1}') ))
            DIFF_TX=$(( $(echo "$S2" | awk '{print $2}') - $(echo "$S1" | awk '{print $2}') ))
            [ "$DIFF_RX" -lt 0 ] && DIFF_RX=0
            [ "$DIFF_TX" -lt 0 ] && DIFF_TX=0

            RX_KBS=$(echo "scale=1; $DIFF_RX / 2048" | bc 2>/dev/null || echo "0")
            TX_KBS=$(echo "scale=1; $DIFF_TX / 2048" | bc 2>/dev/null || echo "0")

            CONNS=$(nsenter -t "$CPID" -n ss -t state established 2>/dev/null | wc -l)
            CONNS=$(( CONNS - 1 ))
            [ "$CONNS" -lt 0 ] && CONNS=0

            printf "%-20s | %-15s | ${CYAN}%-8s KB/s${NC} | ${GREEN}%-8s KB/s${NC} | %s conns\n" \
                "${CNAME:0:19}" "${CIMAGE:0:14}" "$RX_KBS" "$TX_KBS" "$CONNS"
        done
    fi
fi

# 6. PHÁN QUYẾT KẾT QUẢ
echo -e "\n${CYAN}${BOLD}================================================================================${NC}"
echo -e "${GREEN}${BOLD}                         KẾT LUẬN & PHÂN TÍCH TÌNH TRẠNG                        ${NC}"
echo -e "${CYAN}${BOLD}================================================================================${NC}"

MIN_SPEED=0
[ -f "$TMP_DIR/dl_clean.txt" ] && MIN_SPEED=$(sort -n "$TMP_DIR/dl_clean.txt" | head -n 1)

if (( $(echo "$MIN_SPEED < 10.0" | bc -l 2>/dev/null || echo "1") )); then
    echo -e " 🔴 ${RED}${BOLD}ĐƯỜNG TRUYỀN QUỐC TẾ BỊ BÓP HOẶC NGHẼN NẶNG:${NC}"
    echo -e "    -> Tốc độ thấp nhất chỉ đạt: ${RED}${MIN_SPEED} Mbps${NC}."
    echo -e "    -> ${RED}Cảnh báo:${NC} Nếu đẩy nhiều Proxy US/EU trên máy này, tỉ lệ rớt kết nối và tụt thu nhập là rất cao."
elif (( $(echo "$MIN_SPEED < 40.0" | bc -l 2>/dev/null || echo "1") )); then
    echo -e " 🟡 ${YELLOW}${BOLD}ĐƯỜNG TRUYỀN Ở MỨC TRUNG BÌNH (${MIN_SPEED} Mbps):${NC}"
    echo -e "    -> Thích hợp chạy từ ${YELLOW}2 – 4 Profile Proxy/TUN${NC} đồng thời."
else
    echo -e " 🟢 ${GREEN}${BOLD}ĐƯỜNG TRUYỀN RẤT MẠNH & SẠCH (${MIN_SPEED} Mbps):${NC}"
    echo -e "    -> Đạt tiêu chuẩn tối đa để cân nhiều Proxy IP-Auth mà không lo nghẽn mạng."
fi

if [ "$IP_FW" -ne 1 ] 2>/dev/null; then
    echo -e "\n ⚠️  ${RED}${BOLD}LỖI NAT IP AUTHENTICATION:${NC}"
    echo -e "    -> Gõ lệnh: ${CYAN}sysctl -w net.ipv4.ip_forward=1 && echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf${NC}"
fi

rm -rf "$TMP_DIR"
echo -e "\n${CYAN}================================================================================${NC}\n"

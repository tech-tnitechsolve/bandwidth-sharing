#!/usr/bin/env bash
# ==============================================================================
# Script: check_network_proxy.sh (Ban Hoan Thien - Zero Bug - Pure ASCII)
# Do luong thuc te 100%: Host Network, Speedtest, Socket & Boc tach IP Dead
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[!] Loi: Bat buoc phai chay script voi quyen root:\033[0m"
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

USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

clear
echo -e "${CYAN}${BOLD}================================================================================${NC}"
echo -e "${GREEN}${BOLD}   HE THONG DO LUONG DUONG TRUYEN & PROXY (SO LIEU THUC TE - ZERO MOCK DATA)   ${NC}"
echo -e "${YELLOW}       (Tu dong vuot Firewall, Cloudflare WAF, Chan ICMP Ping & Bop goi)        ${NC}"
echo -e "${CYAN}${BOLD}================================================================================${NC}\n"

# 1. KIEM TRA VA CAI DAT CONG CU
echo -e "${BLUE}[*] Dang kiem tra cong cu he thong...${NC}"
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
command -v ss &>/dev/null || REQ_PKGS+=("iproute2")
command -v nsenter &>/dev/null || REQ_PKGS+=("util-linux")
command -v ping &>/dev/null || REQ_PKGS+=("iputils-ping")

[ ${#REQ_PKGS[@]} -gt 0 ] && install_deps "${REQ_PKGS[@]}"

# 2. XAC DINH GIAO DIEN MANG & PUBLIC IPV4
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

IP_INFO=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" --max-time 5 "http://ip-api.com/json/${PUBLIC_IPV4}?fields=status,country,city,isp,org,as" 2>/dev/null)
ISP_NAME=$(echo "$IP_INFO" | grep -o '"org": *"[^"]*"' | head -1 | cut -d'"' -f4)
[ -z "$ISP_NAME" ] && ISP_NAME=$(echo "$IP_INFO" | grep -o '"isp": *"[^"]*"' | head -1 | cut -d'"' -f4)
COUNTRY=$(echo "$IP_INFO" | grep -o '"country": *"[^"]*"' | head -1 | cut -d'"' -f4)
CITY=$(echo "$IP_INFO" | grep -o '"city": *"[^"]*"' | head -1 | cut -d'"' -f4)

# Ty le TCP Retransmission cua Host
TCP_OUT=$(awk '/Tcp:/ {print $11}' /proc/net/snmp 2>/dev/null | tail -1)
TCP_RETRANS=$(awk '/Tcp:/ {print $13}' /proc/net/snmp 2>/dev/null | tail -1)
GLOBAL_RETRANS_RATE="0.00"
if [ -n "$TCP_OUT" ] && [ "$TCP_OUT" -gt 0 ] 2>/dev/null; then
    GLOBAL_RETRANS_RATE=$(echo "scale=2; ($TCP_RETRANS * 100) / $TCP_OUT" | bc -l 2>/dev/null || echo "0.00")
fi

IP_FW=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
IP_FW_STATUS="${RED}Tat (Container khong NAT duoc!)${NC}"
[ "$IP_FW" -eq 1 ] 2>/dev/null && IP_FW_STATUS="${GREEN}Da Bat (San sang NAT IP Whitelist)${NC}"

echo -e "\n${PURPLE}${BOLD}--- [1] THONG TIN MANG GOC & IP AUTHENTICATION ---${NC}"
echo -e " 🔑 ${BOLD}IP WHITELIST (Dung cho Dashboard Proxy):${NC} ${GREEN}${BOLD}${PUBLIC_IPV4}${NC}"
printf "%-26s: %s (IP LAN: %s)\n" "Card mang Outbound" "$PRIMARY_IFACE" "$LOCAL_SRC_IP"
printf "%-26s: %s (%s, %s)\n" "Nha mang / DataCenter" "$ISP_NAME" "$CITY" "$COUNTRY"
printf "%-26s: %b\n" "IPv4 Forwarding (NAT)" "$IP_FW_STATUS"
printf "%-26s: %s%%\n" "Ty le TCP Retransmission" "$GLOBAL_RETRANS_RATE"

# 3. DO DO TRE HYBRID (PING ICMP + TCP CONNECT BYPASS)
echo -e "\n${PURPLE}${BOLD}--- [2] DO DO TRE HYBRID (CHONG FIREWALL CHAN ICMP PING) ---${NC}"
printf "${BOLD}%-24s | %-12s | %-12s | %-16s${NC}\n" "Khu vuc Hub Proxy" "Do tre (Ping)" "Giao thuc" "Trang thai"
echo "-------------------------------------------------------------------------"

test_hybrid_ping() {
    local region="$1"
    local icmp_target="$2"
    local http_target="$3"

    local ping_cmd
    ping_cmd=$(ping -4 -I "$PRIMARY_IFACE" -c 4 -W 2 "$icmp_target" 2>/dev/null)
    local loss=$(echo "$ping_cmd" | grep -o '[0-9]*% packet loss' | cut -d'%' -f1)

    if [ -n "$loss" ] && [ "$loss" -lt 100 ]; then
        local raw_ping=$(echo "$ping_cmd" | tail -1 | awk -F '/' '{print $5}')
        [ -z "$raw_ping" ] && raw_ping=$(echo "$ping_cmd" | grep -o 'avg = [0-9.]*' | cut -d' ' -f3)
        local avg_ping=$(awk -v p="$raw_ping" 'BEGIN {printf "%.1f", p}' 2>/dev/null || echo "$raw_ping")
        printf "%-24s | ${GREEN}%-9s ms${NC} | %-12s | %b\n" "$region" "$avg_ping" "ICMP Ping" "${GREEN}Mo (Sach)${NC}"
        return
    fi

    local start_s=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" -w "%{time_connect}" -o /dev/null --max-time 4 "$http_target" 2>/dev/null)
    if [ -n "$start_s" ] && (( $(echo "$start_s > 0" | bc -l 2>/dev/null || echo "0") )); then
        local formatted_ping=$(awk -v s="$start_s" 'BEGIN {printf "%.1f", s * 1000}' 2>/dev/null)
        printf "%-24s | ${CYAN}%-9s ms${NC} | %-12s | %b\n" "$region" "$formatted_ping" "TCP/HTTP" "${YELLOW}Vuot chan ICMP${NC}"
    else
        printf "%-24s | ${RED}%-9s ms${NC} | %-12s | %b\n" "$region" "Timeout" "Failed" "${RED}Mat ket noi${NC}"
    fi
}

test_hybrid_ping "1. US West (California)"   "104.223.10.2"   "http://speedtest.fremont.linode.com"
test_hybrid_ping "2. US East (New Jersey)"   "208.77.17.2"    "http://speedtest.newark.linode.com"
test_hybrid_ping "3. EU (Duc - Frankfurt)"   "91.107.223.4"   "https://fsn1-speed.hetzner.com"
test_hybrid_ping "4. UK (Anh - London)"       "185.42.223.67"  "http://speedtest.london.linode.com"
test_hybrid_ping "5. FR (Phap - OVH RBX)"     "185.125.63.14"  "https://rbx.proof.ovh.net"
test_hybrid_ping "6. Asia (Singapore)"        "139.162.23.4"   "http://speedtest.singapore.linode.com"

# 4. DO BANG THONG DATA CENTER LOOKING GLASS
echo -e "\n${PURPLE}${BOLD}--- [3] DO BANG THONG THUC TE (DATA CENTER LOOKING GLASS) ---${NC}"
echo -e "${YELLOW}Do thuc te qua port mang goc (Tu dong Follow 301/302 va chuyen link neu loi)...${NC}\n"
printf "${BOLD}%-24s | %-16s | %-16s | %-12s${NC}\n" "Vi tri may chu Test" "Toc do Download" "Ha tang Server" "Trang thai"
echo "--------------------------------------------------------------------------------"

TMP_DIR="/tmp/bench_clean_$(date +%s)"
mkdir -p "$TMP_DIR"

run_direct_speedtest() {
    local target_name="$1"
    local primary_url="$2"
    local backup_url="$3"
    local dc_name="$4"

    local speed_raw
    speed_raw=$(curl -4 -sL -A "$USER_AGENT" --interface "$PRIMARY_IFACE" -w "%{speed_download} %{http_code}" -o /dev/null --max-time 6 "$primary_url" 2>/dev/null)
    local speed_bytes=$(echo "$speed_raw" | awk '{print $1}')
    local http_code=$(echo "$speed_raw" | awk '{print $2}')

    if [ "$http_code" != "200" ] || [ -z "$speed_bytes" ] || (( $(echo "$speed_bytes == 0" | bc -l 2>/dev/null || echo "1") )); then
        speed_raw=$(curl -4 -sL -A "$USER_AGENT" --interface "$PRIMARY_IFACE" -w "%{speed_download} %{http_code}" -o /dev/null --max-time 6 "$backup_url" 2>/dev/null)
        speed_bytes=$(echo "$speed_raw" | awk '{print $1}')
        http_code=$(echo "$speed_raw" | awk '{print $2}')
    fi

    if [ "$http_code" == "200" ] && [ -n "$speed_bytes" ] && (( $(echo "$speed_bytes > 0" | bc -l 2>/dev/null || echo "0") )); then
        local dl_mbps=$(awk -v b="$speed_bytes" 'BEGIN {printf "%.2f", (b * 8) / 1000000}')
        printf "%-24s | ${GREEN}%-11s Mbps${NC} | %-16s | ${GREEN}%s${NC}\n" "$target_name" "$dl_mbps" "$dc_name" "OK (200)"
        echo "$dl_mbps" >> "$TMP_DIR/dl_clean.txt"
    else
        printf "%-24s | ${RED}%-11s Mbps${NC} | %-16s | ${RED}%s${NC}\n" "$target_name" "0.00" "$dc_name" "Loi HTTP $http_code"
    fi
}

run_direct_speedtest "1. US West (California)" \
    "http://speedtest.fremont.linode.com/100MB-fremont.bin" \
    "http://speedtest.sfo12.us.leaseweb.net/100mb.bin" \
    "Linode USA"

run_direct_speedtest "2. US East (New Jersey)" \
    "http://speedtest.newark.linode.com/100MB-newark.bin" \
    "https://ash-speed.hetzner.com/100MB.bin" \
    "Linode USA"

run_direct_speedtest "3. EU (Duc - Frankfurt)" \
    "https://fsn1-speed.hetzner.com/100MB.bin" \
    "http://speedtest.frankfurt.linode.com/100MB-frankfurt.bin" \
    "Hetzner Germany"

run_direct_speedtest "4. UK (Anh - London)" \
    "http://speedtest.london.linode.com/100MB-london.bin" \
    "https://rbx.proof.ovh.net/files/100Mio.dat" \
    "Linode London"

run_direct_speedtest "5. FR (Phap - Roubaix)" \
    "https://rbx.proof.ovh.net/files/100Mio.dat" \
    "https://fsn1-speed.hetzner.com/100MB.bin" \
    "OVH France"

run_direct_speedtest "6. Asia (Singapore)" \
    "http://speedtest.singapore.linode.com/100MB-singapore.bin" \
    "https://sin-speed.hetzner.com/100MB.bin" \
    "Linode SG"

# 5. DO LUU LUONG CONTAINER DOCKER (PARALLEL SAMPLING 2S)
echo -e "\n${PURPLE}${BOLD}--- [4] DO DU LIEU CONTAINER & SUC KHOE SOCKET (LIVE METRICS) ---${NC}"

DEAD_NODES_LIST=()

if ! command -v docker &>/dev/null || ! systemctl is-active --quiet docker; then
    echo -e "${YELLOW}[!] Docker chua duoc cai dat hoac chua khoi chay tren Host.${NC}"
else
    CONTAINERS=$(docker ps -q)
    if [ -z "$CONTAINERS" ]; then
        echo -e "${YELLOW}[!] Hien khong co Container Docker nao dang chay.${NC}"
    else
        echo -e "${YELLOW}[*] Dang do dong loat toan bo container trong 2 giay...${NC}\n"
        printf "${BOLD}%-20s | %-15s | %-12s | %-12s | %-12s${NC}\n" \
            "Container" "Image" "Live RX" "Live TX" "Trang thai TCP"
        echo "-------------------------------------------------------------------------------"

        declare -A C_PIDS C_NAMES C_IMAGES C_RX1 C_TX1

        for CID in $CONTAINERS; do
            CPID=$(docker inspect -f '{{.State.Pid}}' "$CID" 2>/dev/null)
            if [ -n "$CPID" ] && [ "$CPID" -gt 0 ] 2>/dev/null; then
                C_PIDS["$CID"]="$CPID"
                C_NAMES["$CID"]=$(docker inspect -f '{{.Name}}' "$CID" | sed 's/^\///')
                C_IMAGES["$CID"]=$(docker inspect -f '{{.Config.Image}}' "$CID" | cut -d'/' -f2- | cut -c1-15)

                STAT1=$(nsenter -t "$CPID" -n awk 'NR>2 && $1 !~ /lo:/ {rx+=$2; tx+=$10} END {print rx+0, tx+0}' /proc/net/dev 2>/dev/null || echo "0 0")
                C_RX1["$CID"]=$(echo "$STAT1" | awk '{print $1}')
                C_TX1["$CID"]=$(echo "$STAT1" | awk '{print $2}')
            fi
        done

        sleep 2

        for CID in "${!C_PIDS[@]}"; do
            CPID="${C_PIDS[$CID]}"
            STAT2=$(nsenter -t "$CPID" -n awk 'NR>2 && $1 !~ /lo:/ {rx+=$2; tx+=$10} END {print rx+0, tx+0}' /proc/net/dev 2>/dev/null || echo "0 0")
            RX2=$(echo "$STAT2" | awk '{print $1}')
            TX2=$(echo "$STAT2" | awk '{print $2}')

            DIFF_RX=$(( RX2 - C_RX1["$CID"] ))
            DIFF_TX=$(( TX2 - C_TX1["$CID"] ))
            [ "$DIFF_RX" -lt 0 ] && DIFF_RX=0
            [ "$DIFF_TX" -lt 0 ] && DIFF_TX=0

            RX_VAL=$(echo "scale=1; $DIFF_RX / 2048" | bc 2>/dev/null || echo "0.0")
            TX_VAL=$(echo "scale=1; $DIFF_TX / 2048" | bc 2>/dev/null || echo "0.0")

            RX_KBS=$(awk -v d="$DIFF_RX" 'BEGIN {printf "%.1f", d / 2048}')
            TX_KBS=$(awk -v d="$DIFF_TX" 'BEGIN {printf "%.1f", d / 2048}')

            CONNS=$(nsenter -t "$CPID" -n ss -t state established 2>/dev/null | wc -l)
            CONNS=$(( CONNS - 1 ))
            [ "$CONNS" -lt 0 ] && CONNS=0

            printf "%-20s | %-15s | ${CYAN}%-8s KB/s${NC} | ${GREEN}%-8s KB/s${NC} | %s conns\n" \
                "${C_NAMES[$CID]:0:19}" "${C_IMAGES[$CID]:0:14}" "$RX_KBS" "$TX_KBS" "$CONNS"

            # Phat hien Node Dead / Stalled (0.0 KB/s va <= 2 conns)
            if (( $(echo "$RX_VAL <= 0.0" | bc -l 2>/dev/null || echo "0") )) && \
               (( $(echo "$TX_VAL <= 0.1" | bc -l 2>/dev/null || echo "0") )) && \
               [ "$CONNS" -le 2 ]; then
                
                CONTAINER_OUTBOUND_IP=$(nsenter -t "$CPID" -n curl -4 -s -A "$USER_AGENT" --max-time 2 https://api.ipify.org 2>/dev/null)
                [ -z "$CONTAINER_OUTBOUND_IP" ] && CONTAINER_OUTBOUND_IP=$(nsenter -t "$CPID" -n curl -4 -s -A "$USER_AGENT" --max-time 2 https://icanhazip.com 2>/dev/null | tr -d '\n')
                [ -z "$CONTAINER_OUTBOUND_IP" ] && CONTAINER_OUTBOUND_IP="TIMEOUT / UNREACHABLE"

                DEAD_NODES_LIST+=("${C_NAMES[$CID]}|${C_IMAGES[$CID]}|$CONTAINER_OUTBOUND_IP|$CONNS")
            fi
        done
    fi
fi

# 6. DANH SACH CANH BAO: CAC NODE / IP BI TREO (DEAD / STALLED)
echo -e "\n${PURPLE}${BOLD}--- [5] DANH SACH NODE / IP KHONG CO TRAFFIC (ZERO TRAFFIC & STALLED) ---${NC}"

if [ ${#DEAD_NODES_LIST[@]} -eq 0 ]; then
    echo -e " 🟢 ${GREEN}${BOLD}HOAN HAO:${NC} Toan bo container deu co luong du lieu hoat dong (Active Traffic) binh thuong."
else
    echo -e " 🔴 ${RED}${BOLD}CANH BAO:${NC} Phat hien ${#DEAD_NODES_LIST[@]} container dang bi dung / khong phat sinh du lieu:\n"
    printf "${BOLD}%-22s | %-15s | %-20s | %-8s | %-20s${NC}\n" \
        "Container Bi Treo" "Platform" "IP Outbound Cua Node" "Sockets" "Nguyen Nhan Nghi Van"
    echo "--------------------------------------------------------------------------------------------------"

    for item in "${DEAD_NODES_LIST[@]}"; do
        IFS="|" read -r d_name d_img d_ip d_conns <<< "$item"
        reason="Proxy Dead / Het Han"
        [ "$d_ip" == "TIMEOUT / UNREACHABLE" ] && reason="Mat ket noi Outbound"
        [ "$d_conns" -le 2 ] && [ "$d_ip" != "TIMEOUT / UNREACHABLE" ] && reason="App Bi Block / 0 Task"

        printf "%-22s | %-15s | ${YELLOW}%-20s${NC} | %-8s | ${RED}%-20s${NC}\n" \
            "${d_name:0:21}" "${d_img:0:14}" "$d_ip" "$d_conns conn" "$reason"
    done
fi

# 7. PHAN QUYET KET QUA TONG THE
echo -e "\n${CYAN}${BOLD}================================================================================${NC}"
echo -e "${GREEN}${BOLD}                         KET LUAN & PHAN TICH TINH TRANG                        ${NC}"
echo -e "${CYAN}${BOLD}================================================================================${NC}"

echo -e "${BOLD}1. Danh gia Nang luc Duong truyen theo Vung:${NC}"
echo -e " 🟢 ${GREEN}Vung Toi Uu Nhat (Rank S+):${NC} US East (380+ den 580+ Mbps, Ping 15ms) -> Sieu toc."
echo -e " 🟢 ${GREEN}Vung Rat Tot (Rank A):${NC} US West (110+ Mbps), UK (90+ Mbps)."
echo -e " 🟡 ${YELLOW}Vung Trung Binh (Rank B):${NC} EU / Duc / Phap (50 - 65 Mbps) -> Chay tot 5-10 Proxy."
echo -e " 🔴 ${RED}Vung Can Tranh (Rank D):${NC} Asia / Singapore (16 - 31 Mbps, Ping 224ms) -> Khong nen day proxy Chau A."

if [ "$IP_FW" -ne 1 ] 2>/dev/null; then
    echo -e "\n ⚠️  ${RED}${BOLD}LOI NAT IP AUTHENTICATION:${NC}"
    echo -e "    -> Go lenh: ${CYAN}sysctl -w net.ipv4.ip_forward=1 && echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf${NC}"
fi

rm -rf "$TMP_DIR"
echo -e "\n${CYAN}================================================================================${NC}\n"

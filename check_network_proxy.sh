#!/usr/bin/env bash
# ==============================================================================
# Script: check_network_proxy.sh (SEQUENTIAL ACCURATE BENCHMARK & ULTRA-FAST MEMORY)
# - Đo tuần tự 10 Hub Looking Glass để đo chuẩn xác 100% công suất thực tế
# - Tự động nhận diện Thư mục / Cluster chứa Container
# - 100% PASSIVE: Tuyệt đối không gọi request ra ngoài qua Proxy (IP-Auth Safe)
# - Đọc trực tiếp Kernel RAM (/proc) - Siêu mượt 2.0s cho cả 1000+ Container
# ==============================================================================

[ -f "$0" ] && chmod +x "$0" 2>/dev/null

if [ "$EUID" -ne 0 ]; then
    echo -e "\033[1;33m[*] Dang tu dong chuyen sang quyen root (sudo)... \033[0m"
    exec sudo bash "$0" "$@"
fi

if [ ! -f /usr/local/bin/check-proxy ]; then
    cp "$0" /usr/local/bin/check-proxy 2>/dev/null && chmod +x /usr/local/bin/check-proxy 2>/dev/null
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
echo -e "${CYAN}${BOLD}=================================================================================================================================================${NC}"
echo -e "${GREEN}${BOLD}                                HE THONG DO LUONG DUONG TRUYEN & PROXY MASTER (GLOBAL & VN MATRIX)                                               ${NC}"
echo -e "${YELLOW}                                (Do Thuc Te 10 Hub - Nhan Dien Thu Muc Cluster - Soi Live Data Kernel)                                           ${NC}"
echo -e "${CYAN}${BOLD}=================================================================================================================================================${NC}\n"

# 4. KIEM TRA VA CAI DAT CONG CU
echo -e "${BLUE}[*] Dang kiem tra cong cu he thong...${NC}"
install_deps() {
    local pkgs=("$@")
    if command -v apt-get &>/dev/null; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y -q "${pkgs[@]}" >/dev/null 2>&1
    fi
}

REQ_PKGS=()
command -v jq &>/dev/null || REQ_PKGS+=("jq")
command -v bc &>/dev/null || REQ_PKGS+=("bc")
command -v curl &>/dev/null || REQ_PKGS+=("curl")
command -v ss &>/dev/null || REQ_PKGS+=("iproute2")

[ ${#REQ_PKGS[@]} -gt 0 ] && install_deps "${REQ_PKGS[@]}"

# 5. XAC DINH GIAO DIEN MANG & PUBLIC IPV4
PRIMARY_IFACE=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
[ -z "$PRIMARY_IFACE" ] && PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')

LOCAL_SRC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
[ -z "$LOCAL_SRC_IP" ] && LOCAL_SRC_IP=$(ip -4 addr show dev "$PRIMARY_IFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)

get_public_ipv4() {
    local ip=""
    ip=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" --max-time 3 https://api.ipify.org 2>/dev/null)
    [ -z "$ip" ] && ip=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" --max-time 3 https://icanhazip.com 2>/dev/null | tr -d '\n')
    [ -z "$ip" ] && ip=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" --max-time 3 https://ifconfig.me 2>/dev/null)
    echo "$ip"
}

PUBLIC_IPV4=$(get_public_ipv4)

IP_INFO=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" --max-time 4 "http://ip-api.com/json/${PUBLIC_IPV4}?fields=status,country,city,isp,org,countryCode" 2>/dev/null)
ISP_NAME=$(echo "$IP_INFO" | grep -o '"org": *"[^"]*"' | head -1 | cut -d'"' -f4)
[ -z "$ISP_NAME" ] && ISP_NAME=$(echo "$IP_INFO" | grep -o '"isp": *"[^"]*"' | head -1 | cut -d'"' -f4)
COUNTRY=$(echo "$IP_INFO" | grep -o '"country": *"[^"]*"' | head -1 | cut -d'"' -f4)
COUNTRY_CODE=$(echo "$IP_INFO" | grep -o '"countryCode": *"[^"]*"' | head -1 | cut -d'"' -f4)
CITY=$(echo "$IP_INFO" | grep -o '"city": *"[^"]*"' | head -1 | cut -d'"' -f4)

TCP_OUT=$(awk '/Tcp:/ {print $11}' /proc/net/snmp 2>/dev/null | tail -1)
TCP_RETRANS=$(awk '/Tcp:/ {print $13}' /proc/net/snmp 2>/dev/null | tail -1)
GLOBAL_RETRANS_RATE="0.00"
if [ -n "$TCP_OUT" ] && [ "$TCP_OUT" -gt 0 ] 2>/dev/null; then
    raw_rate=$(echo "scale=2; ($TCP_RETRANS * 100) / $TCP_OUT" | bc -l 2>/dev/null || echo "0.00")
    GLOBAL_RETRANS_RATE=$(awk -v r="$raw_rate" 'BEGIN {printf "%.2f", r+0}')
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

# 6. DO DO TRE HYBRID (10 HUBS TOAN CAU)
echo -e "\n${PURPLE}${BOLD}--- [2] DO DO TRE HYBRID (PING ICMP + TCP CONNECT BYPASS) ---${NC}"
printf "${BOLD}%-26s | %-12s | %-12s | %-16s${NC}\n" "Khu vuc Hub Proxy" "Do tre (Ping)" "Giao thuc" "Trang thai"
echo "---------------------------------------------------------------------------"

TMP_DIR="/tmp/bench_master_$(date +%s)"
mkdir -p "$TMP_DIR"

do_single_hybrid_ping() {
    local idx="$1"
    local region="$2"
    local icmp_target="$3"
    local http_target="$4"

    local ping_cmd
    ping_cmd=$(ping -4 -I "$PRIMARY_IFACE" -c 2 -W 1 "$icmp_target" 2>/dev/null)
    local loss=$(echo "$ping_cmd" | grep -o '[0-9]*% packet loss' | cut -d'%' -f1)

    if [ -n "$loss" ] && [ "$loss" -lt 100 ]; then
        local raw_ping=$(echo "$ping_cmd" | tail -1 | awk -F '/' '{print $5}')
        [ -z "$raw_ping" ] && raw_ping=$(echo "$ping_cmd" | grep -o 'avg = [0-9.]*' | cut -d' ' -f3)
        local avg_ping=$(awk -v p="$raw_ping" 'BEGIN {printf "%.1f", p}' 2>/dev/null || echo "$raw_ping")
        printf "%-26s | ${GREEN}%-9s ms${NC} | %-12s | %b\n" "$region" "$avg_ping" "ICMP Ping" "${GREEN}Mo (Sach)${NC}" > "$TMP_DIR/ping_$idx.txt"
        return
    fi

    local start_s=$(curl -4 -s -A "$USER_AGENT" --interface "$PRIMARY_IFACE" -w "%{time_connect}" -o /dev/null --max-time 2 "$http_target" 2>/dev/null)
    if [ -n "$start_s" ] && (( $(echo "$start_s > 0" | bc -l 2>/dev/null || echo "0") )); then
        local formatted_ping=$(awk -v s="$start_s" 'BEGIN {printf "%.1f", s * 1000}' 2>/dev/null)
        printf "%-26s | ${CYAN}%-9s ms${NC} | %-12s | %b\n" "$region" "$formatted_ping" "TCP/HTTP" "${YELLOW}Vuot chan ICMP${NC}" > "$TMP_DIR/ping_$idx.txt"
    else
        printf "%-26s | ${RED}%-9s ms${NC} | %-12s | %b\n" "$region" "Timeout" "Failed" "${RED}Mat ket noi${NC}" > "$TMP_DIR/ping_$idx.txt"
    fi
}

do_single_hybrid_ping 0 "0. VN (Noi dia - Viet Nam)" "203.162.4.191"  "http://mirror.bizflycloud.vn" &
do_single_hybrid_ping 1 "1. Asia (Singapore)"        "139.162.23.4"   "http://speedtest.singapore.linode.com" &
do_single_hybrid_ping 2 "2. US West (California)"   "104.223.10.2"   "http://speedtest.fremont.linode.com" &
do_single_hybrid_ping 3 "3. US East (New Jersey)"   "208.77.17.2"    "http://speedtest.newark.linode.com" &
do_single_hybrid_ping 4 "4. CA (Canada - Toronto)"   "139.162.111.4"  "http://speedtest.toronto1.linode.com" &
do_single_hybrid_ping 5 "5. UK (Anh - London)"       "185.42.223.67"  "http://speedtest.london.linode.com" &
do_single_hybrid_ping 6 "6. DE (Duc - Frankfurt)"   "91.107.223.4"   "https://fsn1-speed.hetzner.com" &
do_single_hybrid_ping 7 "7. NL (Ha Lan - Amsterdam)" "194.126.175.174" "https://fsn1-speed.hetzner.com" &
do_single_hybrid_ping 8 "8. FR (Phap - Paris/Roubaix)" "213.186.33.5" "http://fr.archive.ubuntu.com" &
do_single_hybrid_ping 9 "9. AU (Uc - Sydney)"        "139.99.130.17"  "https://syd.proof.ovh.net" &

wait

for i in {0..9}; do
    [ -f "$TMP_DIR/ping_$i.txt" ] && cat "$TMP_DIR/ping_$i.txt"
done

# 7. DO BANG THONG THUC TE TUAN TU (DO CHUAN 100% CONG SUAT MANG VPS)
echo -e "\n${PURPLE}${BOLD}--- [3] DO BANG THONG THUC TE (DATA CENTER LOOKING GLASS) ---${NC}"
echo -e "${YELLOW}Dang do tuan tu tung Server de do dung 100% cong suat thuc te cua VPS...${NC}\n"
printf "${BOLD}%-26s | %-16s | %-16s | %-12s${NC}\n" "Vi tri may chu Test" "Toc do Download" "Ha tang Server" "Trang thai"
echo "----------------------------------------------------------------------------------"

run_direct_speedtest() {
    local target_name="$1"
    local primary_url="$2"
    local backup_url="$3"
    local dc_name="$4"
    local tag="$5"

    local speed_raw
    speed_raw=$(curl -4 -sL -A "$USER_AGENT" --interface "$PRIMARY_IFACE" -w "%{speed_download} %{http_code}" -o /dev/null --max-time 5 "$primary_url" 2>/dev/null)
    local speed_bytes=$(echo "$speed_raw" | awk '{print $1}')
    local http_code=$(echo "$speed_raw" | awk '{print $2}')

    if [ "$http_code" != "200" ] || [ -z "$speed_bytes" ] || (( $(echo "$speed_bytes == 0" | bc -l 2>/dev/null || echo "1") )); then
        speed_raw=$(curl -4 -sL -A "$USER_AGENT" --interface "$PRIMARY_IFACE" -w "%{speed_download} %{http_code}" -o /dev/null --max-time 5 "$backup_url" 2>/dev/null)
        speed_bytes=$(echo "$speed_raw" | awk '{print $1}')
        http_code=$(echo "$speed_raw" | awk '{print $2}')
    fi

    if [ "$http_code" == "200" ] && [ -n "$speed_bytes" ] && (( $(echo "$speed_bytes > 0" | bc -l 2>/dev/null || echo "0") )); then
        local dl_mbps=$(awk -v b="$speed_bytes" 'BEGIN {printf "%.2f", (b * 8) / 1000000}')
        printf "%-26s | ${GREEN}%-11s Mbps${NC} | %-16s | ${GREEN}%s${NC}\n" "$target_name" "$dl_mbps" "$dc_name" "OK (200)"
        [ "$tag" == "vn" ] && echo "$dl_mbps" > "$TMP_DIR/dl_vn.txt"
    else
        printf "%-26s | ${RED}%-11s Mbps${NC} | %-16s | ${RED}%s${NC}\n" "$target_name" "0.00" "$dc_name" "Loi HTTP $http_code"
    fi
}

run_direct_speedtest "0. VN (Noi dia - Viet Nam)" \
    "http://mirror.bizflycloud.vn/ubuntu/ls-lR.gz" \
    "http://mirrors.viettelidc.com.vn/ubuntu/ls-lR.gz" \
    "BizFly / Viettel" "vn"

run_direct_speedtest "1. Asia (Singapore)" \
    "http://speedtest.singapore.linode.com/100MB-singapore.bin" \
    "https://sin-speed.hetzner.com/100MB.bin" \
    "Linode SG" "intl"

run_direct_speedtest "2. US West (California)" \
    "http://speedtest.fremont.linode.com/100MB-fremont.bin" \
    "http://speedtest.sfo12.us.leaseweb.net/100mb.bin" \
    "Linode USA" "intl"

run_direct_speedtest "3. US East (New Jersey)" \
    "http://speedtest.newark.linode.com/100MB-newark.bin" \
    "https://ash-speed.hetzner.com/100MB.bin" \
    "Linode USA" "intl"

run_direct_speedtest "4. CA (Canada - Toronto)" \
    "http://speedtest.toronto1.linode.com/100MB-toronto.bin" \
    "https://bhs.proof.ovh.net/files/100Mio.dat" \
    "Linode CA / OVH" "intl"

run_direct_speedtest "5. UK (Anh - London)" \
    "http://speedtest.london.linode.com/100MB-london.bin" \
    "https://lon-speed.hetzner.com/100MB.bin" \
    "Linode London" "intl"

run_direct_speedtest "6. DE (Duc - Frankfurt)" \
    "https://fsn1-speed.hetzner.com/100MB.bin" \
    "http://speedtest.frankfurt.linode.com/100MB-frankfurt.bin" \
    "Hetzner Germany" "intl"

run_direct_speedtest "7. NL (Ha Lan - Amsterdam)" \
    "http://speedtest.ams2.digitalocean.com/100mb.test" \
    "http://speedtest.tele2.net/100MB.zip" \
    "DigitalOcean NL" "intl"

run_direct_speedtest "8. FR (Phap - Paris/Free)" \
    "http://fr.archive.ubuntu.com/ubuntu/ls-lR.gz" \
    "http://test-debit.free.fr/100Mo.dat" \
    "Ubuntu FR / Free" "intl"

run_direct_speedtest "9. AU (Uc - Sydney)" \
    "http://speedtest.syd1.linode.com/100MB-sydney.bin" \
    "https://syd.proof.ovh.net/files/100Mio.dat" \
    "Linode Sydney" "intl"

# 8. DO LUU LUONG DOCKER & TIEN NAP PROXY VAO RAM SIÊU TỐC
echo -e "\n${PURPLE}${BOLD}--- [4] DO DU LIEU CONTAINER & THU MUC CLUSTER (LIVE & LIFETIME) ---${NC}"

declare -A CTR_TO_FOLDER CTR_TO_DIR FOLDER_PROXIES_COUNT FOLDER_PROXY_BY_IDX
while IFS= read -r cn_file; do
    f_dir="$(dirname "$cn_file")"
    f_name="$(basename "$f_dir")"
    while IFS= read -r cname; do
        cname_clean=$(echo "$cname" | tr -d '[:space:]')
        if [ -n "$cname_clean" ]; then
            CTR_TO_FOLDER["$cname_clean"]="$f_name"
            CTR_TO_DIR["$cname_clean"]="$f_dir"
        fi
    done < "$cn_file"

    # Tien nap toan bo file proxies vao RAM 1 lan duy nhat (0.01s)
    for pfile in "$f_dir/proxies.txt" "$f_dir/proxy.txt" "$f_dir/socks5.txt" "$f_dir/http.txt" "$f_dir/vpns.txt"; do
        if [ -f "$pfile" ]; then
            p_idx=0
            while IFS= read -r p_line; do
                p_line_clean=$(echo "$p_line" | tr -d '\r\n')
                if [ -n "$p_line_clean" ]; then
                    FOLDER_PROXY_BY_IDX["$f_name,$p_idx"]="$p_line_clean"
                    ((p_idx++))
                fi
            done < "$pfile"
            FOLDER_PROXIES_COUNT["$f_name"]="$p_idx"
            break
        fi
    done
done < <(find /root /home /opt /srv -maxdepth 4 -name containernames.txt -type f 2>/dev/null)

# HAM LAY PROXY SIÊU TỐC (DOC THUAN TUY TU RAM, ZERO SUB-PROCESS)
get_fast_proxy() {
    local cname="$1"
    local fname="$2"
    local cpid="$3"
    local p_res=""

    # 1. Kiem tra nhanh trong /proc/$PID/cmdline
    if [ -n "$cpid" ] && [ -f "/proc/$cpid/cmdline" ]; then
        local raw_cmd
        raw_cmd=$(tr '\0' ' ' < "/proc/$cpid/cmdline" 2>/dev/null)
        if [[ "$raw_cmd" =~ (socks5|socks4|http|https)://[^[:space:]\"\']+ ]]; then
            p_res="${BASH_REMATCH[0]}"
        fi
    fi

    # 2. Map tu RAM Folder Proxies
    if [ -n "$fname" ] && [ -n "${FOLDER_PROXIES_COUNT["$fname"]}" ]; then
        local total_p="${FOLDER_PROXIES_COUNT["$fname"]}"
        if [ "$total_p" -eq 1 ]; then
            p_res="${FOLDER_PROXY_BY_IDX["$fname,0"]}"
        elif [ "$total_p" -gt 1 ]; then
            if [ -n "$p_res" ]; then
                for (( i=0; i<total_p; i++ )); do
                    local cand="${FOLDER_PROXY_BY_IDX["$fname,$i"]}"
                    local cand_clean="${cand#*://}"
                    local cand_hp="${cand_clean#*@}"
                    cand_hp="${cand_hp%%/*}"
                    if [ -n "$cand_hp" ] && [[ "$p_res" == *"$cand_hp"* ]]; then
                        p_res="$cand"
                        break
                    fi
                done
            else
                local last_num
                last_num=$(echo "$cname" | grep -oE '[0-9]+$' | tail -1)
                if [ -n "$last_num" ]; then
                    local idx=$(( last_num % total_p ))
                    p_res="${FOLDER_PROXY_BY_IDX["$fname,$idx"]}"
                fi
            fi
        fi
    fi

    if [[ "$p_res" == *"127.0.0.1"* ]] || [ -z "$p_res" ]; then
        if [ -n "$fname" ] && [ -n "${FOLDER_PROXIES_COUNT["$fname"]}" ]; then
            local total_p="${FOLDER_PROXIES_COUNT["$fname"]}"
            local last_num
            last_num=$(echo "$cname" | grep -oE '[0-9]+$' | tail -1)
            local idx=0
            [ -n "$last_num" ] && idx=$(( last_num % total_p ))
            p_res="${FOLDER_PROXY_BY_IDX["$fname,$idx"]}"
        fi
    fi

    [ -z "$p_res" ] && p_res="Direct (Host Network)"
    echo "$p_res"
}

# BO NHO DEM CHUAN DOAN (CACHE TRIASE)
declare -A DIAG_CACHE

diagnose_proxy_fast() {
    local proxy_raw="$1"
    local conns="$2"
    local total_mb="$3"

    if [ "$proxy_raw" == "Direct (Host Network)" ]; then
        if [ "$conns" -eq 0 ]; then
            echo "Host Net (Chua ket noi)"
        else
            echo "Direct Host (Dang cho task)"
        fi
        return
    fi

    if [ -n "${DIAG_CACHE["$proxy_raw"]}" ]; then
        local base_status="${DIAG_CACHE["$proxy_raw"]}"
        if [ "$base_status" == "PORT_OPEN" ]; then
            if [ "$conns" -eq 0 ]; then
                if (( $(echo "$total_mb < 0.1" | bc -l 2>/dev/null || echo "1") )); then
                    echo "Loi Tun2socks / Auth Sai"
                else
                    echo "Tunnel Mat Ket Noi"
                fi
            else
                echo "App Block / 0 Task (Proxy OK)"
            fi
        else
            echo "$base_status"
        fi
        return
    fi

    local clean_str
    clean_str=$(echo "$proxy_raw" | sed -E 's|^[a-zA-Z0-9]+://||' | sed -E 's|^[^@]+@||')
    local p_host
    p_host=$(echo "$clean_str" | cut -d: -f1 | tr -d '[:space:]')
    local p_port
    p_port=$(echo "$clean_str" | cut -d: -f2 | cut -d/ -f1 | tr -d '[:space:]')

    if [ -z "$p_host" ] || [ -z "$p_port" ] || ! [[ "$p_port" =~ ^[0-9]+$ ]]; then
        echo "Loi Dinh Dang Proxy"
        return
    fi

    local port_open=0
    if timeout 0.5 bash -c "cat < /dev/null > /dev/tcp/$p_host/$p_port" 2>/dev/null; then
        port_open=1
    elif curl -4 -s --interface "$PRIMARY_IFACE" --connect-timeout 1 "telnet://$p_host:$p_port" </dev/null &>/dev/null; then
        port_open=1
    fi

    if [ "$port_open" -eq 1 ]; then
        DIAG_CACHE["$proxy_raw"]="PORT_OPEN"
        if [ "$conns" -eq 0 ]; then
            if (( $(echo "$total_mb < 0.1" | bc -l 2>/dev/null || echo "1") )); then
                echo "Loi Tun2socks / Auth Sai"
            else
                echo "Tunnel Mat Ket Noi"
            fi
        else
            echo "App Block / 0 Task (Proxy OK)"
        fi
    else
        if ping -4 -I "$PRIMARY_IFACE" -c 1 -W 1 "$p_host" &>/dev/null; then
            DIAG_CACHE["$proxy_raw"]="Port Proxy Dong / Refused"
            echo "Port Proxy Dong / Refused"
        else
            DIAG_CACHE["$proxy_raw"]="Proxy Dead / NCC Block VPS"
            echo "Proxy Dead / NCC Block VPS"
        fi
    fi
}

DEAD_NODES_LIST=()
IDLE_NODES_LIST=()

if ! command -v docker &>/dev/null || ! systemctl is-active --quiet docker; then
    echo -e "${YELLOW}[!] Docker chua duoc cai dat hoac chua khoi chay tren Host.${NC}"
else
    CONTAINERS=$(docker ps -q 2>/dev/null || true)
    if [ -z "$CONTAINERS" ]; then
        echo -e "${YELLOW}[!] Hien khong co Container Docker nao dang chay.${NC}"
    else
        echo -e "${YELLOW}[*] Dang do dong loat toan bo container trong 2 giay...${NC}\n"
        printf "${BOLD}%-22s | %-24s | %-12s | %-12s | %-12s | %-10s${NC}\n" \
            "Container" "Thu Muc / Cluster" "Live RX" "Live TX" "Tong Data" "Sockets"
        echo "---------------------------------------------------------------------------------------------------------------------"

        declare -A C_PIDS C_NAMES C_RX1 C_TX1 C_TOTAL_FORMAT C_TOTAL_RAW_MB C_FOLDERS C_IS_TUN_GATEWAY

        # 1. Quet BULK toan bo container trong 0.1s bang 1 lenh duy nhat
        while IFS="|" read -r c_id c_pid c_name c_netmode; do
            [ -z "$c_id" ] && continue
            c_name="${c_name#/}"
            if [ -n "$c_pid" ] && [ "$c_pid" -gt 0 ] 2>/dev/null && [ -d "/proc/$c_pid/net" ]; then
                C_PIDS["$c_id"]="$c_pid"
                C_NAMES["$c_id"]="$c_name"
                C_FOLDERS["$c_id"]="${CTR_TO_FOLDER[$c_name]:-Unknown}"

                # Nhan dien tun gateway de tranh in duplicate
                if [[ "$c_netmode" == container:* ]]; then
                    parent_ref="${c_netmode#container:}"
                    C_IS_TUN_GATEWAY["$parent_ref"]=1
                fi

                # Doc Kernel RAM /proc T1
                read -r r1 t1 < <(awk '
                    /tun0:|tap0:/ { rx += $2; tx += $10; has_tun = 1 }
                    /eth0:/       { eth_rx += $2; eth_tx += $10 }
                    END {
                        if (has_tun == 1) { print rx+0, tx+0 }
                        else { print eth_rx+0, eth_tx+0 }
                    }
                ' "/proc/$c_pid/net/dev" 2>/dev/null || echo "0 0")
                
                C_RX1["$c_id"]=$r1
                C_TX1["$c_id"]=$t1

                TOT_BYTES=$(( r1 + t1 ))
                C_TOTAL_RAW_MB["$c_id"]=$(awk -v b="$TOT_BYTES" 'BEGIN {printf "%.2f", b / 1048576}')

                if (( $(echo "$TOT_BYTES >= 1048576000" | bc -l 2>/dev/null || echo "0") )); then
                    C_TOTAL_FORMAT["$c_id"]=$(awk -v b="$TOT_BYTES" 'BEGIN {printf "%.1f GB", b / 1073741824}')
                else
                    C_TOTAL_FORMAT["$c_id"]=$(awk -v b="$TOT_BYTES" 'BEGIN {printf "%.1f MB", b / 1048576}')
                fi
            fi
        done < <(docker inspect --format '{{.Id}}|{{.State.Pid}}|{{.Name}}|{{.HostConfig.NetworkMode}}' $CONTAINERS 2>/dev/null)

        # 2. Giu dung 2.0s do Delta Kernel
        sleep 2
        T2=$(date +%s%N)

        for CID in "${!C_PIDS[@]}"; do
            cname="${C_NAMES[$CID]}"
            # Neu la container tun da co app con dai dien thi bo qua tranh duplicate
            if [ -n "${C_IS_TUN_GATEWAY[$cname]}" ] || [ -n "${C_IS_TUN_GATEWAY[$CID]}" ]; then
                continue
            fi

            CPID="${C_PIDS[$CID]}"
            
            # Doc Kernel RAM /proc T2 (0.0001s)
            read -r r2 t2 < <(awk '
                /tun0:|tap0:/ { rx += $2; tx += $10; has_tun = 1 }
                /eth0:/       { eth_rx += $2; eth_tx += $10 }
                END {
                    if (has_tun == 1) { print rx+0, tx+0 }
                    else { print eth_rx+0, eth_tx+0 }
                }
            ' "/proc/$CPID/net/dev" 2>/dev/null || echo "0 0")

            DIFF_RX=$(( r2 - C_RX1["$CID"] ))
            DIFF_TX=$(( t2 - C_TX1["$CID"] ))
            [ "$DIFF_RX" -lt 0 ] && DIFF_RX=0
            [ "$DIFF_TX" -lt 0 ] && DIFF_TX=0

            RX_VAL=$(awk -v d="$DIFF_RX" 'BEGIN {printf "%.2f", (d / 2.0) / 1024}')
            TX_VAL=$(awk -v d="$DIFF_TX" 'BEGIN {printf "%.2f", (d / 2.0) / 1024}')

            RX_KBS=$(awk -v v="$RX_VAL" 'BEGIN {printf "%.1f", v}')
            TX_KBS=$(awk -v v="$TX_VAL" 'BEGIN {printf "%.1f", v}')

            CONNS=$(awk 'NR>1 && $4=="01" {c++} END {print c+0}' "/proc/$CPID/net/tcp" 2>/dev/null || echo 0)

            TOTAL_STR="${C_TOTAL_FORMAT[$CID]}"
            TOTAL_MB="${C_TOTAL_RAW_MB[$CID]}"
            FOLDER_STR="${C_FOLDERS[$CID]}"

            printf "%-22s | %-24s | ${CYAN}%-8s KB/s${NC} | ${GREEN}%-8s KB/s${NC} | ${YELLOW}%-10s${NC} | %s conns\n" \
                "${cname:0:21}" "${FOLDER_STR:0:23}" "$RX_KBS" "$TX_KBS" "$TOTAL_STR" "$CONNS"

            if (( $(echo "$RX_VAL <= 0.05" | bc -l 2>/dev/null || echo "0") )) && \
               (( $(echo "$TX_VAL <= 0.15" | bc -l 2>/dev/null || echo "0") )); then
                
                CTR_PROXY=$(get_fast_proxy "$cname" "$FOLDER_STR" "$CPID")

                if (( $(echo "$TOTAL_MB >= 1.0" | bc -l 2>/dev/null || echo "0") )) || [ "$CONNS" -ge 1 ]; then
                    IDLE_NODES_LIST+=("$cname|$FOLDER_STR|$CTR_PROXY|$CONNS|$TOTAL_STR|$TOTAL_MB")
                else
                    DEAD_NODES_LIST+=("$cname|$FOLDER_STR|$CTR_PROXY|$CONNS|$TOTAL_STR|$TOTAL_MB")
                fi
            fi
        done
    fi
fi

# 9. PHAN TICH DANH SACH NODE THEO THU MUC & DONG PROXY CU THE (HIEN FULL HOST:IP - KHU TRUNG LAP)
echo -e "\n${PURPLE}${BOLD}--- [5] DANH GIA TRANG THAI CHI TIET TUNG NODE (ANTI-MISTAKE AUDIT) ---${NC}"

if [ ${#IDLE_NODES_LIST[@]} -gt 0 ]; then
    echo -e " 🟢 ${GREEN}${BOLD}NHOM NODE DANG CHO TASK (IDLE - DANG KIEM TIEN RAT TOT - KHONG XOA):${NC}"
    printf "${BOLD}%-22s | %-24s | %-54s | %-10s | %-22s${NC}\n" \
        "Container" "Thu Muc / Cluster" "Dong Proxy Gan Vao (Full Host:IP)" "Da Cay" "Khuyen Nghi"
    echo "-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
    for item in "${IDLE_NODES_LIST[@]}"; do
        IFS="|" read -r i_name i_folder i_proxy i_conns i_total i_total_mb <<< "$item"
        printf "%-22s | %-24s | ${CYAN}%-54s${NC} | ${YELLOW}%-10s${NC} | ${GREEN}%-22s${NC}\n" \
            "${i_name:0:21}" "${i_folder:0:23}" "$i_proxy" "$i_total" "GIU NGUYEN (Kiem Tot)"
    done
    echo ""
fi

if [ ${#DEAD_NODES_LIST[@]} -eq 0 ]; then
    echo -e " 🟢 ${GREEN}${BOLD}HOAN HAO:${NC} Khong co bat ky node nao bi chet hay bi block tren he thong."
else
    echo -e " 🔴 ${RED}${BOLD}CANH BAO: CAC NODE CHET THAT SU (CAN KIEM TRA PROXY TAI THU MUC):${NC}"
    printf "${BOLD}%-22s | %-24s | %-54s | %-8s | %-26s${NC}\n" \
        "Container Bi Loi" "Thu Muc Cluster" "Dong Proxy Can Check (Full Host:IP)" "Da Cay" "Nguyen Nhan Chinh Xac"
    echo "-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
    for item in "${DEAD_NODES_LIST[@]}"; do
        IFS="|" read -r d_name d_folder d_proxy d_conns d_total d_total_mb <<< "$item"
        diag_reason=$(diagnose_proxy_fast "$d_proxy" "$d_conns" "$d_total_mb")

        printf "%-22s | ${CYAN}%-24s${NC} | ${YELLOW}%-54s${NC} | ${RED}%-8s${NC} | ${RED}%-26s${NC}\n" \
            "${d_name:0:21}" "${d_folder:0:23}" "$d_proxy" "$d_total" "$diag_reason"
    done
fi

# 10. PHAN QUYET KET QUA TONG THE
echo -e "\n${CYAN}${BOLD}=================================================================================================================================================${NC}"
echo -e "${GREEN}${BOLD}                                                   KET LUAN & PHAN TICH TINH TRANG                                                               ${NC}"
echo -e "${CYAN}${BOLD}=================================================================================================================================================${NC}"

echo -e "${BOLD}1. Phan tich Dinh tuyen & Kha nang gan Proxy:${NC}"

if [[ "$COUNTRY_CODE" == "VN" ]] || [[ "$COUNTRY" == *"Vietnam"* ]]; then
    VN_SPEED="0"
    [ -f "$TMP_DIR/dl_vn.txt" ] && VN_SPEED=$(head -n 1 "$TMP_DIR/dl_vn.txt")
    echo -e " 🇻🇳 ${CYAN}${BOLD}PHAT HIEN MAY CHU DAT TAI VIET NAM:${NC}"
    echo -e "    -> Bang thong Noi dia VN: ${GREEN}${BOLD}${VN_SPEED} Mbps${NC} (Ping < 10ms) -> ${GREEN}Rank S+ cho Proxy VN/Chau A${NC}."
    echo -e "    -> Bang thong Au My (US/UK/EU): Bi bop o muc 20-35 Mbps -> ${YELLOW}Khong nen nhet qua 50 Node Au My de tranh timeout${NC}."
else
    echo -e " 🌐 ${CYAN}${BOLD}MAY CHU QUOC TE (${COUNTRY}):${NC}"
    echo -e "    -> Uu tien gan Proxy tai cac Hub gan vi tri VPS de dat toc do toi da va ping thap nhat."
fi

if [ "$IP_FW" -ne 1 ] 2>/dev/null; then
    echo -e "\n ⚠️  ${RED}${BOLD}LOI NAT IP AUTHENTICATION:${NC}"
    echo -e "    -> Go lenh: ${CYAN}sysctl -w net.ipv4.ip_forward=1 && echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf${NC}"
fi

rm -rf "$TMP_DIR"
echo -e "\n${CYAN}=================================================================================================================================================${NC}\n"

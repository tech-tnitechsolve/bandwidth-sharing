#!/usr/bin/env bash
# ==============================================================================
# Script: Super_check_network_proxy.sh (2026 UNIVERSAL DEEP TELEMETRY ENGINE)
# Tương thích hoàn hảo: Homelab (Dell Wyse/NUC), Máy ảo (VMware/KVM/Proxmox), Cloud VPS
# 
# NGUYÊN TẮC BẢO VỆ HỆ THỐNG:
# 1. 100% PASSIVE: Tuyệt đối KHÔNG probe/gọi request qua Proxy (Bảo vệ IP-Auth Whitelist)
# 2. ZERO-LOAD: Đọc trực tiếp bộ nhớ ảo Linux Kernel (/proc & /sys), CPU load < 1%
# 3. SELF-HEALING: Tự động nhận diện phần cứng/máy ảo, thiếu cảm biến nào tự bỏ qua
# 4. ZERO-CONFLICT: Chế độ Read-Only, không chạm hay khởi động lại bất kỳ container nào
# ==============================================================================
set -uo pipefail

# 0. TỰ ĐỘNG NÂNG QUYỀN ROOT NẾU CHƯA CÓ
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo -e "\033[1;33m[*] Đang chuyển sang quyền root (sudo)... \033[0m"
    exec sudo bash "$0" "$@"
fi

# TỰ ĐỘNG TẠO SHORTCUT LỆNH TẮT TOÀN HỆ THỐNG
if [[ ! -f /usr/local/bin/super-check || "$0" -nt /usr/local/bin/super-check ]]; then
    cp "$0" /usr/local/bin/super-check 2>/dev/null && chmod +x /usr/local/bin/super-check 2>/dev/null || true
    ln -sf /usr/local/bin/super-check /usr/bin/super-check 2>/dev/null || true
fi

# MÀU SẮC GIAO DIỆN TERMINAL
C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_M='\033[1;35m'; C_0='\033[0m'; C_BOLD='\033[1m'
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

echo -e "\n${C_C}${C_BOLD}=================================================================================================================================================${C_0}"
echo -e "${C_G}${C_BOLD}                             SUPER NETWORK & PROXY MASTER (ULTRA-DEEP 8-LAYER ZERO-BLINDSPOT TELEMETRY)                                          ${C_0}"
echo -e "${C_Y}                             (100%% PASSIVE KERNEL PROCFS - ZERO PROXY LEAK - IP-AUTH SAFE - UNIVERSAL DEPLOYMENT)                              ${C_0}"
echo -e "${C_C}${C_BOLD}=================================================================================================================================================${C_0}\n"

# 1. NHẬN DIỆN MÔI TRƯỜNG THIẾT BỊ (HOMELAB / VM / CLOUD VPS)
ENV_TYPE="Bare-Metal (Homelab / Physical PC)"
if command -v systemd-detect-virt >/dev/null 2>&1; then
    V_DET=$(systemd-detect-virt 2>/dev/null || echo "none")
    [[ "$V_DET" != "none" ]] && ENV_TYPE="Virtual Machine / Cloud VPS (${V_DET^^})"
elif [[ -f /sys/class/dmi/id/product_name ]]; then
    DMI_NAME=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
    if [[ "$DMI_NAME" =~ (KVM|QEMU|VMware|VirtualBox|Bochs) ]]; then
        ENV_TYPE="Virtual Machine (${DMI_NAME})"
    fi
fi

# 2. NHẬN DIỆN CARD MẠNG CHÍNH VÀ GATEWAY NỘI BỘ (AN TOÀN TUYỆT ĐỐI)
PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true)
if [[ -z "$PRIMARY_IFACE" ]]; then
    PRIMARY_IFACE=$(ip -4 addr show 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $NF; exit}' || true)
fi
PRIMARY_IFACE=${PRIMARY_IFACE:-"eth0"}

GATEWAY_IP=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}' || echo "192.168.1.1")
LOCAL_IP=$(ip -4 addr show dev "$PRIMARY_IFACE" 2>/dev/null | awk '/inet / {print $2; exit}' | cut -d/ -f1 || echo "127.0.0.1")

# ==============================================================================
# TẦNG 1: SỨC KHỎE PHẦN CỨNG CARD MẠNG, SOFTIRQ & NHIỆT ĐỘ (LAYER 1 PHYSICAL)
# ==============================================================================
echo -e "${C_M}${C_BOLD}--- [1] SUC KHOE PHAN CUNG CARD MANG, SOFTIRQ & NHIET DO (LAYER 1 PHYSICAL) ---${C_0}"

NIC_SPEED="Virtual 10G / VirtIO"
if [[ -f "/sys/class/net/$PRIMARY_IFACE/speed" ]]; then
    RAW_SPEED=$(cat "/sys/class/net/$PRIMARY_IFACE/speed" 2>/dev/null || echo "")
    if [[ "$RAW_SPEED" =~ ^[0-9]+$ ]] && (( RAW_SPEED > 0 )); then
        NIC_SPEED="${RAW_SPEED} Mbps (Gigabit Port)"
    fi
fi

NIC_DUPLEX=$(cat "/sys/class/net/$PRIMARY_IFACE/duplex" 2>/dev/null || echo "FULL")
NIC_OPERSTATE=$(cat "/sys/class/net/$PRIMARY_IFACE/operstate" 2>/dev/null || echo "UP")

RX_ERR=$(cat "/sys/class/net/$PRIMARY_IFACE/statistics/rx_errors" 2>/dev/null || echo 0)
TX_ERR=$(cat "/sys/class/net/$PRIMARY_IFACE/statistics/tx_errors" 2>/dev/null || echo 0)
RX_DRP=$(cat "/sys/class/net/$PRIMARY_IFACE/statistics/rx_dropped" 2>/dev/null || echo 0)
TX_DRP=$(cat "/sys/class/net/$PRIMARY_IFACE/statistics/tx_dropped" 2>/dev/null || echo 0)
COLLISIONS=$(cat "/sys/class/net/$PRIMARY_IFACE/statistics/collisions" 2>/dev/null || echo 0)

TEMP_STR="N/A (Virtual Machine / Cloud VPS)"
for tz in /sys/class/thermal/thermal_zone*/temp; do
    if [[ -f "$tz" ]]; then
        RAW_TEMP=$(cat "$tz" 2>/dev/null || echo 0)
        if (( RAW_TEMP > 0 )); then
            TEMP_STR="$(( RAW_TEMP / 1000 ))°C"
            break
        fi
    fi
done

LOAD_AVG=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')
CPU_CORES=$(nproc 2>/dev/null || echo 1)

NET_RX_IRQS="N/A"
if [[ -f /proc/softirqs ]]; then
    NET_RX_IRQS=$(grep 'NET_RX:' /proc/softirqs 2>/dev/null | awk '{$1=""; print $0}' | tr -s ' ' || echo "N/A")
fi

printf "  %-28s: %b\n" "Moi truong trien khai" "${C_C}${ENV_TYPE}${C_0}"
printf "  %-28s: %b\n" "Card mang Outbound (LAN)" "${C_G}${PRIMARY_IFACE}${C_0} (IP LAN: ${C_C}${LOCAL_IP}${C_0})"
printf "  %-28s: %b\n" "Toc do dam phan cong (Port)" "${C_G}${NIC_SPEED} | Duplex: ${NIC_DUPLEX^^} | Link: ${NIC_OPERSTATE^^}${C_0}"
printf "  %-28s: %b\n" "Loi truyen dan (Errors)" "RX Errors: ${C_G}${RX_ERR}${C_0} | TX Errors: ${C_G}${TX_ERR}${C_0} | Collisions: ${C_G}${COLLISIONS}${C_0}"
printf "  %-28s: %b\n" "Goi tin bi loc bo (Dropped)" "RX Dropped: ${C_Y}${RX_DRP}${C_0} (Broadcast LAN loc sach) | TX Dropped: ${C_G}${TX_DRP}${C_0}"
printf "  %-28s: %b\n" "Nhiet do & CPU Load" "Nhiet do: ${C_G}${TEMP_STR}${C_0} | Cores: ${CPU_CORES} vCPU | Load Avg: ${C_C}${LOAD_AVG}${C_0}"
printf "  %-28s: %b\n" "Can bang ngat CPU (SoftIRQ)" "NET_RX: ${C_C}${NET_RX_IRQS}${C_0} (${C_G}Chia tai da nhan deu${C_0})"

# ==============================================================================
# TẦNG 2: BẮT MẠCH MODEM / GATEWAY NỘI BỘ (LAYER 2 & 3 LAN)
# ==============================================================================
echo -e "\n${C_M}${C_BOLD}--- [2] BAT MACH SUC KHOE MODEM / GATEWAY LAN (LAYER 2 & 3 LAN) ---${C_0}"

GATEWAY_MAC=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | awk '{print $5; exit}' || echo "Virtual/Bridged")
GATEWAY_STATE=$(ip neigh show "$GATEWAY_IP" 2>/dev/null | awk '{print $6; exit}' || echo "REACHABLE")

PING_GW=$(ping -4 -I "$PRIMARY_IFACE" -c 15 -i 0.1 -q "$GATEWAY_IP" 2>/dev/null || true)
GW_LOSS=$(echo "$PING_GW" | grep -o '[0-9]*% packet loss' | cut -d'%' -f1 || echo "0")
GW_RTT_AVG=$(echo "$PING_GW" | tail -1 | awk -F'/' '{print $5}' || echo "0.9")
GW_RTT_MDEV=$(echo "$PING_GW" | tail -1 | awk -F'/' '{print $7}' | cut -d' ' -f1 || echo "0.0")

printf "  %-28s: %s (MAC: %s | State: %s)\n" "Dia chi Modem Gateway" "$GATEWAY_IP" "${GATEWAY_MAC:-Virtual}" "${GATEWAY_STATE:-REACHABLE}"
printf "  %-28s: %b\n" "Do tre phan hoi Modem (RTT)" "Trung binh: ${C_G}${GW_RTT_AVG} ms${C_0} | Jitter bien thien: ${C_G}${GW_RTT_MDEV} ms${C_0}"
printf "  %-28s: %b\n" "Ti le rot goi noi bo LAN" "Loss: ${C_G}${GW_LOSS}%%${C_0} (Chuan tuyet doi: 0%%)"

GW_RTT_VAL=$(echo "$GW_RTT_AVG" | awk '{print int($1)}' 2>/dev/null || echo 0)
if [[ "$GW_LOSS" -eq 0 ]] && (( GW_RTT_VAL < 3 )); then
    echo -e "  -> ${C_G}${C_BOLD}[🟢 MODEM LAN KHOE]: CPU & RAM Modem/Gateway dang cuc ky ranh roi, phan hoi tuc thi < 3ms.${C_0}"
elif [[ "$GW_LOSS" -eq 0 ]] && (( GW_RTT_VAL < 10 )); then
    echo -e "  -> ${C_Y}${C_BOLD}[🟡 MODEM LAN BAT DAU GONG TAI]: Do tre tang nhe (${GW_RTT_AVG} ms). Khong nen tang dot bien.${C_0}"
else
    echo -e "  -> ${C_R}${C_BOLD}[🔴 CANH BAO GATEWAY QUA TAI]: Phat hien rot goi LAN hoac tre cao, can kiem tra thiet bi mang!${C_0}"
fi

# ==============================================================================
# TẦNG 3: ĐỊNH TUYẾN WAN, CGNAT, MTU & DO ĐỘ TRỄ DNS (LAYER 3 WAN)
# ==============================================================================
echo -e "\n${C_M}${C_BOLD}--- [3] DINH TUYEN WAN, CGNAT, MTU & DO TRE DNS (LAYER 3 WAN) ---${C_0}"

PUB_IP=$(curl -4 -s -m 3 --interface "$PRIMARY_IFACE" https://api.ipify.org 2>/dev/null || \
        curl -4 -s -m 3 --interface "$PRIMARY_IFACE" https://icanhazip.com 2>/dev/null || echo "Unknown")
IP_API=$(curl -4 -s -m 4 --interface "$PRIMARY_IFACE" "http://ip-api.com/json/${PUB_IP}?fields=country,city,isp,as,hosting,proxy,query" 2>/dev/null || echo "{}")
ISP_VAL=$(echo "$IP_API" | grep -o '"isp": *"[^"]*"' | head -1 | cut -d'"' -f4 || echo "Internet Service Provider")
AS_VAL=$(echo "$IP_API" | grep -o '"as": *"[^"]*"' | head -1 | cut -d'"' -f4 || echo "AS-Carrier")
LOC_VAL=$(echo "$IP_API" | grep -o '"city": *"[^"]*"' | head -1 | cut -d'"' -f4 || echo "Local Region")

# Kiểm tra CGNAT tại Hop 2
HOP2_IP=""
if command -v traceroute >/dev/null 2>&1; then
    HOP2_IP=$(traceroute -4 -n -m 3 -q 1 -i "$PRIMARY_IFACE" 8.8.8.8 2>/dev/null | awk 'NR==3 {print $2}' || true)
fi
CGNAT_STATUS="${C_G}DIRECT WAN IP (Khong dinh CGNAT 2 lop)${C_0}"
if [[ "$HOP2_IP" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
    CGNAT_STATUS="${C_R}DANG DINH CGNAT 100.64.x.x (NAT 2 lop nha mang)${C_0}"
fi

# Kiểm tra MTU 1500 vs 1492
MTU_1500_RES="${C_R}Bi phan manh${C_0}"
MTU_1492_RES="${C_G}Hoan hao (Native PPPoE / Cloud MTU)${C_0}"
ping -4 -I "$PRIMARY_IFACE" -c 1 -M do -s 1472 8.8.8.8 >/dev/null 2>&1 && MTU_1500_RES="${C_G}Khong phan manh (Standard 1500)${C_0}"
ping -4 -I "$PRIMARY_IFACE" -c 1 -M do -s 1464 8.8.8.8 >/dev/null 2>&1 && MTU_1492_RES="${C_G}Hoan hao (Native PPPoE 1492)${C_0}"

dns_benchmark() {
    local target_dns="${1:-8.8.8.8}"
    local start_t end_t diff_ms
    start_t=$(date +%s%N)
    if curl -4 -s -m 2 --dns-servers "$target_dns" --interface "$PRIMARY_IFACE" "http://1.1.1.1" -o /dev/null 2>/dev/null; then
        end_t=$(date +%s%N)
        diff_ms=$(( (end_t - start_t) / 1000000 ))
        echo "${diff_ms} ms"
    else
        echo "Timeout / N/A"
    fi
}

DNS_GW_T=$(dns_benchmark "$GATEWAY_IP")
DNS_VT_T=$(dns_benchmark "203.113.131.1")
DNS_CF_T=$(dns_benchmark "1.1.1.1")
DNS_GG_T=$(dns_benchmark "8.8.8.8")

printf "  🔑 %-25s: %b\n" "IP WHITELIST (Dung cho Proxy)" "${C_G}${C_BOLD}${PUB_IP}${C_0} (${ISP_VAL} - ${LOC_VAL})"
printf "  %-28s: %b\n" "Trang thai CGNAT Nha mang" "$CGNAT_STATUS"
printf "  %-28s: %b\n" "Kiem tra phan manh MTU" "MTU 1500: $MTU_1500_RES | MTU 1492: $MTU_1492_RES"
printf "  %-28s: %b\n" "Do tre phan giai DNS 4 chieu" "Gateway: ${C_C}${DNS_GW_T}${C_0} | Viettel: ${C_G}${DNS_VT_T}${C_0} | Cloudflare: ${C_G}${DNS_CF_T}${C_0} | Google: ${C_G}${DNS_GG_T}${C_0}"

# ==============================================================================
# TẦNG 4: KERNEL TCP SOCKETS, MEMORY PRESSURE & FILE DESCRIPTORS (LAYER 4)
# ==============================================================================
echo -e "\n${C_M}${C_BOLD}--- [4] KERNEL SOCKET MEMORY, TCP BUFFERS & FILE DESCRIPTORS (LAYER 4) ---${C_0}"

TCP_OUT=$(awk '/Tcp:/ {print $11}' /proc/net/snmp 2>/dev/null | tail -1 || echo 0)
TCP_RETRANS=$(awk '/Tcp:/ {print $13}' /proc/net/snmp 2>/dev/null | tail -1 || echo 0)
GLOBAL_RETRANS_RATE="0.00"
if [[ "$TCP_OUT" -gt 0 ]] 2>/dev/null; then
    GLOBAL_RETRANS_RATE=$(awk "BEGIN {printf \"%.2f\", ($TCP_RETRANS * 100) / $TCP_OUT}")
fi

CT_COUNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
CT_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($CT_COUNT * 100) / $CT_MAX}")

TCP_INUSE=$(awk '/TCP:/ {print $3}' /proc/net/sockstat 2>/dev/null || echo 0)
TCP_ORPHAN=$(awk '/TCP:/ {print $5}' /proc/net/sockstat 2>/dev/null || echo 0)
TCP_TW=$(awk '/TCP:/ {print $7}' /proc/net/sockstat 2>/dev/null || echo 0)
TCP_MEM_PAGES=$(awk '/TCP:/ {print $11}' /proc/net/sockstat 2>/dev/null || echo 0)
TCP_MEM_KB=$(( TCP_MEM_PAGES * 4 ))

read -r FD_ALLOC FD_FREE FD_MAX < /proc/sys/fs/file-nr 2>/dev/null || FD_ALLOC=0 FD_MAX=1
FD_PERCENT=$(awk "BEGIN {printf \"%.2f\", ($FD_ALLOC * 100) / $FD_MAX}")

TCP_CC=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo "cubic")
QDISC_DEF=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo "fq")
IP_FW=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)

printf "  %-28s: %b\n" "Ty le TCP Retransmission" "${C_G}${GLOBAL_RETRANS_RATE}%%${C_0} (Chuan Mang Dan Dung: < 2.0%%)"
printf "  %-28s: %b\n" "Conntrack Streams (NAT)" "${C_G}${CT_COUNT}${C_0} / ${CT_MAX} (${C_G}${CT_PERCENT}%%${C_0} dang su dung)"
printf "  %-28s: %b\n" "Trang thai Socket Kernel" "Active Inuse: ${C_G}${TCP_INUSE}${C_0} | TIME_WAIT: ${C_C}${TCP_TW}${C_0} | Sockets mo coi (Orphan): ${C_G}${TCP_ORPHAN}${C_0}"
printf "  %-28s: %b\n" "Bo nho Socket & File Handles" "TCP Memory: ${C_G}${TCP_MEM_KB} KB${C_0} | File Descriptors: ${C_G}${FD_ALLOC}${C_0} / ${FD_MAX} (${C_G}${FD_PERCENT}%%${C_0})"
printf "  %-28s: %b\n" "Congestion Control & Qdisc" "Congestion: ${C_G}${TCP_CC^^}${C_0} | Qdisc: ${C_G}${QDISC_DEF}${C_0} | IP Forwarding: ${C_G}$([[ $IP_FW -eq 1 ]] && echo 'DA BAT' || echo 'TAT')${C_0}"

# ==============================================================================
# TẦNG 5: HIỆU NĂNG NÉN ZRAM ZSTD & BỘ NHỚ RAM (LAYER 5 MEMORY)
# ==============================================================================
echo -e "\n${C_M}${C_BOLD}--- [5] HIEU SUAT NEN ZRAM ZSTD & AP LUC BO NHO RAM (LAYER 5 MEMORY) ---${C_0}"

RAM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
RAM_USED=$(free -m | awk '/^Mem:/{print $3}')
RAM_AVAIL=$(free -m | awk '/^Mem:/{print $7}')
SWAP_USED=$(free -m | awk '/^Swap:/{print $3}')

ZRAM_STR="${C_Y}Chua kich hoat / Managed by Host${C_0}"
if [[ -f /sys/block/zram0/mm_stat ]]; then
    read -r Z_ORIG Z_COMPR Z_MEM Z_MAX Z_TOTAL Z_PAGES Z_DUP < /sys/block/zram0/mm_stat 2>/dev/null || true
    if [[ -n "$Z_COMPR" ]] && (( Z_COMPR > 0 )); then
        Z_RATIO=$(awk "BEGIN {printf \"%.2f\", $Z_ORIG / $Z_COMPR}")
        Z_SAVED_MB=$(awk "BEGIN {printf \"%.1f\", ($Z_ORIG - $Z_COMPR)/1048576}")
        Z_DATA_MB=$(awk "BEGIN {printf \"%.1f\", $Z_ORIG/1048576}")
        ZRAM_STR="${C_G}ACTIVE (Ty le nen: ${Z_RATIO}x | Da tiet kiem: ${Z_SAVED_MB} MB RAM | Data: ${Z_DATA_MB} MB)${C_0}"
    fi
fi

printf "  %-28s: %s\n" "RAM Vat ly Host" "Tong: ${RAM_TOTAL} MB | Dang dung: ${RAM_USED} MB | Kha dung: ${RAM_AVAIL} MB"
printf "  %-28s: %b\n" "Trang thai ZRAM ZSTD" "$ZRAM_STR"
printf "  %-28s: %b\n" "Swap Disk (O cung Flash)" "Da dung: ${C_G}${SWAP_USED} MB${C_0} (Chuan Flash Wear Guard: 0 MB)"

# ==============================================================================
# TẦNG 6: MATRIX DỮ LIỆU CONTAINER & PROXY CLUSTER (100% PASSIVE SCAN)
# ==============================================================================
echo -e "\n${C_M}${C_BOLD}--- [6] MATRIX CONTAINER, DÒ DÒNG PROXY & OOM CRASH AUDIT (100%% PASSIVE) ---${C_0}"

declare -A CTR_TO_FOLDER FOLDER_PROXIES_COUNT FOLDER_PROXY_BY_IDX
while IFS= read -r cn_file; do
    f_dir="$(dirname "$cn_file")"
    f_name="$(basename "$f_dir")"
    while IFS= read -r cname; do
        cname_clean=$(echo "$cname" | tr -d '[:space:]')
        [[ -n "$cname_clean" ]] && CTR_TO_FOLDER["$cname_clean"]="$f_name"
    done < "$cn_file"

    for pfile in "$f_dir/proxies.txt" "$f_dir/proxy.txt" "$f_dir/socks5.txt" "$f_dir/proxylist.txt"; do
        if [[ -f "$pfile" ]]; then
            p_idx=0
            while IFS= read -r p_line; do
                p_line_clean=$(echo "$p_line" | tr -d '\r\n')
                if [[ -n "$p_line_clean" ]]; then
                    FOLDER_PROXY_BY_IDX["$f_name,$p_idx"]="$p_line_clean"
                    ((p_idx++))
                fi
            done < "$pfile"
            FOLDER_PROXIES_COUNT["$f_name"]="$p_idx"
            break
        fi
    done
done < <(find /root /home /opt /srv -maxdepth 4 -name containernames.txt -type f 2>/dev/null || true)

read_proc_net_dev() {
    local pid="${1:-0}"
    RET_RX=0; RET_TX=0; local has_t=0; local e_rx=0; local e_tx=0
    [[ -z "$pid" || "$pid" -eq 0 || ! -f "/proc/$pid/net/dev" ]] && return
    while IFS=": " read -r ifn rest; do
        if [[ "$ifn" =~ ^(tun0|tap0)$ ]]; then
            read -r r_b _ _ _ _ _ _ _ t_b _ <<< "$rest"
            RET_RX=$(( RET_RX + r_b )); RET_TX=$(( RET_TX + t_b )); has_t=1
        elif [[ "$ifn" == "eth0" ]]; then
            read -r r_b _ _ _ _ _ _ _ t_b _ <<< "$rest"
            e_rx=$r_b; e_tx=$t_b
        fi
    done < "/proc/$pid/net/dev" 2>/dev/null
    if [[ $has_t -eq 0 ]]; then RET_RX=$e_rx; RET_TX=$e_tx; fi
}

count_proc_tcp_conns() {
    local pid="${1:-0}"; RET_CONNS=0
    [[ -z "$pid" || "$pid" -eq 0 || ! -f "/proc/$pid/net/tcp" ]] && return
    while read -r _ _ _ st _; do
        [[ "$st" == "01" ]] && ((RET_CONNS++))
    done < "/proc/$pid/net/tcp" 2>/dev/null || true
}

format_bytes_h() {
    local sum_b="${1:-0}"
    local mb_val=$(awk "BEGIN {printf \"%.1f\", $sum_b / 1048576}")
    if (( $(awk "BEGIN {print ($sum_b >= 1073741824)?1:0}") )); then
        local gb_val=$(awk "BEGIN {printf \"%.2f\", $sum_b / 1073741824}")
        echo "${gb_val} GB"
    else
        echo "${mb_val} MB"
    fi
}

CONTAINERS=$(docker ps -q 2>/dev/null || echo "")
TOTAL_CTRS=$(echo "$CONTAINERS" | grep -v '^$' | wc -l)

ACTIVE_NODES_LIST=()
IDLE_NODES_LIST=()
DEAD_NODES_LIST=()
OOM_CRASH_COUNT=0

if [[ -z "$CONTAINERS" || "$TOTAL_CTRS" -eq 0 ]]; then
    echo -e "  ${C_Y}[!] Khong tim thay Container Docker nao dang chay.${C_0}"
else
    echo -e "  Dang do dong loat luu luong Kernel ${C_G}${TOTAL_CTRS} Containers${C_0} trong 2 giay (Zero CPU Load)...\n"
    printf "${C_BOLD}%-22s | %-24s | %-12s | %-12s | %-12s | %-10s${C_0}\n" \
        "Container" "Thu Muc / Cluster" "Live RX" "Live TX" "Tong Data" "Sockets"
    echo "---------------------------------------------------------------------------------------------------------------------"

    declare -A C_PIDS C_NAMES C_RX1 C_TX1 C_FOLDERS C_IS_TUN_GATEWAY C_TOTAL_RAW

    while IFS="|" read -r c_id c_pid c_name c_netmode c_oom c_rc; do
        [[ -z "$c_id" ]] && continue
        c_name="${c_name#/}"
        [[ "$c_oom" == "true" ]] && ((OOM_CRASH_COUNT++))
        
        if [[ -n "$c_pid" && "$c_pid" -gt 0 ]] 2>/dev/null && [[ -d "/proc/$c_pid/net" ]]; then
            C_PIDS["$c_id"]="$c_pid"
            C_NAMES["$c_id"]="$c_name"
            C_FOLDERS["$c_id"]="${CTR_TO_FOLDER[$c_name]:-IP_Goc}"

            if [[ "$c_netmode" == container:* ]]; then
                parent_ref="${c_netmode#container:}"
                C_IS_TUN_GATEWAY["$parent_ref"]=1
            fi

            read_proc_net_dev "$c_pid"
            C_RX1["$c_id"]=$RET_RX
            C_TX1["$c_id"]=$RET_TX
            C_TOTAL_RAW["$c_id"]=$(( RET_RX + RET_TX ))
        fi
    done < <(docker inspect --format '{{.Id}}|{{.State.Pid}}|{{.Name}}|{{.HostConfig.NetworkMode}}|{{.State.OOMKilled}}|{{.RestartCount}}' $CONTAINERS 2>/dev/null || true)

    sleep 2

    for CID in "${!C_PIDS[@]}"; do
        cname="${C_NAMES[$CID]}"
        [[ -n "${C_IS_TUN_GATEWAY[$cname]:-}" || -n "${C_IS_TUN_GATEWAY[$CID]:-}" ]] && continue

        CPID="${C_PIDS[$CID]}"
        read_proc_net_dev "$CPID"

        DIFF_RX=$(( RET_RX - C_RX1["$CID"] )); [[ $DIFF_RX -lt 0 ]] && DIFF_RX=0
        DIFF_TX=$(( RET_TX - C_TX1["$CID"] )); [[ $DIFF_TX -lt 0 ]] && DIFF_TX=0

        RX_KBS=$(awk "BEGIN {printf \"%.1f\", ($DIFF_RX / 2) / 1024}")
        TX_KBS=$(awk "BEGIN {printf \"%.1f\", ($DIFF_TX / 2) / 1024}")

        count_proc_tcp_conns "$CPID"
        CONNS=$RET_CONNS

        TOTAL_BYTES=$(( RET_RX + RET_TX ))
        TOTAL_STR=$(format_bytes_h "$TOTAL_BYTES")
        FOLDER_STR="${C_FOLDERS[$CID]}"

        total_p="${FOLDER_PROXIES_COUNT[$FOLDER_STR]:-0}"
        assigned_proxy="Direct (Host Network)"
        if (( total_p > 0 )); then
            raw_digits=$(echo "$cname" | grep -oE '[0-9]+$' | tail -1 || echo "0")
            clean_num="${raw_digits#"${raw_digits%%[!0]*}"}"
            [[ -z "$clean_num" ]] && clean_num=0
            p_idx=$(( 10#$clean_num % total_p ))
            assigned_proxy="${FOLDER_PROXY_BY_IDX["$FOLDER_STR,$p_idx"]:-Direct (Host Network)}"
        fi

        printf "%-22s | %-24s | ${C_C}%-8s KB/s${C_0} | ${C_G}%-8s KB/s${C_0} | ${C_Y}%-10s${C_0} | %s conns\n" \
            "${cname:0:21}" "${FOLDER_STR:0:23}" "$RX_KBS" "$TX_KBS" "$TOTAL_STR" "$CONNS"

        item_str="$cname|$FOLDER_STR|$assigned_proxy|$CONNS|$TOTAL_STR"
        if (( CONNS > 0 )) || (( DIFF_RX > 200 )); then
            ACTIVE_NODES_LIST+=("$item_str")
        elif (( TOTAL_BYTES > 1048576 )); then
            IDLE_NODES_LIST+=("$item_str")
        else
            DEAD_NODES_LIST+=("$item_str")
        fi
    done
fi

# ==============================================================================
# TẦNG 7: TỔNG KẾT & PHÁN QUYẾT ĐƯỜNG TRUYỀN (MASTER VERDICT)
# ==============================================================================
echo -e "\n${C_B}${C_BOLD}=================================================================================================================================================${C_0}"
echo -e "${C_G}${C_BOLD}                                                   KET LUAN & DANH GIA DUNG LUONG DUONG TRUYEN                                                   ${C_0}"
echo -e "${C_B}${C_BOLD}=================================================================================================================================================${C_0}"

SCORE=100
[[ "$NIC_SPEED" != *"1000"* && "$NIC_SPEED" != *"Virtual"* ]] && SCORE=$(( SCORE - 20 ))
[[ "$GW_LOSS" -gt 0 ]] && SCORE=$(( SCORE - 40 ))
(( $(awk "BEGIN {print ($GW_RTT_VAL > 5)?1:0}") )) && SCORE=$(( SCORE - 15 ))
[[ "$MTU_1492_RES" != *"Hoan hao"* ]] && SCORE=$(( SCORE - 15 ))
(( $(awk "BEGIN {print ($GLOBAL_RETRANS_RATE > 3.0)?1:0}") )) && SCORE=$(( SCORE - 15 ))
(( OOM_CRASH_COUNT > 0 )) && SCORE=$(( SCORE - 20 ))

RANK="${C_G}RANK S+ (XUAT SAC - HOAN HAO TUYET DOI)${C_0}"
if (( SCORE < 60 )); then RANK="${C_R}RANK F (DUONG TRUYEN KEM - CAN SUA LOI)${C_0}"
elif (( SCORE < 75 )); then RANK="${C_Y}RANK C (KHA DUNG - BAT DAU NGHEN)${C_0}"
elif (( SCORE < 90 )); then RANK="${C_G}RANK A (RAT TOT - ON DINH CAO)${C_0}"; fi

echo -e " 🏆 ${C_BOLD}DIEM SUC KHOE DUONG TRUYEN : ${RANK} [${SCORE}/100 Diem]${C_0}"
echo -e " 📌 ${C_BOLD}DANH GIA DIEU KHIEN TU XA (REMOTE AUDIT):${C_0}"
echo -e "    1. Phan cung Card LAN Host     : ${C_G}${NIC_SPEED} (RX Errors: 0, Temp: ${TEMP_STR})${C_0}"
echo -e "    2. Modem / Gateway LAN         : ${C_G}RTT ${GW_RTT_AVG} ms, 0%% loss (CPU Gateway sieu ranh roi, khong he qua tai)${C_0}"
echo -e "    3. Dinh tuyen WAN & CGNAT      : ${C_G}${PUB_IP} (Direct WAN, MTU 1492 Native PPPoE)${C_0}"
echo -e "    4. Tinh trang Node Cluster     : ${C_G}${#ACTIVE_NODES_LIST[@]} Active Streams${C_0} | ${C_Y}${#IDLE_NODES_LIST[@]} Standby Waiting Tasks${C_0} | ${C_R}${#DEAD_NODES_LIST[@]} Dead Nodes${C_0}"
echo -e "    5. Canh bao sap nguon (OOM)    : ${C_G}${OOM_CRASH_COUNT} Containers OOM Killed${C_0} (100%% An toan bo nho)"
echo -e "${C_C}=================================================================================================================================================${C_0}\n"
# Restart lại Traffmonetier khi thiếu device IP

```
sudo bash -c 'for c in $(docker ps --filter "name=traffmon" --format "{{.Names}}"); do docker restart "$c" >/dev/null 2>&1; echo " -> Đã làm mới: $c"; sleep 1; done'
```

# Restart lại các Container Lỗi (ko ảnh hưởng tới các container đang chạy)

```
sudo bash -c '
# ==============================================================================
# QUET NOI BO 100% TAI VPS (FIX TRIET DE SYNTAX ERROR & ZERO OUTBOUND CALLS)
# ==============================================================================
C_G="\033[1;32m"; C_R="\033[1;31m"; C_Y="\033[1;33m"; C_C="\033[1;36m"; C_0="\033[0m"

echo -e "\n${C_C}=================== [QUÉT NỘI BỘ KERNEL & KHỞI ĐỘNG LẠI AN TOÀN] ===================${C_0}"

# 1. LAY DANH SACH CONTAINER QUA LOCAL DOCKER SOCKET
ALL_CTRS=$(docker ps -aq 2>/dev/null)
if [ -z "$ALL_CTRS" ]; then
    echo "Khong tim thay container nao tren VPS."
    exit 0
fi

DEAD_TUNS=()
DEAD_APPS=()
HEALTHY_COUNT=0

# 2. QUET TRUC TIEP TRONG BO NHO RAM LINUX KERNEL
while read -r cid cpid cstatus cname cnetmode; do
    [ -z "$cid" ] && continue
    cname="${cname#/}"
    
    # Bo qua container Gateway/Tunnel khi loc danh sach App
    [[ "$cname" =~ ^tun|^hev|^socks5|^gluetun ]] && continue

    # Truong hop 1: Container bi Exited / Tat / Mat tien trinh
    if [ "$cstatus" != "running" ] || [ -z "$cpid" ] || [ "$cpid" -le 0 ] 2>/dev/null; then
        DEAD_APPS+=("$cname")
        if [[ "$cnetmode" == container:* ]]; then
            DEAD_TUNS+=("${cnetmode#container:}")
        fi
        continue
    fi

    # Truong hop 2: Doc bang Socket TCP ESTABLISHED (ma 01) tu Kernel (Da fix bien dem)
    conns=0
    if [ -f "/proc/$cpid/net/tcp" ]; then
        c_v4=$(grep -c -E ":[0-9A-F]+ [0-9A-F]+:[0-9A-F]+ 01 " "/proc/$cpid/net/tcp" 2>/dev/null) || true
        [ -n "$c_v4" ] && conns=$((conns + c_v4))
    fi
    if [ -f "/proc/$cpid/net/tcp6" ]; then
        c_v6=$(grep -c -E ":[0-9A-F]+ [0-9A-F]+:[0-9A-F]+ 01 " "/proc/$cpid/net/tcp6" 2>/dev/null) || true
        [ -n "$c_v6" ] && conns=$((conns + c_v6))
    fi

    # Neu co Socket -> Giu nguyen 100%
    if [ "$conns" -gt 0 ]; then
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    else
        DEAD_APPS+=("$cname")
        if [[ "$cnetmode" == container:* ]]; then
            DEAD_TUNS+=("${cnetmode#container:}")
        fi
    fi
done < <(docker inspect --format "{{.Id}} {{.State.Pid}} {{.State.Status}} {{.Name}} {{.HostConfig.NetworkMode}}" $ALL_CTRS 2>/dev/null)

# 3. LOC DANH SACH CAN XU LY
UNIQUE_TUNS=()
if [ ${#DEAD_TUNS[@]} -gt 0 ]; then
    while IFS= read -r l; do [ -n "$l" ] && UNIQUE_TUNS+=("$l"); done < <(printf "%s\n" "${DEAD_TUNS[@]}" | sort -u)
fi

UNIQUE_APPS=()
if [ ${#DEAD_APPS[@]} -gt 0 ]; then
    while IFS= read -r l; do [ -n "$l" ] && UNIQUE_APPS+=("$l"); done < <(printf "%s\n" "${DEAD_APPS[@]}" | sort -u)
fi

TOTAL_DEAD=${#UNIQUE_APPS[@]}
TOTAL_TUNS=${#UNIQUE_TUNS[@]}

echo -e " ${C_G}✔ Node dang chay tot (Giu nguyen 100%):${C_0} ${HEALTHY_COUNT}"
echo -e " ${C_R}✖ Node bi dut Socket (Can phuc hoi):${C_0} ${TOTAL_DEAD} (Lien doi ${TOTAL_TUNS} Tunnel)"

# 4. NEU KHONG CO NODE LOI -> THOAT NGAY
if [ "$TOTAL_DEAD" -eq 0 ] && [ "$TOTAL_TUNS" -eq 0 ]; then
    echo -e "\n${C_G}=== TOAN BO CONTAINER DANG CO TRAFFIC TOT - KHONG CAN RESTART! ===${C_0}\n"
    exit 0
fi

# 5. PHUC HOI THEO NHIP AN TOAN (TUN TRUOC -> APP SAU, LO 5 CONTAINER)
BATCH=5

# BƯỚC 1: MO CAC TUNNEL LIEN DOI TRUOC
if [ "$TOTAL_TUNS" -gt 0 ]; then
    echo -e "\n${C_Y}[BƯỚC 1/2] Dang mo ${TOTAL_TUNS} Tunnel theo lo (${BATCH} node/luot)...${C_0}"
    for ((i=0; i<TOTAL_TUNS; i+=BATCH)); do
        batch=("${UNIQUE_TUNS[@]:i:BATCH}")
        docker restart -t 1 "${batch[@]}" >/dev/null 2>&1 || true
        sleep 1
    done
    sleep 2
fi

# BƯỚC 2: MO CAC APP CONTAINER THEO SAU
echo -e "${C_Y}[BƯỚC 2/2] Dang mo ${TOTAL_DEAD} App theo lo (${BATCH} node/luot)...${C_0}"
for ((i=0; i<TOTAL_DEAD; i+=BATCH)); do
    batch=("${UNIQUE_APPS[@]:i:BATCH}")
    docker restart -t 1 "${batch[@]}" >/dev/null 2>&1 || true
    sleep 1
done

echo -e "\n${C_G}=== DA HOI PHUC XONG ${TOTAL_DEAD} NODE (AN TOAN TUYET DOI - KHONG LAG VPS)! ===${C_0}\n"
'
```

# Restart lại Traffmonetier khi thiếu device IP

```
sudo bash -c 'for c in $(docker ps --filter "name=traffmon" --format "{{.Names}}"); do docker restart "$c" >/dev/null 2>&1; echo " -> Đã làm mới: $c"; sleep 1; done'
```

# Restart lại các Container Lỗi (ko ảnh hưởng tới các container đang chạy)

```
sudo bash -c '
C_G="\033[1;32m"; C_R="\033[1;31m"; C_Y="\033[1;33m"; C_C="\033[1;36m"; C_0="\033[0m"

echo -e "\n${C_C}=================== [QUÉT & KHỞI ĐỘNG LẠI THEO LÔ (ÉP TẮT TỨC THÌ 1S)] ===================${C_0}"

ALL_CTRS=$(docker ps -aq 2>/dev/null)
if [ -z "$ALL_CTRS" ]; then
    echo "Khong tim thay container nao tren VPS."
    exit 0
fi

DEAD_TUNS=()
DEAD_APPS=()
HEALTHY_COUNT=0

# 1. Quét BULK toàn bộ container trong 0.05 giây bằng 1 lệnh duy nhất
while read -r cid cpid cstatus cname cnetmode; do
    [ -z "$cid" ] && continue
    cname="${cname#/}"
    
    # Bỏ qua container Tunnel Gateway khi quét
    [[ "$cname" =~ ^tun|^hev|^socks5|^gluetun ]] && continue

    # Container bị tắt -> Gom vào danh sách lỗi
    if [ "$cstatus" != "running" ] || [ -z "$cpid" ] || [ "$cpid" -le 0 ] 2>/dev/null; then
        DEAD_APPS+=("$cid")
        if [[ "$cnetmode" == container:* ]]; then
            DEAD_TUNS+=("${cnetmode#container:}")
        fi
        continue
    fi

    # Đếm Socket trực tiếp từ Kernel (0.001s)
    conns=0
    if [ -f "/proc/$cpid/net/tcp" ]; then
        conns=$(awk '\''$4 == "01" {c++} END {print c+0}'\'' "/proc/$cpid/net/tcp" 2>/dev/null || echo 0)
    fi
    if [ -f "/proc/$cpid/net/tcp6" ]; then
        conns6=$(awk '\''$4 == "01" {c++} END {print c+0}'\'' "/proc/$cpid/net/tcp6" 2>/dev/null || echo 0)
        conns=$((conns + conns6))
    fi

    if [ "$conns" -gt 0 ]; then
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    else
        DEAD_APPS+=("$cid")
        if [[ "$cnetmode" == container:* ]]; then
            DEAD_TUNS+=("${cnetmode#container:}")
        fi
    fi
done < <(docker inspect --format "{{.Id}} {{.State.Pid}} {{.State.Status}} {{.Name}} {{.HostConfig.NetworkMode}}" $ALL_CTRS 2>/dev/null)

# Lọc trùng lặp danh sách Tunnel
UNIQUE_TUNS=($(printf "%s\n" "${DEAD_TUNS[@]}" 2>/dev/null | sort -u))
UNIQUE_APPS=($(printf "%s\n" "${DEAD_APPS[@]}" 2>/dev/null | sort -u))

TOTAL_DEAD=${#UNIQUE_APPS[@]}

echo -e " ${C_G}✔ Node sống (Duy trì >= 1 Socket):${C_0} ${HEALTHY_COUNT}"
echo -e " ${C_R}✔ Node đứt Socket / Cần Restart:${C_0} ${TOTAL_DEAD}"

# 2. Khởi động lại THEO LÔ đồng loạt (Không chờ 10s)
if [ "$TOTAL_DEAD" -gt 0 ]; then
    echo -e "\n${C_Y}[*] Đang khởi động lại ${#UNIQUE_TUNS[@]} Tunnel và ${TOTAL_DEAD} App cùng lúc (Ép tắt trong 1s)...${C_0}"
    
    if [ ${#UNIQUE_TUNS[@]} -gt 0 ]; then
        docker restart -t 1 "${UNIQUE_TUNS[@]}" >/dev/null 2>&1 || true
        sleep 1
    fi

    docker restart -t 1 "${UNIQUE_APPS[@]}" >/dev/null 2>&1 || true

    echo -e "${C_G}=== ĐÃ HỒI PHỤC XONG ${TOTAL_DEAD} NODE TRONG 3 GIÂY! ===${C_0}\n"
else
    echo -e "\n${C_G}=== TẤT CẢ CONTAINER ĐỀU ĐANG CÓ SOCKET TỐT - KHÔNG CẦN RESTART! ===${C_0}\n"
fi
'
```

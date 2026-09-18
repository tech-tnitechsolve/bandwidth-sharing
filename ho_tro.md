# Restart lại Traffmonetier khi thiếu device IP

```
sudo bash -c 'for c in $(docker ps --filter "name=traffmon" --format "{{.Names}}"); do docker restart "$c" >/dev/null 2>&1; echo " -> Đã làm mới: $c"; sleep 1; done'
```

# Restart lại các Container Lỗi (ko ảnh hưởng tới các container đang chạy)

```
sudo bash -c '
C_G="\033[1;32m"; C_R="\033[1;31m"; C_Y="\033[1;33m"; C_C="\033[1;36m"; C_0="\033[0m"

echo -e "\n${C_C}=================== [QUÉT & TỰ HỒI PHỤC NODE BỊ ĐƠ NGẦM / SẬP SOCKET] ===================${C_0}"
echo -e "${C_Y}[*] Đang lấy mẫu lưu lượng tức thời trong 2 giây để xác định node chết thật sự...${C_0}\n"

declare -A RX1 TX1 PIDS NAMES STATUSES
CTRS=$(docker ps -aq 2>/dev/null)

# 1. LẤY MẪU THÌ ĐIỂM T1
for cid in $CTRS; do
    cname=$(docker inspect -f "{{.Name}}" "$cid" 2>/dev/null | sed "s|^/||")
    cstatus=$(docker inspect -f "{{.State.Status}}" "$cid" 2>/dev/null || echo "unknown")
    cpid=$(docker inspect -f "{{.State.Pid}}" "$cid" 2>/dev/null || echo 0)

    [[ "$cname" =~ ^tun|^hev|^socks5|^gluetun ]] && continue

    NAMES["$cid"]="$cname"
    STATUSES["$cid"]="$cstatus"
    PIDS["$cid"]="$cpid"

    rx=0; tx=0
    if [ "$cstatus" == "running" ] && [ "$cpid" -gt 0 ] && [ -f "/proc/$cpid/net/dev" ]; then
        while IFS=": " read -r ifname rest; do
            if [[ "$ifname" =~ ^(tun0|tap0|eth0)$ ]]; then
                read -r r _ _ _ _ _ _ _ t _ <<< "$rest"
                rx=$((rx + r)); tx=$((tx + t))
            fi
        done < "/proc/$cpid/net/dev" 2>/dev/null
    fi
    RX1["$cid"]=$rx
    TX1["$cid"]=$tx
done

# Đợi 2 giây để đo biến thiên dữ liệu thực tế
sleep 2

RESTART_COUNT=0
HEALTHY_COUNT=0

# 2. ĐỐI SOÁT TẠI THỜI ĐIỂM T2
for cid in "${!NAMES[@]}"; do
    cname="${NAMES[$cid]}"
    cstatus="${STATUSES[$cid]}"
    cpid="${PIDS[$cid]}"

    # TRƯỜNG HỢP A: CONTAINER BỊ EXITED / CRASH -> BẮT BUỘC RESTART
    if [ "$cstatus" != "running" ]; then
        RESTART_COUNT=$((RESTART_COUNT + 1))
        echo -e " ${C_R}[SẬP / TẮT]${C_0} ${cname} (Trạng thái: ${cstatus^^}) -> Đang khởi động lại..."
        
        net_mode=$(docker inspect -f "{{.HostConfig.NetworkMode}}" "$cid" 2>/dev/null || echo "")
        if [[ "$net_mode" =~ ^container:(.+) ]]; then
            parent_tun="${BASH_REMATCH[1]}"
            docker restart "$parent_tun" >/dev/null 2>&1 || true
            sleep 1
        fi
        docker restart "$cid" >/dev/null 2>&1 || true
        continue
    fi

    # TRƯỜNG HỢP B: ĐANG RUNNING -> KIỂM TRA LIVE TRAFFIC & LIVE SOCKETS
    conns=0
    if [ -f "/proc/$cpid/net/tcp" ]; then
        conns=$(awk '\''$4 == "01" {c++} END {print c+0}'\'' "/proc/$cpid/net/tcp" 2>/dev/null || echo 0)
    fi

    rx2=0; tx2=0
    if [ -f "/proc/$cpid/net/dev" ]; then
        while IFS=": " read -r ifname rest; do
            if [[ "$ifname" =~ ^(tun0|tap0|eth0)$ ]]; then
                read -r r _ _ _ _ _ _ _ t _ <<< "$rest"
                rx2=$((rx2 + r)); tx2=$((tx2 + t))
            fi
        done < "/proc/$cpid/net/dev" 2>/dev/null
    fi

    delta=$(( (rx2 - RX1["$cid"]) + (tx2 - TX1["$cid"]) ))
    total_lifetime_mb=$(awk -v b="$((rx2 + tx2))" '\''BEGIN {printf "%.1f", b/1048576}'\'')

    # NẾU CÓ SOCKET ĐANG CHẠY HOẶC CÓ DATA NHẢY TRONG 2 GIÂY -> SỐNG 100% (GIỮ NGUYÊN)
    if [ "$conns" -gt 0 ] || [ "$delta" -gt 0 ]; then
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
        continue
    fi

    # NẾU 0 SOCKET VÀ 0 DATA TRONG 2S -> ĐÂY LÀ NODE BỊ ĐƠ / RỚT PROXY (BẤT KỂ TRƯỚC ĐÓ CÀY BAO NHIÊU MB)
    RESTART_COUNT=$((RESTART_COUNT + 1))
    echo -e " ${C_Y}[ĐƠ NGẦM / MẤT SOCKET]${C_0} ${cname} (Đã cày: ${total_lifetime_mb}MB | Conns: 0 | Delta: 0B) -> Đang hồi phục..."

    net_mode=$(docker inspect -f "{{.HostConfig.NetworkMode}}" "$cid" 2>/dev/null || echo "")
    if [[ "$net_mode" =~ ^container:(.+) ]]; then
        parent_tun="${BASH_REMATCH[1]}"
        docker restart "$parent_tun" >/dev/null 2>&1 || true
        sleep 1
    fi
    docker restart "$cid" >/dev/null 2>&1 || true
done

echo -e "\n${C_C}=========================================================================${C_0}"
echo -e " ${C_G}✔ Node hoạt động hoàn hảo (Không động vào):${C_0} ${HEALTHY_COUNT}"
echo -e " ${C_Y}✔ Node bị sập / đơ ngầm (Đã tự động cứu sống lại):${C_0} ${RESTART_COUNT}"
echo -e "${C_C}=========================================================================${C_0}\n"

if [ "$RESTART_COUNT" -gt 0 ]; then
    echo -e "${C_Y}[*] Đang chờ 5s để các node bắt tay lại mạng và đo kiểm tổng thể...${C_0}"
    sleep 5
    check-proxy
fi
'
```

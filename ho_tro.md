# Restart lại Traffmonetier khi thiếu device IP

```
sudo bash -c 'for c in $(docker ps --filter "name=traffmon" --format "{{.Names}}"); do docker restart "$c" >/dev/null 2>&1; echo " -> Đã làm mới: $c"; sleep 1; done'
```

# Restart lại các Container Lỗi (ko ảnh hưởng tới các container đang chạy)

```
sudo bash -c '
C_G="\033[1;32m"; C_R="\033[1;31m"; C_Y="\033[1;33m"; C_C="\033[1;36m"; C_0="\033[0m"

echo -e "\n${C_C}=================== [SIÊU TỐC: QUÉT SOCKET REAL-TIME (0.1 GIÂY)] ===================${C_0}"

NOW=$(date +%s)
RESTART_COUNT=0
HEALTHY_COUNT=0

for cid in $(docker ps -aq 2>/dev/null); do
    cname=$(docker inspect -f "{{.Name}}" "$cid" 2>/dev/null | sed "s|^/||")
    cstatus=$(docker inspect -f "{{.State.Status}}" "$cid" 2>/dev/null || echo "unknown")
    cpid=$(docker inspect -f "{{.State.Pid}}" "$cid" 2>/dev/null || echo 0)
    started_at=$(docker inspect -f "{{.State.StartedAt}}" "$cid" 2>/dev/null || echo "")

    # Bỏ qua container Tunnel Gateway
    [[ "$cname" =~ ^tun|^hev|^socks5|^gluetun ]] && continue

    # 1. Container bị tắt/exited -> Bật lại ngay
    if [ "$cstatus" != "running" ]; then
        RESTART_COUNT=$((RESTART_COUNT + 1))
        echo -e " ${C_R}[OFFLINE]${C_0} ${cname} (${cstatus^^}) -> Đang bật lại..."
        net_mode=$(docker inspect -f "{{.HostConfig.NetworkMode}}" "$cid" 2>/dev/null || echo "")
        if [[ "$net_mode" =~ ^container:(.+) ]]; then
            docker restart "${BASH_REMATCH[1]}" >/dev/null 2>&1 || true
            sleep 0.5
        fi
        docker restart "$cid" >/dev/null 2>&1 || true
        continue
    fi

    # Bỏ qua node mới khởi động dưới 15 giây (chờ app bắt tay WebSocket)
    start_ts=$(date -d "$started_at" +%s 2>/dev/null || echo "$NOW")
    uptime_sec=$(( NOW - start_ts ))
    if (( uptime_sec < 15 )); then
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
        continue
    fi

    # 2. Đếm số Socket ESTABLISHED (Mã 01 trong Kernel)
    conns=0
    if [ -f "/proc/$cpid/net/tcp" ]; then
        conns=$(awk '\''$4 == "01" {c++} END {print c+0}'\'' "/proc/$cpid/net/tcp" 2>/dev/null || echo 0)
    fi
    if [ -f "/proc/$cpid/net/tcp6" ]; then
        conns6=$(awk '\''$4 == "01" {c++} END {print c+0}'\'' "/proc/$cpid/net/tcp6" 2>/dev/null || echo 0)
        conns=$((conns + conns6))
    fi

    # 3. Phán quyết nhanh: Có Socket = Sống | 0 Socket = Chết
    if [ "$conns" -gt 0 ]; then
        HEALTHY_COUNT=$((HEALTHY_COUNT + 1))
    else
        RESTART_COUNT=$((RESTART_COUNT + 1))
        echo -e " ${C_R}[MẤT KẾT NỐI - 0 SOCKET]${C_0} ${cname} -> Đang hồi phục Tunnel & App..."
        
        net_mode=$(docker inspect -f "{{.HostConfig.NetworkMode}}" "$cid" 2>/dev/null || echo "")
        if [[ "$net_mode" =~ ^container:(.+) ]]; then
            docker restart "${BASH_REMATCH[1]}" >/dev/null 2>&1 || true
            sleep 0.5
        fi
        docker restart "$cid" >/dev/null 2>&1 || true
    fi
done

echo -e "\n${C_C}=========================================================================${C_0}"
echo -e " ${C_G}✔ Node sống (Đang duy trì >= 1 Socket):${C_0} ${HEALTHY_COUNT}"
echo -e " ${C_R}✔ Node đứt Socket (Đã tự động khởi động lại):${C_0} ${RESTART_COUNT}"
echo -e "${C_C}=========================================================================${C_0}\n"
'
```

# Restart lại Traffmonetier khi thiếu device IP

```
sudo bash -c 'for c in $(docker ps --filter "name=traffmon" --format "{{.Names}}"); do docker restart "$c" >/dev/null 2>&1; echo " -> Đã làm mới: $c"; sleep 1; done'
```

# Restart lại các Container Lỗi (ko ảnh hưởng tới các container đang chạy)

```
sudo bash -c '
C_G="\033[1;32m"; C_R="\033[1;31m"; C_Y="\033[1;33m"; C_C="\033[1;36m"; C_0="\033[0m"

echo -e "\n${C_C}=================== [KHOI PHUC RIENG CAC NODE BI LOI] ===================${C_0}"

RESTART_COUNT=0
SKIP_COUNT=0

for cid in $(docker ps -q); do
    cname=$(docker inspect -f "{{.Name}}" "$cid" 2>/dev/null | sed "s|^/||")
    cpid=$(docker inspect -f "{{.State.Pid}}" "$cid" 2>/dev/null || echo 0)

    # Bo qua container gateway tun2socks khi quet so bo
    [[ "$cname" =~ ^tun|^hev|^socks5|^gluetun ]] && continue

    # 1. Kiem tra so luong Socket dang mo
    conns=0
    if [ -f "/proc/$cpid/net/tcp" ]; then
        conns=$(awk '\''$4 == "01" {c++} END {print c+0}'\'' "/proc/$cpid/net/tcp" 2>/dev/null || echo 0)
    fi

    # 2. Kiem tra tong dung luong byte da truyen tai
    rx=0; tx=0
    if [ -f "/proc/$cpid/net/dev" ]; then
        while IFS=": " read -r ifname rest; do
            if [[ "$ifname" =~ ^(tun0|tap0|eth0)$ ]]; then
                read -r r _ _ _ _ _ _ _ t _ <<< "$rest"
                rx=$((rx + r)); tx=$((tx + t))
            fi
        done < "/proc/$cpid/net/dev" 2>/dev/null
    fi
    total_bytes=$((rx + tx))
    total_mb=$(awk -v b="$total_bytes" '\''BEGIN {printf "%.1f", b/1048576}'\'')

    # DIEU KIEN LOC AN TOAN TUYET DOI:
    # Neu Node co > 0 Socket HOAC da cay duoc >= 0.5 MB -> DANG HOAT DONG TOT -> GIU NGUYEN
    if (( conns > 0 )) || (( total_bytes > 524288 )); then
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # NEU NODE 0 SOCKET VA 0.0 MB -> XAC NHAN LA NODE LOI -> TIEN HANH RESTART
    RESTART_COUNT=$((RESTART_COUNT + 1))
    echo -e " ${C_R}[!] PHAT HIEN NODE LOI #${RESTART_COUNT}:${C_0} ${cname} (Data: ${total_mb}MB | Conns: ${conns})"

    net_mode=$(docker inspect -f "{{.HostConfig.NetworkMode}}" "$cid" 2>/dev/null || echo "")
    if [[ "$net_mode" =~ ^container:(.+) ]]; then
        parent_tun="${BASH_REMATCH[1]}"
        echo -e "     -> ${C_Y}Restart Gateway Tunnel:${C_0} $parent_tun"
        docker restart "$parent_tun" >/dev/null 2>&1 || true
        sleep 1
    fi

    echo -e "     -> ${C_G}Restart Container App:${C_0} $cname"
    docker restart "$cid" >/dev/null 2>&1 || true
    echo ""
done

echo -e "${C_C}=========================================================================${C_0}"
echo -e " ${C_G}✔ Da giu nguyen:${C_0} ${SKIP_COUNT} container dang chay tot 100%"
echo -e " ${C_Y}✔ Da khoi dong lai:${C_0} ${RESTART_COUNT} container bi loi socket/0MB"
echo -e "${C_C}=========================================================================${C_0}\n"

if (( RESTART_COUNT > 0 )); then
    echo -e "${C_Y}[*] Dang doi 5 giay de cac node ket noi lai roi do kiem...${C_0}"
    sleep 5
    check-proxy
fi
'
```

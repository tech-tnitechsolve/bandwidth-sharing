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

# Update Docker Traffmonetizer an toàn nhất 

```
sudo update-traffmonetizer
```

```
cat << 'EOF' | sudo bash
set -uo pipefail

# 1. Tạo script cập nhật chuẩn hóa
cat << 'EOSCRIPT' > /usr/local/bin/update-traffmonetizer
#!/usr/bin/env bash
set -uo pipefail

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

echo -e "\n${C_B}========================================================================${C_0}"
echo -e "${C_B} [TRAFFMONETIZER] QUY TRÌNH NÂNG CẤP CUỐN CHIẾU AN TOÀN 2026 (MULTI-FOLDER)${C_0}"
echo -e "${C_B}========================================================================${C_0}"

# 1.1 Xác định CPU & Kéo bản build mới nhất (Duy nhất 1 lần ~1.4MB)
CPU_ARCH=$(uname -m)
case "$CPU_ARCH" in
  aarch64|arm64) TM_IMG="traffmonetizer/cli_v2:arm64v8" ;;
  armv7l)        TM_IMG="traffmonetizer/cli_v2:arm32v7" ;;
  *)             TM_IMG="traffmonetizer/cli_v2:latest" ;;
esac

echo -e "\n${C_Y}==> [1/5] Dang pull image moi nhat (${TM_IMG}) - Tieu ton ~1.4MB...${C_0}"
if ! docker pull "$TM_IMG"; then
  echo -e "${C_R}[XX] Loi ket noi mang, khong the pull image. Vui long thu lai!${C_0}"
  exit 1
fi

# 1.2 Quét toàn bộ container TraffMonetizer trên mọi folder
CTR_IDS=($(docker ps -a --filter "name=^traffmon" --format "{{.ID}}"))
TOTAL=${#CTR_IDS[@]}

if (( TOTAL == 0 )); then
  echo -e "\n${C_Y}[!] Khong tim thay container TraffMonetizer nao tren VPS/VM.${C_0}"
  exit 0
fi

echo -e "${C_G}[OK] Phat hien $TOTAL container TraffMonetizer tren toan bo he thong.${C_0}"
echo -e "${C_Y}==> [2/5] Bat dau cap nhat cuon chieu (Staggered Rolling Update)...${C_0}\n"

SUCCESS=0
FAILED=0

for (( i=0; i<TOTAL; i++ )); do
  cid="${CTR_IDS[$i]}"
  IDX=$(( i + 1 ))

  # Kiểm soát RAM động: Nếu RAM trống < 200MB thì hãm phanh để ZRAM nén
  RAM_AVAIL_MB=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 500)
  if (( RAM_AVAIL_MB < 200 )); then
    echo -e "      ${C_Y}[CANH BAO: RAM con ${RAM_AVAIL_MB}MB] Tam dung 3s giai phong cache...${C_0}"
    sync
    echo 1 > /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 3
  fi

  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  netmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid" 2>/dev/null || echo "")
  src_vol=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/.config/traffmonetizer"}}{{.Source}}{{end}}{{end}}' "$cid" 2>/dev/null || echo "")
  dns_vol=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/resolv.conf"}}{{.Source}}{{end}}{{end}}' "$cid" 2>/dev/null || echo "")
  cmd_args=$(docker inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' "$cid" 2>/dev/null || echo "")

  printf "  -> [%3d/%-3d] Node: %-26s " "$IDX" "$TOTAL" "$cname"

  # Kiểm tra Proxy Tunnel tương ứng nếu chạy mode container:tun...
  if [[ "$netmode" =~ ^container:(.+) ]]; then
    target_tun="${BASH_REMATCH[1]}"
    tun_running=$(docker inspect -f '{{.State.Running}}' "$target_tun" 2>/dev/null || echo "false")
    if [[ "$tun_running" != "true" ]]; then
      docker start "$target_tun" >/dev/null 2>&1 || true
      sleep 0.5
    fi
  fi

  # Dừng lịch sự (timeout 2s) để ngắt TCP socket êm ái
  docker stop -t 2 "$cid" >/dev/null 2>&1 || true
  docker rm "$cid" >/dev/null 2>&1 || true

  # Ráp các volume mount bảo đảm an toàn dữ liệu đa folder
  MOUNT_PARAMS=""
  if [[ -n "$src_vol" && -d "$src_vol" ]]; then
    MOUNT_PARAMS="$MOUNT_PARAMS --mount type=bind,source=$src_vol,target=/.config/traffmonetizer"
  fi
  if [[ -n "$dns_vol" && -f "$dns_vol" ]]; then
    MOUNT_PARAMS="$MOUNT_PARAMS --mount type=bind,source=$dns_vol,target=/etc/resolv.conf,readonly"
  fi

  NET_PARAM=""
  if [[ -n "$netmode" ]]; then
    NET_PARAM="--network=$netmode"
  fi

  if docker run -d \
      --name "$cname" \
      --restart=unless-stopped \
      $NET_PARAM \
      $MOUNT_PARAMS \
      "$TM_IMG" $cmd_args >/dev/null 2>&1; then
    echo -e "${C_G}[OK]${C_0}"
    SUCCESS=$((SUCCESS + 1))
  else
    echo -e "${C_R}[LOI]${C_0}"
    FAILED=$((FAILED + 1))
  fi

  # Nghỉ 0.5s giữa các node để tránh bão CPU và sốc Proxy
  sleep 0.5

  # Sau mỗi cụm 10 node, nghỉ 2s để xả tải kết nối
  if (( IDX % 10 == 0 && IDX < TOTAL )); then
    echo -e "      ${C_C}>> Da cap nhat 10 node. Nghi 2s de ha nhiet Proxy & CPU...${C_0}"
    sleep 2
  fi
done

# 1.3 Dọn dẹp layer image cũ
echo -e "\n${C_Y}==> [3/5] Don dep layer image cu (Dangling images)...${C_0}"
docker image prune -f >/dev/null 2>&1 || true

# 1.4 Khóa hạn mức tài nguyên thông qua ii-autosync
echo -e "${C_Y}==> [4/5] Kich hoat ii-autosync de ap Memory Reservation & Limits...${C_0}"
if [[ -x /usr/local/bin/ii-autosync.sh ]]; then
  /usr/local/bin/ii-autosync.sh >/dev/null 2>&1 || true
elif [[ -x /usr/bin/ii-autosync ]]; then
  /usr/bin/ii-autosync >/dev/null 2>&1 || true
fi

# 1.5 Kiểm tra hoạt động thực tế
echo -e "${C_Y}==> [5/5] Kiem tra trang thai ket noi cua node ngau nhien:${C_0}"
sleep 2
SAMPLE_CTR=$(docker ps -q --filter "name=^traffmon" | head -n 1)
if [[ -n "$SAMPLE_CTR" ]]; then
  SAMPLE_NAME=$(docker inspect -f '{{.Name}}' "$SAMPLE_CTR" | sed 's|^/||')
  echo -e "--- [Log mau: ${C_G}${SAMPLE_NAME}${C_0}] ---"
  docker logs --tail 6 "$SAMPLE_CTR" || true
  echo "--------------------------------------------------------"
fi

echo -e "\n${C_B}========================================================================${C_0}"
echo -e "${C_G} [HOÀN TẤT] THÀNH CÔNG: ${SUCCESS}/${TOTAL} node. LỖI: ${FAILED} node.${C_0}"
echo -e "${C_B} Toàn bộ node TraffMonetizer trên mọi folder đã lên bản build mới nhất!${C_0}"
echo -e "${C_B}========================================================================${C_0}\n"
EOSCRIPT

chmod +x /usr/local/bin/update-traffmonetizer
ln -sf /usr/local/bin/update-traffmonetizer /usr/bin/update-traffmonetizer 2>/dev/null || true

# 2. Thực thi ngay lập tức
/usr/local/bin/update-traffmonetizer
EOF
```

# LỆNH KIỂM TRA TỰ ĐỘNG TOÀN DIỆN (CHẠY 1 PHÁT RA TẤT CẢ)

```
cat << 'EOF' | bash
echo "==================== [BẢNG TỔNG KẾT SỨC KHỎE TRAFFMONETIZER] ===================="
TOTAL=$(docker ps -aq --filter "name=^traffmon" | wc -l)
RUNNING=$(docker ps -q --filter "name=^traffmon" | wc -l)
CONNECTED=$(docker ps -q --filter "name=^traffmon" | xargs -I {} docker logs --tail 15 {} 2>&1 | grep -c "Connected: True" || echo 0)

echo "  - Tổng số container TraffMonetizer : $TOTAL"
echo "  - Số container đang chạy (Running) : $RUNNING / $TOTAL"
echo "  - Số node ghi nhận kết nối máy chủ : $CONNECTED log xác nhận"

if (( RUNNING == TOTAL && TOTAL > 0 )); then
  echo -e "\n \033[1;32m===> KẾT LUẬN: 100% NODE ĐÃ LÊN BẢN MỚI VÀ HOẠT ĐỘNG HOÀN HẢO!\033[0m"
else
  echo -e "\n \033[1;33m===> KẾT LUẬN: Đang có $((TOTAL - RUNNING)) node chưa chạy. Hãy kiểm tra lại tunnel proxy.\033[0m"
fi
echo "=================================================================================="
EOF
```

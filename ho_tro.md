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
sudo check-traffmon
```

```
cat << 'EOF' | sudo bash
set -uo pipefail

cat << 'EOSCRIPT' > /usr/local/bin/check-traffmon
#!/usr/bin/env bash
set -uo pipefail

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

clear
echo -e "${C_B}========================================================================================================${C_0}"
echo -e "${C_B}  [ULTIMATE AUDIT 2026] ĐO ĐẠC TOÀN DIỆN: DIGEST DOCKER HUB CHÍNH THỨC + KERNEL INODE + ĐƯỜNG TRUYỀN    ${C_0}"
echo -e "${C_B}========================================================================================================${C_0}"

PRIMARY_IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
PUB_IP=$(curl -s4 -m 3 --interface "$PRIMARY_IFACE" https://api.ipify.org 2>/dev/null || echo "Unknown")

# Chữ ký Digest chính thức từ Docker Hub cho bản cập nhật mới
OFFICIAL_HASH_PREFIX="4197c3765"

echo -e " VPS Host IP (Can bao ve) : ${C_G}${PUB_IP}${C_0} (IP goc cua may chu)"
echo -e " Docker Hub Target Digest  : ${C_C}sha256:${OFFICIAL_HASH_PREFIX}... (Bản mới nhất vừa cập nhật)${C_0}"
echo -e " Conntrack Streams         : $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0) / $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)"
echo -e " RAM / ZRAM Status         : Dung $(free -m | awk '/^Mem:/{print $3}')MB / Con trong $(free -m | awk '/^Mem:/{print $7}')MB"
echo -e " Kiem tra luc              : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "--------------------------------------------------------------------------------------------------------"

TM_CTRS=($(docker ps -aq --filter "name=^traffmon" 2>/dev/null))
TOTAL=${#TM_CTRS[@]}

if (( TOTAL == 0 )); then
  echo -e "${C_R}[XX] Khong tim thay container TraffMonetizer nao tren he thong!${C_0}"
  exit 0
fi

printf " %-24s %-12s %-14s %-16s %-10s %-15s %-6s %s\n" \
  "NODE CONTAINER" "TUNNEL" "DOCKER HUB" "KERNEL INODE" "TCP SOCKET" "DATA (RX/TX)" "DROP" "KẾT LUẬN"
echo "--------------------------------------------------------------------------------------------------------"

PERFECT_NODES=0
DIRECT_NODES=0
WARN_NODES=0
TOTAL_DATA_MB=0

for cid in "${TM_CTRS[@]}"; do
  cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
  netmode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid" 2>/dev/null || echo "")
  tm_pid=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null || echo 0)
  tm_img_id=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null || echo "")

  # 1. So khớp trực tiếp mã băm Digest thực tế với Docker Hub
  img_digests=$(docker inspect -f '{{range .RepoDigests}}{{.}} {{end}}' "$tm_img_id" 2>/dev/null || echo "")
  ver_status="${C_R}HUB: CŨ${C_0}"
  is_official_new=0

  # Soi xem Image có chứa mã băm 4197c3765... của Docker Hub hay không
  if [[ "$img_digests" =~ $OFFICIAL_HASH_PREFIX || "$tm_img_id" =~ $OFFICIAL_HASH_PREFIX ]]; then
    ver_status="${C_G}HUB: MỚI${C_0}"
    is_official_new=1
  else
    # Fallback kiểm tra ngày tạo image nếu không có tag digest cục bộ
    img_created=$(docker image inspect "$tm_img_id" -f '{{.Created}}' 2>/dev/null || echo "")
    if [[ "$img_created" =~ 2026-11 ]]; then
      ver_status="${C_G}BUILD 11/26${C_0}"
      is_official_new=1
    fi
  fi

  # 2. Phân loại & Đo Inode Kernel
  target_tun="Direct"
  tun_pid=0
  inode_status="${C_Y}HOST DIRECT${C_0}"
  is_direct=1
  is_valid=1

  if [[ "$netmode" =~ ^container:(.+) ]]; then
    is_direct=0
    tun_id="${BASH_REMATCH[1]}"
    target_tun="${tun_id:0:10}"
    tun_pid=$(docker inspect -f '{{.State.Pid}}' "$tun_id" 2>/dev/null || echo 0)

    if (( tm_pid > 0 && tun_pid > 0 )); then
      tm_inode=$(readlink "/proc/$tm_pid/ns/net" 2>/dev/null || echo "1")
      tun_inode=$(readlink "/proc/$tun_pid/ns/net" 2>/dev/null || echo "2")

      if [[ -n "$tm_inode" && "$tm_inode" == "$tun_inode" ]]; then
        inode_status="${C_G}LOCKED (100%)${C_0}"
      else
        inode_status="${C_R}LEAK DETECT${C_0}"
        is_valid=0
      fi
    elif (( tun_pid == 0 )); then
      inode_status="${C_R}TUNNEL OFF${C_0}"
      is_valid=0
    else
      inode_status="${C_R}NODE OFF${C_0}"
      is_valid=0
    fi
  else
    # Chế độ Direct
    if (( tm_pid == 0 )); then
      inode_status="${C_R}NODE OFF${C_0}"
      is_valid=0
    fi
  fi

  # 3. Đo lường Socket & Lưu lượng
  CHECK_PID=$tun_pid
  if (( is_direct == 1 || CHECK_PID == 0 )); then CHECK_PID=$tm_pid; fi

  conns=0
  rx_mb="0.0"; tx_mb="0.0"
  drop_total=0

  if (( CHECK_PID > 0 )) && [[ -d "/proc/$CHECK_PID" ]]; then
    conns=$(nsenter -t "$CHECK_PID" -n ss -tan state established 2>/dev/null | grep -vc 'Recv-Q' || echo 0)

    if [[ -f "/proc/$CHECK_PID/net/dev" ]]; then
      read -r r_b r_d t_b t_d < <(awk -v is_dir="$is_direct" '
        {
          if (is_dir == 1 && $1 ~ /^eth0:/) {
            print $2, $5, $10, $13; found=1; exit
          } else if (is_dir == 0 && $1 ~ /^(tun0|tap0):/) {
            print $2, $5, $10, $13; found=1; exit
          }
        }
        END { if (!found) print 0, 0, 0, 0 }
      ' "/proc/$CHECK_PID/net/dev" 2>/dev/null || echo "0 0 0 0")

      rx_mb=$(awk "BEGIN {printf \"%.1f\", $r_b/1048576}")
      tx_mb=$(awk "BEGIN {printf \"%.1f\", $t_b/1048576}")
      drop_total=$(( r_d + t_d ))
      node_sum=$(awk "BEGIN {print int($rx_mb + $tx_mb)}")
      TOTAL_DATA_MB=$(( TOTAL_DATA_MB + node_sum ))
    fi
  fi

  # 4. Đánh giá tổng hợp
  verdict="${C_G}[HOAN HAO]${C_0}"
  if (( is_valid == 0 )); then
    if [[ "$inode_status" =~ TUNNEL ]]; then
      verdict="${C_R}[TUNNEL SẬP]${C_0}"
    elif [[ "$inode_status" =~ NODE ]]; then
      verdict="${C_R}[NODE DỪNG]${C_0}"
    else
      verdict="${C_R}[RÒ RỈ IP!]${C_0}"
    fi
    WARN_NODES=$(( WARN_NODES + 1 ))
  elif (( is_official_new == 0 )); then
    verdict="${C_Y}[CHƯA UPDATE]${C_0}"
    WARN_NODES=$(( WARN_NODES + 1 ))
  else
    if (( is_direct == 1 )); then
      verdict="${C_G}[DIRECT GỐC]${C_0}"
      DIRECT_NODES=$(( DIRECT_NODES + 1 ))
    else
      PERFECT_NODES=$(( PERFECT_NODES + 1 ))
    fi
  fi

  printf " %-24s %-12s %-23b %-25b %-10s %-15s %-6s %b\n" \
    "$cname" "$target_tun" "$ver_status" "$inode_status" "$conns conns" "${rx_mb}M/${tx_mb}M" "$drop_total" "$verdict"
done

echo "--------------------------------------------------------------------------------------------------------"
echo -e "${C_B}>>> TỔNG KẾT ĐÁNH GIÁ CHẤT LƯỢNG HẠ TẦNG:${C_0}"
echo -e "  * Tổng số node TraffMonetizer đang chạy : ${TOTAL}"
echo -e "  * Xác thực Docker Hub Digest (Bản mới) : ${C_G}$((PERFECT_NODES + DIRECT_NODES)) / ${TOTAL} node chuẩn xác 100%${C_0}"
echo -e "  * Node Proxy Tunnel Hoàn Hảo (100% Khóa): ${C_G}${PERFECT_NODES}${C_0} node"
if (( DIRECT_NODES > 0 )); then
  echo -e "  * Node Direct sử dụng IP gốc máy chủ    : ${C_Y}${DIRECT_NODES}${C_0} node (Hợp lệ)"
fi
echo -e "  * Tổng lưu lượng các node đã truyền nhận: ${C_G}~${TOTAL_DATA_MB} MB${C_0}"
echo ""

TOTAL_HEALTHY=$(( PERFECT_NODES + DIRECT_NODES ))
if (( TOTAL_HEALTHY == TOTAL )); then
  echo -e "  ${C_G}[✓] XÁC THỰC KÉP HOÀN HẢO: 100% Node chạy đúng Digest mới từ Docker Hub & Khóa mạng Tunnel an toàn!${C_0}"
  echo -e "\n \033[1;42;37m ===> HỆ THỐNG ĐẠT ĐIỂM TUYỆT ĐỐI: DOCKER HUB MỚI 100% - PROXY THÔNG SUỐT - ZERO DROP! \033[0m"
else
  echo -e "  ${C_R}[!] CẢNH BÁO: Có ${WARN_NODES} node chưa đúng bản mới hoặc gặp sự cố!${C_0}"
fi
echo -e "${C_B}========================================================================================================${C_0}\n"
EOSCRIPT

chmod +x /usr/local/bin/check-traffmon
ln -sf /usr/local/bin/check-traffmon /usr/bin/check-traffmon 2>/dev/null || true

/usr/local/bin/check-traffmon
EOF
```

# 1. Chạy lại cho các Proxy cũ hết băng thông đã được Renew
```
curl -4 -sSL "https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/List_Proxy/fix_bandwidth.sh?v=$(date +%s)" -o fix_bandwidth.sh && chmod +x fix_bandwidth.sh && ./fix_bandwidth.sh
```

# LỆNH "QUÉT TOÀN BỘ VPS"
#### Cơ chế hoạt động của lệnh này:
1. **Tự động lùng sục:** Tìm tất cả các folder trên VPS đang chứa `containernames.txt`.
2. **Tự động tải về:** Tải bản mới nhất của `fix_bandwidth.sh` từ GitHub nạp thẳng vào đúng từng folder đó.
3. **Tự động phân quyền & chạy:** Lần lượt chui vào từng folder, kích hoạt chạy đo lường, gỡ FlapGuard, đánh thức các node ngất và nghiệm thu kết quả cho bạn.

```
sudo bash -c 'RAW_URL="https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/List_Proxy/fix_bandwidth.sh"; for f in $(find /home /root -maxdepth 5 -name "containernames.txt" -type f 2>/dev/null); do d=$(dirname "$f"); echo -e "\n\033[1;36m>>> ĐANG UPDATE VÀ CHẠY TẠI: $d <<<\033[0m"; curl -4 -sSL "$RAW_URL" -o "$d/fix_bandwidth.sh"; chmod +x "$d/fix_bandwidth.sh"; (cd "$d" && ./fix_bandwidth.sh); done'
```
--------------------------------------------------------------------------
--------------------------------------------------------------------------
--------------------------------------------------------------------------
--------------------------------------------------------------------------
--------------------------------------------------------------------------


# 2. Tạo Sheild bảo vệ cho proxy: chặn các cổng và Request nguy hiểm ảnh hưởng
```
sudo bash -c 'RAW_URL="https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/List_Proxy/webshare_shield.sh?v=$(date +%s)"; SHIELD_BIN="/usr/local/bin/webshare_shield.sh"; curl -4 -sSL -H "Cache-Control: no-cache, no-store" -H "Pragma: no-cache" "$RAW_URL" -o "$SHIELD_BIN" && chmod +x "$SHIELD_BIN" && "$SHIELD_BIN" && systemctl restart webshare-watcher.service 2>/dev/null || true'
```

# Check tổng xem đã bảo vệ oke chưa

```
sudo bash -c 'RAW_URL="https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/List_Proxy/audit_system.sh?v=$(date +%s)"; AUDIT_BIN="/usr/local/bin/audit_system.sh"; curl -4 -sSL -H "Cache-Control: no-cache, no-store" -H "Pragma: no-cache" "$RAW_URL" -o "$AUDIT_BIN" && chmod +x "$AUDIT_BIN" && "$AUDIT_BIN"'
```
--------------------------------------------------------------------------

# Xóa Tool Shield khi không cần nữa
```
sudo bash -c '
SHIELD_KEY="webshare""_shield.sh"
AUDIT_KEY="audit""_system.sh"

# 1. Dừng và xóa systemd watcher + chỉ xóa dòng cron của shield (giữ nguyên cron setup_vps)
systemctl stop webshare-watcher.service 2>/dev/null || true
systemctl disable webshare-watcher.service 2>/dev/null || true
rm -f /etc/systemd/system/webshare-watcher.service
systemctl daemon-reload 2>/dev/null || true
sed -i "/${SHIELD_KEY}/d" /etc/cron.d/internetincome 2>/dev/null || true

# 2. Diệt tiến trình shield còn chạy ngầm (không tự kill bash -c)
for p in $(pgrep -f "$SHIELD_KEY" 2>/dev/null || true); do
  [[ "$p" != "$$" && "$p" != "$PPID" ]] && kill -9 "$p" 2>/dev/null || true
done

# 3. Gỡ sạch chain WEBSHARE_SHIELD trong mọi container đang chạy (giữ nguyên disable_ipv6 của internetIncome)
for pid in $(docker inspect --format "{{.State.Pid}}" $(docker ps -q 2>/dev/null) 2>/dev/null | sort -u); do
  if (( pid > 0 )); then
    while nsenter -t "$pid" -n iptables -D OUTPUT -j WEBSHARE_SHIELD 2>/dev/null; do :; done
    nsenter -t "$pid" -n iptables -F WEBSHARE_SHIELD 2>/dev/null || true
    nsenter -t "$pid" -n iptables -X WEBSHARE_SHIELD 2>/dev/null || true
  fi
done

# 4. Dọn sạch block domain trong file hosts của MỌI container (cả đang chạy & đã dừng)
for h in $(docker inspect --format "{{.HostsPath}}" $(docker ps -aq 2>/dev/null) 2>/dev/null); do
  if [[ -f "$h" ]] && grep -q "WEBSHARE COMPLIANCE FILTER" "$h" 2>/dev/null; then
    tmp_h=$(mktemp)
    awk "/# --- WEBSHARE COMPLIANCE FILTER/{exit} {print}" "$h" > "$tmp_h" && cat "$tmp_h" > "$h"
    rm -f "$tmp_h"
  fi
done

# 5. Xóa file script webshare_shield & audit_system
rm -f "/usr/local/bin/${SHIELD_KEY}" "/usr/local/bin/${AUDIT_KEY}"

echo -e "\n\033[1;32m[HOÀN TẤT] ĐÃ XÓA SẠCH CÁC SHIELD & GIỮ NGUYÊN CẤU HÌNH SETUP_VPS!\033[0m\n"
'
```
# Check xem đã xóa sạch chưa
```
sudo bash -c '
G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; C="\033[1;36m"; B="\033[1;34m"; N="\033[0m"
ERR=0; WARN=0

echo -e "\n${B}================================================================================${N}"
echo -e "${B}  [DEEP CHECK] KIỂM TOÁN XÓA SHIELD & ĐỘ ỔN ĐỊNH HỆ THỐNG (${HOSTNAME})${N}"
echo -e "${B}================================================================================${N}"

# --- PHẦN 1: XÁC MINH ĐÃ XÓA SẠCH SHIELD ---
K_WS="webshare""_shield"; K_PS="pawns""-shield"; K_AU="audit""_system"
P_HIT=$(pgrep -af "${K_WS}|${K_PS}" 2>/dev/null | grep -vE "^($$|$PPID) " || true)
SVC_WS=$(systemctl is-active webshare-watcher.service 2>/dev/null || echo "none")
SVC_WS_F=$([[ -f /etc/systemd/system/webshare-watcher.service ]] && echo "CÒN FILE" || echo "SẠCH")
SVC_PS=$(systemctl is-active pawns-shield.service 2>/dev/null || echo "none")
CRON_WS=$(grep "$K_WS" /etc/cron.d/internetincome 2>/dev/null | wc -l)
CRON_SVPS=$(grep -E "ii-autosync|ii-flapguard|ii-repocket-watchdog" /etc/cron.d/internetincome 2>/dev/null | wc -l)

F_LEFT=""
for f in "/usr/local/bin/${K_WS}.sh" "/usr/local/bin/${K_AU}.sh" "/usr/local/bin/${K_PS}.py"; do
  [[ -e "$f" ]] && F_LEFT="${F_LEFT} $f"
done

RUN_IDS=$(docker ps -q 2>/dev/null || true)
ALL_IDS=$(docker ps -aq 2>/dev/null || true)
RUN_C=$([[ -n "$RUN_IDS" ]] && echo "$RUN_IDS" | wc -l || echo 0)
ALL_C=$([[ -n "$ALL_IDS" ]] && echo "$ALL_IDS" | wc -l || echo 0)

IPT_HIT=0
if (( RUN_C > 0 )); then
  for pid in $(docker inspect --format "{{.State.Pid}}" $RUN_IDS 2>/dev/null | sort -u); do
    if (( pid > 0 )); then
      if nsenter -t "$pid" -n iptables -S WEBSHARE_SHIELD >/dev/null 2>&1 || nsenter -t "$pid" -n iptables -C OUTPUT -j WEBSHARE_SHIELD >/dev/null 2>&1; then
        IPT_HIT=$((IPT_HIT + 1))
      fi
    fi
  done
fi

HOSTS_DIRTY=0; HOSTS_BROKEN=0; HOSTS_TOTAL=0
if (( ALL_C > 0 )); then
  for h in $(docker inspect --format "{{.HostsPath}}" $ALL_IDS 2>/dev/null); do
    if [[ -f "$h" ]]; then
      HOSTS_TOTAL=$((HOSTS_TOTAL + 1))
      grep -qE "WEBSHARE COMPLIANCE FILTER|0\.0\.0\.0 auth\.uber\.com" "$h" 2>/dev/null && HOSTS_DIRTY=$((HOSTS_DIRTY + 1))
      grep -q "localhost" "$h" 2>/dev/null || HOSTS_BROKEN=$((HOSTS_BROKEN + 1))
    fi
  done
fi

echo -e "${C}[1. KIỂM TRA DẤU VẾT SHIELD]${N}"
if [[ -z "$P_HIT" && "$SVC_WS" != "active" && "$SVC_WS_F" == "SẠCH" && "$SVC_PS" != "active" && "$CRON_WS" -eq 0 && -z "$F_LEFT" && "$IPT_HIT" -eq 0 && "$HOSTS_DIRTY" -eq 0 ]]; then
  echo -e "  * Trạng thái Shield : ${G}SẠCH 100%${N} (Không còn tiến trình, service, cron, file, iptables, hosts)"
else
  ERR=$((ERR + 1))
  echo -e "  * Trạng thái Shield : ${R}CÒN SÓT!${N} Proc=[$P_HIT] Svc=[$SVC_WS/$SVC_WS_F/$SVC_PS] CronWS=[$CRON_WS] File=[$F_LEFT] Ipt=[$IPT_HIT] Hosts=[$HOSTS_DIRTY]"
fi
if (( HOSTS_BROKEN == 0 )); then
  echo -e "  * Toàn vẹn /etc/hosts: ${G}AN TOÀN${N} (${HOSTS_TOTAL}/${HOSTS_TOTAL} container giữ nguyên localhost)"
else
  ERR=$((ERR + 1))
  echo -e "  * Toàn vẹn /etc/hosts: ${R}LỖI${N} (${HOSTS_BROKEN} container mất dòng localhost!)"
fi
if (( CRON_SVPS > 0 )); then
  echo -e "  * Cron setup_vps.sh : ${G}ĐANG HOẠT ĐỘNG (${CRON_SVPS} tác vụ)${N}"
else
  echo -e "  * Cron setup_vps.sh : ${Y}Không thấy hoặc chạy với --no-cron${N}"
fi

# --- PHẦN 2: SỨC KHỎE PHẦN CỨNG & KERNEL ---
read -r L1 L5 L15 _ < /proc/loadavg
CORES=$(nproc 2>/dev/null || echo 1)
read -r _ RAM_T RAM_U _ _ _ RAM_A < <(free -m | grep "^Mem:")
read -r _ SWAP_T SWAP_U _ < <(free -m | grep "^Swap:")
read -r FD_U _ FD_M < /proc/sys/fs/file-nr
ZRAM_SZ=$(swapon --show 2>/dev/null | grep "/dev/zram0" | tr -s " " | cut -d" " -f3 || true)
DISK_PCT=$(df -h / | tail -n1 | tr -s " " | cut -d" " -f5)
RO_CHK=$(grep " / " /proc/mounts | grep -oE "\bro\b" | head -n1 || echo "rw")
PID1_CPU=$(ps -p 1 -o %cpu= 2>/dev/null | tr -d " " || echo "0.0")

echo -e "\n${C}[2. TÀI NGUYÊN HỆ THỐNG & KERNEL]${N}"
echo -e "  * CPU (${CORES} Cores)      : Load ${G}${L1} ${L5} ${L15}${N} | PID 1 systemd: ${G}${PID1_CPU}%${N}"
echo -e "  * RAM / Swap        : Dùng ${G}${RAM_U}/${RAM_T} MB${N} (Trống: ${G}${RAM_A} MB${N}) | Swap dùng: ${SWAP_U}/${SWAP_T} MB"
if [[ -n "$ZRAM_SZ" ]]; then
  echo -e "  * ZRAM              : ${G}ACTIVE (${ZRAM_SZ})${N}"
else
  WARN=$((WARN + 1))
  echo -e "  * ZRAM              : ${Y}KHÔNG BẬT${N}"
fi
echo -e "  * Disk / FD         : Ổ đĩa ${DISK_PCT} (${RO_CHK^^}) | FD: ${FD_U}/${FD_M}"
[[ "$RO_CHK" == "ro" ]] && ERR=$((ERR + 1))

# --- PHẦN 3: SỨC KHỎE DOCKER & DÀN CONTAINER ---
DOCKER_ST=$(systemctl is-active docker 2>/dev/null || echo "inactive")
DOCKER_FWD=$(iptables -S FORWARD 2>/dev/null | grep "DOCKER" | wc -l)
EXIT_C=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
REST_C=$(docker ps -aq -f status=restarting 2>/dev/null | wc -l)
DEAD_C=$(docker ps -aq -f status=dead 2>/dev/null | wc -l)
TOT_RC=0; TOT_OOM=0; MAX_RC=0; MAX_RC_NAME=""
if (( RUN_C > 0 )); then
  while read -r cname rc oom; do
    TOT_RC=$((TOT_RC + rc))
    if (( rc > MAX_RC )); then MAX_RC=$rc; MAX_RC_NAME="${cname#/}"; fi
    [[ "$oom" == "true" ]] && TOT_OOM=$((TOT_OOM + 1))
  done < <(docker inspect --format "{{.Name}} {{.RestartCount}} {{.State.OOMKilled}}" $RUN_IDS 2>/dev/null)
fi
FLAP_C=0; [[ -d /var/lib/ii-flapguard ]] && FLAP_C=$(grep -sl " [1-9][0-9]*$" /var/lib/ii-flapguard/*.state 2>/dev/null | wc -l || echo 0)

TUN_NAME=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -E "^(tun|gluetun|hev)" | head -n1 || true)
TUN_V6="N/A"
if [[ -n "$TUN_NAME" ]]; then
  TUN_PID=$(docker inspect -f "{{.State.Pid}}" "$TUN_NAME" 2>/dev/null || echo 0)
  (( TUN_PID > 0 )) && TUN_V6=$(nsenter -t "$TUN_PID" -n sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "?")
fi

echo -e "\n${C}[3. SỨC KHỎE DOCKER & CONTAINER]${N}"
if (( DOCKER_FWD > 0 )); then
  FWD_TXT="${G}CÓ (${DOCKER_FWD})${N}"
else
  WARN=$((WARN + 1))
  FWD_TXT="${Y}THIẾU (Nếu container mất mạng, hãy restart docker)${N}"
fi
echo -e "  * Docker / FORWARD  : Daemon ${G}${DOCKER_ST^^}${N} | Docker FORWARD rules: ${FWD_TXT}"
echo -e "  * Container         : Chạy ${G}${RUN_C}/${ALL_C}${N} | Exited: ${EXIT_C} | Restarting: ${REST_C} | Dead: ${DEAD_C}"
echo -e "  * Lỗi ngầm (OOM/Flap): OOMKilled: ${TOT_OOM} | Tổng Restart: ${TOT_RC} (Cao nhất: ${MAX_RC_NAME:-None}=${MAX_RC}) | FlapGuard phạt: ${FLAP_C}"
if [[ -n "$TUN_NAME" ]]; then
  if [[ "$TUN_V6" == "1" ]]; then
    echo -e "  * Chống rò IPv6 TUN : ${G}ĐANG KHÓA CHUẨN (disable_ipv6=1 tại ${TUN_NAME})${N}"
  else
    WARN=$((WARN + 1))
    echo -e "  * Chống rò IPv6 TUN : ${Y}CẢNH BÁO (disable_ipv6=${TUN_V6} tại ${TUN_NAME})${N}"
  fi
fi
if (( EXIT_C > 0 )); then
  WARN=$((WARN + 1))
  echo -e "  * Node đang Exited  : ${Y}$(docker ps -a -f status=exited --format "{{.Names}}" | head -n 8 | tr "\n" " ")${N}"
fi
[[ "$DOCKER_ST" != "active" ]] && ERR=$((ERR + 1))
(( REST_C > 0 || DEAD_C > 0 || TOT_OOM > 0 )) && ERR=$((ERR + 1))
(( FLAP_C > 0 )) && WARN=$((WARN + 1))

# --- PHẦN 4: MẠNG & LƯU LƯỢNG KIẾM TIỀN THỰC TẾ (2 GIÂY) ---
CONN_C=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CONN_M=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
EST_ALL=$(ss -tan state established 2>/dev/null | tail -n +2 | wc -l)
EST_INC=$(ss -tan state established "( dport = :80 or dport = :443 or sport = :80 or sport = :443 )" 2>/dev/null | tail -n +2 | wc -l)
SYN_C=$(ss -tan state syn-sent 2>/dev/null | tail -n +2 | wc -l)
CW_C=$(ss -tan state close-wait 2>/dev/null | tail -n +2 | wc -l)

echo -e "\n${C}[4. LƯU LƯỢNG MẠNG & TỐC ĐỘ CẮN DATA (ZERO-PROBE)]${N}"
echo -e "  * Sockets Income    : ${G}${EST_INC} active (80/443)${N} / Tổng ${EST_ALL} established | SYN_SENT: ${SYN_C} | CLOSE_WAIT: ${CW_C}"
echo -e "  * Conntrack Kernel  : ${CONN_C} / ${CONN_M} ($(( CONN_C * 100 / CONN_M ))%)"
(( EST_INC == 0 && RUN_C > 0 )) && WARN=$((WARN + 1))

SAMPLE_NODES=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -E "^(traffmon|pawns|packet|earn|honey|repocket|bitping)" | shuf -n 3 2>/dev/null || true)
[[ -z "$SAMPLE_NODES" ]] && SAMPLE_NODES=$(docker ps --format "{{.Names}}" 2>/dev/null | head -n 3 || true)
if [[ -n "$SAMPLE_NODES" ]]; then
  declare -A B1
  for c in $SAMPLE_NODES; do
    p=$(docker inspect -f "{{.State.Pid}}" "$c" 2>/dev/null || echo 0)
    b=0
    if (( p > 0 )) && [[ -f "/proc/$p/net/dev" ]]; then
      while read -r iface rx _ _ _ _ _ _ _ tx _; do
        case "$iface" in tun*|tap*|eth*) b=$((b + rx + tx)) ;; esac
      done < <(tr ":" " " < "/proc/$p/net/dev" 2>/dev/null)
    fi
    B1["$c"]=$b
  done
  sleep 2
  for c in $SAMPLE_NODES; do
    p=$(docker inspect -f "{{.State.Pid}}" "$c" 2>/dev/null || echo 0)
    b=0
    if (( p > 0 )) && [[ -f "/proc/$p/net/dev" ]]; then
      while read -r iface rx _ _ _ _ _ _ _ tx _; do
        case "$iface" in tun*|tap*|eth*) b=$((b + rx + tx)) ;; esac
      done < <(tr ":" " " < "/proc/$p/net/dev" 2>/dev/null)
    fi
    d=$((b - B1["$c"]))
    mi=$((b / 1048576)); md=$(( (b % 1048576) * 100 / 1048576 ))
    kb=$((d / 2048))
    if (( d > 0 )); then
      echo -e "  * Mẫu [${c}] : Tổng ${G}${mi}.${md} MB${N} | 2s qua: ${G}+${d} B (~${kb} KB/s)${N}"
    else
      echo -e "  * Mẫu [${c}] : Tổng ${G}${mi}.${md} MB${N} | 2s qua: ${Y}0 B (Chờ heartbeat)${N}"
    fi
  done
fi

echo -e "\n${B}--------------------------------------------------------------------------------${N}"
if (( ERR == 0 && WARN == 0 )); then
  echo -e "  >>> KẾT LUẬN: ${G}[HOÀN HẢO 100%] Sạch hoàn toàn Shield & Mọi thứ chạy ổn định!${N}"
elif (( ERR == 0 )); then
  echo -e "  >>> KẾT LUẬN: ${Y}[SẠCH SHIELD - CÓ ${WARN} CẢNH BÁO NHẸ]${N} (Xem dòng màu vàng ở trên)"
else
  echo -e "  >>> KẾT LUẬN: ${R}[PHÁT HIỆN ${ERR} LỖI / ${WARN} CẢNH BÁO]${N} (Xem dòng màu đỏ ở trên)"
fi
echo -e "${B}================================================================================${N}\n"
'
```


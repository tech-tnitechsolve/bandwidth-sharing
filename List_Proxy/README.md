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
cd / && sudo bash -c '
K_WS="webshare""_shield.sh"; K_AU="audit""_system.sh"

# 1. Xóa sạch webshare_shield (service, cron, process, iptables container, hosts)
systemctl stop webshare-watcher.service 2>/dev/null || true
systemctl disable webshare-watcher.service 2>/dev/null || true
rm -f /etc/systemd/system/webshare-watcher.service
sed -i "/${K_WS}/d" /etc/cron.d/internetincome 2>/dev/null || true

for p in $(pgrep -f "$K_WS" 2>/dev/null || true); do
  [[ "$p" != "$$" && "$p" != "$PPID" ]] && kill -9 "$p" 2>/dev/null || true
done

for pid in $(docker inspect --format "{{.State.Pid}}" $(docker ps -q 2>/dev/null) 2>/dev/null | sort -u); do
  if (( pid > 0 )); then
    while nsenter -t "$pid" -n iptables -D OUTPUT -j WEBSHARE_SHIELD 2>/dev/null; do :; done
    nsenter -t "$pid" -n iptables -F WEBSHARE_SHIELD 2>/dev/null || true
    nsenter -t "$pid" -n iptables -X WEBSHARE_SHIELD 2>/dev/null || true
  fi
done

for h in $(docker inspect --format "{{.HostsPath}}" $(docker ps -aq 2>/dev/null) 2>/dev/null); do
  if [[ -f "$h" ]] && grep -q "WEBSHARE COMPLIANCE FILTER" "$h" 2>/dev/null; then
    tmp_h=$(mktemp)
    awk "/# --- WEBSHARE COMPLIANCE FILTER/{exit} {print}" "$h" > "$tmp_h" && cat "$tmp_h" > "$h"
    rm -f "$tmp_h"
  fi
done

# 2. Xóa sạch luôn pawns-shield trên host (nếu từng lỡ cài trên VPS Docker thuần)
systemctl disable --now pawns-shield 2>/dev/null || true
iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true
iptables -t nat -F PAWNS_SHIELD 2>/dev/null || true
iptables -t nat -X PAWNS_SHIELD 2>/dev/null || true
ip6tables -D OUTPUT -j PAWNS_SHIELD_V6 2>/dev/null || true
ip6tables -F PAWNS_SHIELD_V6 2>/dev/null || true
ip6tables -X PAWNS_SHIELD_V6 2>/dev/null || true
ip6tables -D OUTPUT -p tcp -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true
ip6tables -D OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
ip6tables -D OUTPUT -o lo -j ACCEPT 2>/dev/null || true

# 3. Xóa toàn bộ file script shield & reload systemd
rm -f "/usr/local/bin/${K_WS}" "/usr/local/bin/${K_AU}" /usr/local/bin/pawns-shield.py /etc/systemd/system/pawns-shield.service
systemctl daemon-reload 2>/dev/null || true

echo -e "\n\033[1;32m[HOÀN TẤT] ĐÃ XÓA SẠCH 100% SHIELD — QUAY VỀ NGUYÊN BẢN DOCKER + SETUP_VPS!\033[0m\n"
'
```
# Check xem đã xóa sạch chưa
```
cd / && sudo bash -c '
G="\033[1;32m"; Y="\033[1;33m"; R="\033[1;31m"; C="\033[1;36m"; B="\033[1;34m"; N="\033[0m"
ERR=0; WARN=0

echo -e "\n${B}================================================================================${N}"
echo -e "${B}  [FINAL DEEP CHECK] KIỂM TOÁN TOÀN DIỆN TRAFFMONETIZER & DOCKER (${HOSTNAME})${N}"
echo -e "${B}================================================================================${N}"

# --- 1. KIỂM TRA SẠCH SHIELD 100% ---
K_WS="webshare""_shield"; K_PS="pawns""-shield"; K_AU="audit""_system"; K_WW="webshare""-watcher"
P_HIT=$(pgrep -af "${K_WS}|${K_PS}" 2>/dev/null || true)
SVC_WS=$(systemctl is-active "${K_WW}.service" 2>/dev/null || echo "none")
SVC_PS=$(systemctl is-active "${K_PS}.service" 2>/dev/null || echo "none")
CRON_WS=$(grep "$K_WS" /etc/cron.d/internetincome 2>/dev/null | wc -l)
CRON_OK=$(grep -E "ii-autosync|ii-flapguard|ii-repocket-watchdog" /etc/cron.d/internetincome 2>/dev/null | wc -l)

F_LEFT=""
for f in "/usr/local/bin/${K_WS}.sh" "/usr/local/bin/${K_AU}.sh" "/usr/local/bin/${K_PS}.py" "/etc/systemd/system/${K_WW}.service" "/etc/systemd/system/${K_PS}.service"; do
  [[ -e "$f" ]] && F_LEFT="${F_LEFT} $f"
done

NAT_HIT=$(iptables -t nat -S PAWNS_SHIELD 2>/dev/null | wc -l)
V6_HIT=$(ip6tables -S PAWNS_SHIELD_V6 2>/dev/null | wc -l)

ALL_IDS=$(docker ps -aq 2>/dev/null || true)

IPT_HIT=0; V6_OK=0; V6_BAD=0
HOSTS_DIRTY=0; HOSTS_BROKEN=0; HOSTS_TOT=0
TUN_RUN=0; TUN_ALL=0; TM_RUN=0; TM_ALL=0; TM_RC=0; TM_OOM=0; OTHER_EXIT=0
TUN_PIDS=""

if [[ -n "$ALL_IDS" ]]; then
  while IFS="|" read -r cname st pid rc oom hpath; do
    cname="${cname#/}"
    if [[ -f "$hpath" ]]; then
      HOSTS_TOT=$((HOSTS_TOT + 1))
      grep -qE "WEBSHARE COMPLIANCE FILTER|0\.0\.0\.0 auth\.uber\.com" "$hpath" 2>/dev/null && HOSTS_DIRTY=$((HOSTS_DIRTY + 1))
      grep -q "localhost" "$hpath" 2>/dev/null || HOSTS_BROKEN=$((HOSTS_BROKEN + 1))
    fi
    if [[ "$cname" =~ ^(tun|gluetun|hev) ]]; then
      TUN_ALL=$((TUN_ALL + 1))
      [[ "$st" == "running" ]] && { TUN_RUN=$((TUN_RUN + 1)); (( pid > 0 )) && TUN_PIDS="${TUN_PIDS} $pid"; }
    elif [[ "$cname" =~ ^traffmon ]]; then
      TM_ALL=$((TM_ALL + 1))
      if [[ "$st" == "running" ]]; then
        TM_RUN=$((TM_RUN + 1))
        TM_RC=$((TM_RC + rc))
        [[ "$oom" == "true" ]] && TM_OOM=$((TM_OOM + 1))
      fi
    else
      [[ "$st" != "running" ]] && OTHER_EXIT=$((OTHER_EXIT + 1))
    fi
  done < <(docker inspect --format "{{.Name}}|{{.State.Status}}|{{.State.Pid}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{.HostsPath}}" $ALL_IDS 2>/dev/null)
fi

for tp in $(echo "$TUN_PIDS" | tr " " "\n" | sort -u); do
  [[ -z "$tp" ]] && continue
  if nsenter -t "$tp" -n iptables -S WEBSHARE_SHIELD >/dev/null 2>&1 || nsenter -t "$tp" -n iptables -C OUTPUT -j WEBSHARE_SHIELD >/dev/null 2>&1; then
    IPT_HIT=$((IPT_HIT + 1))
  fi
  v6=$(nsenter -t "$tp" -n sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "?")
  [[ "$v6" == "1" ]] && V6_OK=$((V6_OK + 1)) || V6_BAD=$((V6_BAD + 1))
done

echo -e "${C}[1. SẠCH SHIELD & TOÀN VẸN NGUYÊN BẢN]${N}"
if [[ -z "$P_HIT" && "$SVC_WS" != "active" && "$SVC_PS" != "active" && "$CRON_WS" -eq 0 && -z "$F_LEFT" && "$NAT_HIT" -eq 0 && "$V6_HIT" -eq 0 && "$IPT_HIT" -eq 0 && "$HOSTS_DIRTY" -eq 0 ]]; then
  echo -e "  * Trạng thái Shield : ${G}SẠCH 100%${N} (0 process, 0 service, 0 cron, 0 file, 0 iptables, 0 hosts)"
else
  ERR=$((ERR + 1))
  echo -e "  * Trạng thái Shield : ${R}CÒN SÓT!${N} Proc=[$P_HIT] Svc=[$SVC_WS/$SVC_PS] Cron=[$CRON_WS] File=[$F_LEFT] NAT=[$NAT_HIT] V6=[$V6_HIT] Ipt=[$IPT_HIT] Hosts=[$HOSTS_DIRTY]"
fi
if (( HOSTS_BROKEN == 0 )); then
  echo -e "  * File /etc/hosts   : ${G}NGUYÊN VẸN${N} (${HOSTS_TOT}/${HOSTS_TOT} container đủ localhost)"
else
  ERR=$((ERR + 1))
  echo -e "  * File /etc/hosts   : ${R}LỖI${N} (${HOSTS_BROKEN} container mất localhost)"
fi
echo -e "  * Cron setup_vps.sh : $( (( CRON_OK > 0 )) && echo -e "${G}HOẠT ĐỘNG (${CRON_OK} tác vụ)${N}" || echo -e "${Y}Không có${N}" )"

# --- 2. SỨC KHỎE TRAFFMONETIZER & TUN ---
echo -e "\n${C}[2. SỨC KHỎE RIÊNG TRAFFMONETIZER & TUNNEL]${N}"
if (( TM_ALL > 0 && TM_RUN == TM_ALL && TM_OOM == 0 )); then
  echo -e "  * Traffmonetizer    : ${G}${TM_RUN}/${TM_ALL} ĐANG CHẠY 100%${N} | OOM: ${TM_OOM} | Tổng Restart: ${TM_RC}"
elif (( TM_ALL == 0 )); then
  WARN=$((WARN + 1))
  echo -e "  * Traffmonetizer    : ${Y}Chưa thấy container traffmon* nào${N}"
else
  ERR=$((ERR + 1))
  echo -e "  * Traffmonetizer    : ${R}${TM_RUN}/${TM_ALL} đang chạy${N} | OOM: ${TM_OOM} | Restart: ${TM_RC}"
fi

if (( TUN_ALL > 0 && TUN_RUN == TUN_ALL && V6_BAD == 0 )); then
  echo -e "  * Tunnel (TUN)      : ${G}${TUN_RUN}/${TUN_ALL} ĐANG CHẠY 100%${N} | Khóa IPv6 chuẩn: ${G}${V6_OK}/${TUN_RUN}${N}"
else
  (( TUN_RUN < TUN_ALL || V6_BAD > 0 )) && ERR=$((ERR + 1))
  echo -e "  * Tunnel (TUN)      : ${R}${TUN_RUN}/${TUN_ALL} chạy${N} | IPv6 OK=${V6_OK}, Hở=${V6_BAD}"
fi
(( OTHER_EXIT > 0 )) && echo -e "  * Container khác tắt: ${Y}${OTHER_EXIT} node không phải traffmon/tun (vd: pawns cũ)${N}"

# --- 3. PHẦN CỨNG, KERNEL & NETWORK ---
read -r L1 L5 L15 _ < /proc/loadavg
CORES=$(nproc 2>/dev/null || echo 1)
read -r _ RAM_T RAM_U _ _ _ RAM_A < <(free -m | grep "^Mem:")
read -r _ SWAP_T SWAP_U _ < <(free -m | grep "^Swap:")
ZRAM_SZ=$(swapon --show 2>/dev/null | grep "/dev/zram0" | tr -s " " | cut -d" " -f3 || true)
DISK_PCT=$(df -h / | tail -n1 | tr -s " " | cut -d" " -f5)
grep " / " /proc/mounts | grep -qE "[ ,]ro([ ,]|$)" && RO_CHK="RO" || RO_CHK="RW"
VM_LINE=$(vmstat 1 2 | tail -n 1)
read -r _ _ _ _ _ _ VM_SI VM_SO _ _ _ _ _ _ VM_ID VM_WA VM_ST _ <<< "$VM_LINE"
CONN_C=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CONN_M=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 524288)
DNS_OK=$(grep -E "^nameserver (1\.1\.1\.1|8\.8\.8\.8|9\.9\.9\.9)" /etc/resolv.conf 2>/dev/null | wc -l)

echo -e "\n${C}[3. PHẦN CỨNG, KERNEL & DNS HOST]${N}"
echo -e "  * CPU (${CORES} Cores)      : Load ${G}${L1} ${L5} ${L15}${N} | Idle: ${G}${VM_ID}%${N} | IOwait: ${VM_WA}% | Steal: ${VM_ST}%"
echo -e "  * RAM / Swap / ZRAM : Dùng ${G}${RAM_U}/${RAM_T} MB${N} (Trống: ${G}${RAM_A} MB${N}) | Swap: ${SWAP_U}/${SWAP_T} MB (si=${VM_SI} so=${VM_SO}) | ZRAM: ${G}${ZRAM_SZ:-OFF}${N}"
echo -e "  * Disk / Conntrack  : ${DISK_PCT} (${RO_CHK}) | Conntrack: ${G}${CONN_C}/${CONN_M}${N} | Host DNS upstream: ${G}${DNS_OK} server${N}"
[[ "$RO_CHK" == "RO" ]] && ERR=$((ERR + 1))
(( VM_ST > 15 || VM_SI > 50 || VM_SO > 50 )) && WARN=$((WARN + 1))

# --- 4. TỐC ĐỘ THỰC TẾ & TỶ LỆ TUN SỐNG (5 GIÂY) ---
IFACE=$(ip -4 route show default | awk "{print \$5}" | head -n1)
R1=$(cat /sys/class/net/"$IFACE"/statistics/rx_bytes 2>/dev/null || echo 0)
T1=$(cat /sys/class/net/"$IFACE"/statistics/tx_bytes 2>/dev/null || echo 0)
ACT=0; IDLE=0
for tp in $(echo "$TUN_PIDS" | tr " " "\n" | grep -v "^$" | shuf -n 20); do
  c=$(nsenter -t "$tp" -n ss -tan state established 2>/dev/null | tail -n +2 | wc -l)
  (( c > 0 )) && ACT=$((ACT + 1)) || IDLE=$((IDLE + 1))
done
sleep 5
R2=$(cat /sys/class/net/"$IFACE"/statistics/rx_bytes 2>/dev/null || echo 0)
T2=$(cat /sys/class/net/"$IFACE"/statistics/tx_bytes 2>/dev/null || echo 0)
DR=$(( (R2 - R1) / 5120 )); DT=$(( (T2 - T1) / 5120 ))

echo -e "\n${C}[4. TỐC ĐỘ CẮN DATA & SOCKET THỰC TẾ (5 GIÂY)]${N}"
echo -e "  * Tỷ lệ TUN sống    : ${G}${ACT} / $((ACT + IDLE)) TUN mẫu${N} đang có socket ESTABLISHED"
echo -e "  * Băng thông (${IFACE}) : Down ~${G}${DR} KB/s${N} | Up ~${G}${DT} KB/s${N} | Tổng: ${G}$((DR + DT)) KB/s${N}"
(( ACT == 0 && TUN_RUN > 0 )) && ERR=$((ERR + 1))

echo -e "\n${B}--------------------------------------------------------------------------------${N}"
if (( ERR == 0 && WARN == 0 )); then
  echo -e "  >>> KẾT LUẬN: ${G}[HOÀN HẢO 100%] Sạch Shield — Traffmonetizer & TUN đang cắn mượt không lỗi!${N}"
elif (( ERR == 0 )); then
  echo -e "  >>> KẾT LUẬN: ${Y}[ỔN ĐỊNH - CÓ ${WARN} LƯU Ý NHẸ]${N} (Không ảnh hưởng Traffmonetizer)"
else
  echo -e "  >>> KẾT LUẬN: ${R}[PHÁT HIỆN ${ERR} LỖI CẦN XEM LẠI]${N} (Xem dòng màu đỏ ở trên)"
fi
echo -e "${B}================================================================================${N}\n"
'
```


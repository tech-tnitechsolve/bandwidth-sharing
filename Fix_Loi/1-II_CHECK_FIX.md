# Fix lỗi tồn đọng của source setup_vps và internetincome.sh

```
sudo bash <<'II_MASTER_FIX_CHECK'
set +u
G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[1;36m'; D='\033[0;37m'; N='\033[0m'

echo -e "${C}==================== [PHAN 1: TOI UU HE THONG AN TOAN (IDEMPOTENT)] ====================${N}"

# 1.1 Don tien trinh cron/docker stats bi treo (khong dung container)
HUNG_CNT=$(ps aux | grep -E "[d]ocker stats --no-stream|[i]i-autosync" | wc -l)
if [ "$HUNG_CNT" -gt 0 ]; then
  pkill -9 -f "[d]ocker stats --no-stream" 2>/dev/null || true
  pkill -9 -f "[i]i-autosync" 2>/dev/null || true
  echo -e "  ${G}[FIXED]${N} Da don ${HUNG_CNT} tien trinh docker stats/autosync bi treo"
else
  echo -e "  ${D}[SKIP]${N}  Khong co tien trinh treo"
fi

# 1.2 Va chong treo cho ii-autosync.sh (flock + timeout 25s)
SYNC_FILE="/usr/local/bin/ii-autosync.sh"
if [ ! -f "$SYNC_FILE" ]; then
  echo -e "  ${D}[SKIP]${N}  Khong co ii-autosync.sh"
elif grep -q "ii-autosync.lock" "$SYNC_FILE" && grep -q "timeout 25 docker stats" "$SYNC_FILE"; then
  echo -e "  ${D}[SKIP]${N}  ii-autosync.sh da duoc va san"
else
  if ! grep -q "ii-autosync.lock" "$SYNC_FILE"; then
    if grep -q "set -uo pipefail" "$SYNC_FILE"; then
      sed -i '/set -uo pipefail/a exec 9>/run/ii-autosync.lock\nflock -n 9 || exit 0' "$SYNC_FILE"
    else
      sed -i '1a exec 9>/run/ii-autosync.lock\nflock -n 9 || exit 0' "$SYNC_FILE"
    fi
  fi
  if ! grep -q "timeout 25 docker stats" "$SYNC_FILE"; then
    sed -i 's/STATS_RAW=$(docker stats --no-stream/STATS_RAW=$(timeout 25 docker stats --no-stream/' "$SYNC_FILE"
  fi
  echo -e "  ${G}[FIXED]${N} Da va chong treo ii-autosync.sh"
fi

# 1.3 Tat cron 2-phut ii-repocket-watchdog neu VPS khong chay Repocket
if ! docker ps -a --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -qi 'repocket'; then
  if [ -f /etc/cron.d/internetincome ] && grep -qE '^[^#].*ii-repocket-watchdog' /etc/cron.d/internetincome; then
    sed -i '/^[^#].*ii-repocket-watchdog/s/^/# /' /etc/cron.d/internetincome
    echo -e "  ${G}[FIXED]${N} Da tat cron 2-phut ii-repocket-watchdog (VPS khong chay Repocket)"
  else
    echo -e "  ${D}[SKIP]${N}  Cron ii-repocket-watchdog da tat san"
  fi
else
  RP_FILE="/usr/local/bin/ii-repocket-watchdog.sh"
  if [ -f "$RP_FILE" ] && ! grep -q "ii-repocket.lock" "$RP_FILE" && grep -q "set -uo pipefail" "$RP_FILE"; then
    sed -i '/set -uo pipefail/a exec 8>/run/ii-repocket.lock\nflock -n 8 || exit 0' "$RP_FILE"
    echo -e "  ${G}[FIXED]${N} Da them khoa flock cho ii-repocket-watchdog.sh"
  else
    echo -e "  ${D}[SKIP]${N}  ii-repocket-watchdog.sh da toi uu san"
  fi
fi

# 1.4 Giu nguyen ii-flapguard.sh cho Pawns & Honeygain (them flock + thoat nhanh neu ko co app nhay cam)
FG_FILE="/usr/local/bin/ii-flapguard.sh"
if [ -f "$FG_FILE" ]; then
  fg_chg=0
  if ! grep -q "ii-flapguard.lock" "$FG_FILE" && grep -q "set -uo pipefail" "$FG_FILE"; then
    sed -i '/set -uo pipefail/a exec 7>/run/ii-flapguard.lock\nflock -n 7 || exit 0' "$FG_FILE"
    fg_chg=1
  fi
  if ! grep -q "honey|pawns|packetstream" "$FG_FILE" && grep -q "command -v docker" "$FG_FILE"; then
    sed -i "/command -v docker/a docker ps -a --format '{{.Names}}|{{.Image}}' 2>/dev/null | grep -qiE 'honey|pawns|packetstream|packetshare|earnfm|depinext|ebesucher|adnade|grass|gradient|nodepay|dawn|titan|uprock|customchrome|customfirefox' || exit 0" "$FG_FILE"
    fg_chg=1
  fi
  [ "$fg_chg" -eq 1 ] && echo -e "  ${G}[FIXED]${N} Da toi uu ii-flapguard.sh (van bao ve Pawns/Honeygain)" || echo -e "  ${D}[SKIP]${N}  ii-flapguard.sh da toi uu san"
else
  echo -e "  ${D}[SKIP]${N}  Khong co ii-flapguard.sh"
fi

# 1.5 Bao dam /dev/net/tun ton tai (giup container moi khong bi loi)
if [ ! -c /dev/net/tun ]; then
  mkdir -p /dev/net 2>/dev/null || true
  mknod /dev/net/tun c 10 200 2>/dev/null && chmod 600 /dev/net/tun 2>/dev/null || true
  [ -c /dev/net/tun ] && echo -e "  ${G}[FIXED]${N} Da khoi phuc /dev/net/tun" || echo -e "  ${R}[LOI]${N}   Khong tao duoc /dev/net/tun"
else
  echo -e "  ${D}[SKIP]${N}  /dev/net/tun san sang"
fi

# 1.6 Kich hoat ZRAM neu dang tat
if swapon --show 2>/dev/null | grep -q zram; then
  echo -e "  ${D}[SKIP]${N}  ZRAM da bat san"
else
  if ! modprobe zram num_devices=1 2>/dev/null; then
    timeout 45 apt-get update -y -qq >/dev/null 2>&1 || true
    timeout 90 apt-get install -y -qq "linux-modules-extra-$(uname -r)" >/dev/null 2>&1 || true
    modprobe zram num_devices=1 2>/dev/null || true
  fi
  if [ -x /usr/local/bin/ii-init-zram.sh ]; then
    /usr/local/bin/ii-init-zram.sh >/dev/null 2>&1 || true
  elif [ -b /dev/zram0 ]; then
    MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    ZBYTES=$(( MEM_KB * 1024 ))
    grep -q zstd /sys/block/zram0/comp_algorithm 2>/dev/null && echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    echo "$ZBYTES" > /sys/block/zram0/disksize 2>/dev/null || true
    mkswap /dev/zram0 >/dev/null 2>&1 && swapon -p 10 /dev/zram0 2>/dev/null || true
  fi
  swapon --show 2>/dev/null | grep -q zram && echo -e "  ${G}[FIXED]${N} Da kich hoat ZRAM thanh cong" || echo -e "  ${Y}[WARN]${N}  Kernel khong ho tro ZRAM"
fi

# 1.7 Dong bo Swappiness, MTU Probing & Conntrack cho container cu & moi
SYSCTL_F="/etc/sysctl.d/99-internetincome.conf"
CURR_SW=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "")
if swapon --show 2>/dev/null | grep -q zram; then
  TARGET_SW="100"; TARGET_VFS="200"
else
  TARGET_SW="15"; TARGET_VFS="100"
fi
if [ "$CURR_SW" = "$TARGET_SW" ]; then
  echo -e "  ${D}[SKIP]${N}  Swappiness da chuan (${TARGET_SW})"
else
  sysctl -w "vm.swappiness=${TARGET_SW}" >/dev/null 2>&1 || true
  sysctl -w "vm.vfs_cache_pressure=${TARGET_VFS}" >/dev/null 2>&1 || true
  if [ -f "$SYSCTL_F" ]; then
    sed -i "s/^vm\.swappiness.*/vm.swappiness = ${TARGET_SW}/" "$SYSCTL_F"
    sed -i "s/^vm\.vfs_cache_pressure.*/vm.vfs_cache_pressure = ${TARGET_VFS}/" "$SYSCTL_F"
  fi
  echo -e "  ${G}[FIXED]${N} Da chinh swappiness ${CURR_SW} -> ${TARGET_SW}"
fi

CURR_MTU=$(cat /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null || echo 0)
if [ "$CURR_MTU" = "1" ]; then
  echo -e "  ${D}[SKIP]${N}  tcp_mtu_probing da bat (1)"
else
  sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
  if [ -f "$SYSCTL_F" ] && ! grep -q "tcp_mtu_probing" "$SYSCTL_F"; then
    echo "net.ipv4.tcp_mtu_probing = 1" >> "$SYSCTL_F"
  fi
  echo -e "  ${G}[FIXED]${N} Da bat net.ipv4.tcp_mtu_probing=1 (chong nghen goi tin TUN)"
fi

CURR_CTMAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
if [ "${CURR_CTMAX:-0}" -lt 524288 ]; then
  sysctl -w net.netfilter.nf_conntrack_max=524288 >/dev/null 2>&1 || true
  echo -e "  ${G}[FIXED]${N} Da nang nf_conntrack_max -> 524288"
fi

# 1.8 Don log Docker phinh to >20MB
BIG_LOGS=$(find /var/lib/docker/containers/ -name "*-json.log" -size +20M 2>/dev/null | wc -l)
if [ "$BIG_LOGS" -gt 0 ]; then
  find /var/lib/docker/containers/ -name "*-json.log" -size +20M -exec truncate -s 0 {} + 2>/dev/null || true
  journalctl --vacuum-size=10M >/dev/null 2>&1 || true
  echo -e "  ${G}[FIXED]${N} Da don ${BIG_LOGS} file log >20MB"
else
  echo -e "  ${D}[SKIP]${N}  Log Docker sach se (<20MB)"
fi

echo -e "\n${C}==================== [PHAN 2: CHECK SAU TOAN BO VPS] ====================${N}"
ZRAM_INFO=$(swapon --show --noheadings 2>/dev/null | awk '/zram/{printf "%s", $3}')
DOCKERD_MB=$(ps -C dockerd -o rss= 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s/1024}')
HUNG_NOW=$(ps aux | grep -E "[d]ocker stats --no-stream|[i]i-autosync" | wc -l)
DISK_PCT=$(df -h / | awk 'NR==2 {print $5}')
LOAD_AVG=$(awk '{print $1, $2, $3}' /proc/loadavg)
CT_CNT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
CT_MAX=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 1)
CT_PCT=$(( CT_CNT * 100 / (CT_MAX > 0 ? CT_MAX : 1) ))

echo "  Host/Load  : $(hostname) ($(nproc) vCPU) | Load: ${LOAD_AVG} | Disk /: ${DISK_PCT}"
echo "  RAM / Swap : $(free -h | awk '/^Mem:/{print "Mem "$3"/"$2" (Avail: "$7")"}') | $(free -h | awk '/^Swap:/{print "Swap "$3"/"$2}')"
echo -e "  ZRAM/Docker: ZRAM=$([ -n "$ZRAM_INFO" ] && echo -e "${G}ON(${ZRAM_INFO})${N}" || echo -e "${Y}OFF${N}") | Swappiness=$(cat /proc/sys/vm/swappiness) | MTU_Probe=$(cat /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null) | dockerd=${DOCKERD_MB}MB | Hung=${HUNG_NOW} | Conntrack=${CT_CNT}/${CT_MAX}(${CT_PCT}%)"

OOM_LINES=$(dmesg -T 2>/dev/null | grep -iE "out of memory|oom-killer|killed process" | tail -n 2 || true)
if [ -n "$OOM_LINES" ]; then
  echo -e "  ${Y}[LUU Y] Co vet OOM trong dmesg (kiem tra moc thoi gian):${N}"
  echo "$OOM_LINES" | sed 's/^/    /'
fi

declare -A ST RC OOM PID_MAP
mapfile -t CIDS < <(docker ps -aq 2>/dev/null)
c_run=0; c_rst=0; c_cre=0; c_ext=0; c_oom=0; c_flap=0; BROKEN=()
if (( ${#CIDS[@]} > 0 )); then
  while IFS='|' read -r cname st rc oom cpid; do
    cname="${cname#/}"
    ST["$cname"]="$st"; RC["$cname"]="$rc"; OOM["$cname"]="$oom"; PID_MAP["$cname"]="$cpid"
    case "$st" in
      running)    c_run=$((c_run+1)) ;;
      restarting) c_rst=$((c_rst+1)); BROKEN+=("$cname|restarting|rc=$rc") ;;
      created)    c_cre=$((c_cre+1)); BROKEN+=("$cname|created|rc=$rc") ;;
      *)          c_ext=$((c_ext+1)); BROKEN+=("$cname|$st|rc=$rc") ;;
    esac
    [[ "$oom" == "true" ]] && c_oom=$((c_oom+1))
    (( ${rc:-0} >= 3 )) && c_flap=$((c_flap+1))
  done < <(docker inspect --type container --format '{{.Name}}|{{.State.Status}}|{{.RestartCount}}|{{.State.OOMKilled}}|{{.State.Pid}}' "${CIDS[@]}" 2>/dev/null)
fi

echo -e "  Containers : Tong ${#CIDS[@]} | ${G}Up:${c_run}${N} | $([ $c_rst -gt 0 ] && echo -e "${R}Restarting:${c_rst}${N}" || echo "Restarting:0") | $([ $c_cre -gt 0 ] && echo -e "${R}Created:${c_cre}${N}" || echo "Created:0") | $([ $c_ext -gt 0 ] && echo -e "${Y}Exited:${c_ext}${N}" || echo "Exited:0") | OOM:${c_oom} | Flap>=3:${c_flap}"
if (( ${#BROKEN[@]} > 0 )); then
  echo -e "  ${R}Top 15 container loi:${N}"
  printf '    - %s\n' "${BROKEN[@]:0:15}"
fi

ok_dirs=0; bad_dirs=0; total_dirs=0
tun_estab_ok=0; tun_estab_zero=0; IDLE_FOLDERS=()

while IFS= read -r cfile; do
  total_dirs=$((total_dirs+1))
  d=$(dirname "$cfile")
  pfile="${d}/proxies.txt"; prop="${d}/properties.conf"
  f_tot=0; f_run=0; f_bad=0; f_miss=0; f_tun=0; d_idle_tun=0
  while IFS= read -r cn || [[ -n "$cn" ]]; do
    cn="${cn//$'\r'/}"
    [[ -z "$cn" ]] && continue
    f_tot=$((f_tot+1))
    s="${ST[$cn]:-MISSING}"
    if [[ "$s" == "running" ]]; then
      f_run=$((f_run+1))
      if [[ "$cn" == tun* ]]; then
        f_tun=$((f_tun+1))
        tpid="${PID_MAP[$cn]:-0}"
        if (( tpid > 0 )) && awk 'FNR>1 && $4=="01" && $3 !~ /^(0100007F|00000000000000000000000001000000|0000000000000000FFFF00000100007F):/ {f=1; exit 0} END{exit (f?0:1)}' "/proc/${tpid}/net/tcp" "/proc/${tpid}/net/tcp6" 2>/dev/null; then
          tun_estab_ok=$((tun_estab_ok+1))
        else
          tun_estab_zero=$((tun_estab_zero+1))
          d_idle_tun=$((d_idle_tun+1))
        fi
      fi
    elif [[ "$s" == "MISSING" ]]; then
      f_miss=$((f_miss+1))
      [[ "$cn" == tun* ]] && f_tun=$((f_tun+1))
    else
      f_bad=$((f_bad+1))
      [[ "$cn" == tun* ]] && f_tun=$((f_tun+1))
    fi
  done < "$cfile"

  (( d_idle_tun > 0 )) && IDLE_FOLDERS+=("${d} (${d_idle_tun}/${f_tun} TUN 0 ESTAB)")

  p_cnt=0; p_badfmt=0; p_crlf=0
  if [[ -f "$pfile" ]]; then
    grep -q $'\r' "$pfile" && p_crlf=1
    while IFS= read -r pl || [[ -n "$pl" ]]; do
      pl="${pl//$'\r'/}"; pl="$(echo "$pl" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$pl" || "$pl" == \#* ]] && continue
      p_cnt=$((p_cnt+1))
      [[ "$pl" != *"://"* ]] && p_badfmt=$((p_badfmt+1))
    done < "$pfile"
  fi

  if (( f_bad > 0 || f_miss > 0 || p_badfmt > 0 || p_crlf == 1 || (f_tun > 0 && f_tun != p_cnt) )); then
    bad_dirs=$((bad_dirs+1))
    t2p=$(grep -E '^USE_TUN2PROXY=' "$prop" 2>/dev/null | tail -n1 | cut -d= -f2 || echo "?")
    doh=$(grep -E '^USE_DNS_OVER_HTTPS=' "$prop" 2>/dev/null | tail -n1 | cut -d= -f2 || echo "?")
    echo -e "  ${R}[FOLDER LOI]${N} $d"
    echo -e "    Containers: ${f_run}/${f_tot} running (Loi:${f_bad}, Thieu:${f_miss}) | TUN:${f_tun} vs Proxies:${p_cnt} | bad_fmt:${p_badfmt} | CRLF:${p_crlf} | TUN2PROXY=${t2p:-?} DoH=${doh:-?}"
  else
    ok_dirs=$((ok_dirs+1))
  fi
done < <(find /root /home /opt /srv /mnt /data -maxdepth 6 -name "containernames.txt" -type f 2>/dev/null | sort -u)

if (( bad_dirs == 0 )); then
  echo -e "  Folders    : ${G}${ok_dirs}/${total_dirs} folders [100% OK]${N}"
else
  echo -e "  Folders    : ${G}${ok_dirs} OK${N} | ${R}${bad_dirs} LOI${N} (tong ${total_dirs})"
fi

echo -e "  TUN Socket : ${G}${tun_estab_ok} TUN dang co ESTAB${N} | $([ $tun_estab_zero -eq 0 ] && echo "0 TUN 0_ESTAB" || echo -e "${Y}${tun_estab_zero} TUN dang 0_ESTAB${N}")"
if (( ${#IDLE_FOLDERS[@]} > 0 )); then
  echo -e "  ${Y}Folder co TUN 0_ESTAB (het data proxy / chua ket noi):${N}"
  printf '    - %s\n' "${IDLE_FOLDERS[@]}"
fi

if [ -s /var/log/ii-flapguard.log ]; then
  echo -e "  ${Y}ii-flapguard (2 dong cuoi):${N}"; tail -n 2 /var/log/ii-flapguard.log | sed 's/^/    /'
fi

echo -e "${C}==================================================================================${N}"
if (( c_rst == 0 && c_cre == 0 && bad_dirs == 0 && HUNG_NOW == 0 && tun_estab_zero == 0 )); then
  echo -e "  ${G}KET LUAN: VPS KHOE MANH 100% - TAT CA NODE DANG CHAY MUOT & CO TRAFFIC!${N}"
elif (( c_rst == 0 && c_cre == 0 && bad_dirs == 0 && HUNG_NOW == 0 )); then
  echo -e "  ${Y}KET LUAN: HE THONG VPS SACH SE 100% — CHI CO MOT SO FOLDER PROXY 0_ESTAB O MUC TREN.${N}"
else
  echo -e "  ${Y}KET LUAN: CO NODE/FOLDER CAN KIEM TRA O MUC [FOLDER LOI] / [Top container loi] PHIA TREN.${N}"
fi
II_MASTER_FIX_CHECK
```

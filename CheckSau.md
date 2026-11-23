# Check Sâu lỗi nghẽn máy của VPS

```
sudo bash <<'DEEPCHECK'
set +u
G='\033[1;32m'; Y='\033[1;33m'; R='\033[1;31m'; C='\033[1;36m'; N='\033[0m'

echo -e "${C}==================== [1. HE THONG, RAM, ZRAM & OOM] ====================${N}"
free -h | sed 's/^/  /'
ZRAM_ON=$(swapon --show 2>/dev/null | grep -q zram && echo "ON" || echo "OFF")
SWAP_INFO=$(swapon --show --noheadings 2>/dev/null | awk '{printf "%s(%s/%s) ", $1,$3,$4}')
SWAPPINESS=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "?")
echo -e "  ZRAM: $([ "$ZRAM_ON" = "ON" ] && echo -e "${G}ON${N}" || echo -e "${R}OFF${N}") | Swap: ${SWAP_INFO:-NONE} | Swappiness: ${SWAPPINESS}"
if [[ "$ZRAM_ON" == "OFF" && "$SWAPPINESS" -ge 60 ]] 2>/dev/null; then
  echo -e "  ${R}[LOI NANG] ZRAM dang TAT nhung swappiness=${SWAPPINESS} -> ep swap ra o cung gay lag node!${N}"
fi
[[ -c /dev/net/tun ]] && echo -e "  /dev/net/tun: ${G}OK${N}" || echo -e "  /dev/net/tun: ${R}THIEU (TUN se crash!)${N}"

OOM_LINES=$(dmesg -T 2>/dev/null | grep -iE "out of memory|oom-killer|killed process" | tail -n 3 || true)
if [[ -n "$OOM_LINES" ]]; then
  echo -e "  ${R}[CANH BAO] Phat hien OOM Kill gan day:${N}"
  echo "$OOM_LINES" | sed 's/^/    /'
fi

echo -e "\n${C}==================== [2. DOCKERD & TIEN TRINH TREO] ====================${N}"
DOCKERD_MB=$(ps -C dockerd -o rss= 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s/1024}')
HUNG_CNT=$(ps aux | grep -E "[d]ocker stats --no-stream|[i]i-autosync" | wc -l)
PATCHED=$(grep -q "ii-autosync.lock" /usr/local/bin/ii-autosync.sh 2>/dev/null && echo "YES" || echo "NO")
echo -e "  dockerd RSS : $([ "${DOCKERD_MB:-0}" -gt 500 ] && echo -e "${R}${DOCKERD_MB} MB (BI PHINH)${N}" || echo -e "${G}${DOCKERD_MB} MB${N}")"
echo -e "  Hung procs  : $([ "$HUNG_CNT" -gt 0 ] && echo -e "${R}${HUNG_CNT} tien trinh treo${N}" || echo -e "${G}0${N}")"
echo -e "  ii-autosync : $([ "$PATCHED" = "YES" ] && echo -e "${G}DA VA CHONG TREO${N}" || echo -e "${Y}CHUA VA (de bi treo docker stats)${N}")"

echo -e "\n${C}==================== [3. SUC KHOE THUC TE CONTAINER] ====================${N}"
declare -A ST RC OOM
mapfile -t CIDS < <(docker ps -aq 2>/dev/null)
c_run=0; c_rst=0; c_cre=0; c_ext=0; c_oom=0; c_flap=0; BROKEN=()
if (( ${#CIDS[@]} > 0 )); then
  while IFS='|' read -r cname st rc oom; do
    cname="${cname#/}"
    ST["$cname"]="$st"; RC["$cname"]="$rc"; OOM["$cname"]="$oom"
    case "$st" in
      running)    c_run=$((c_run+1)) ;;
      restarting) c_rst=$((c_rst+1)); BROKEN+=("$cname|restarting|rc=$rc") ;;
      created)    c_cre=$((c_cre+1)); BROKEN+=("$cname|created|rc=$rc") ;;
      *)          c_ext=$((c_ext+1)); BROKEN+=("$cname|$st|rc=$rc") ;;
    esac
    [[ "$oom" == "true" ]] && c_oom=$((c_oom+1))
    (( ${rc:-0} >= 3 )) && c_flap=$((c_flap+1))
  done < <(docker inspect --type container --format '{{.Name}}|{{.State.Status}}|{{.RestartCount}}|{{.State.OOMKilled}}' "${CIDS[@]}" 2>/dev/null)
fi
echo -e "  Tong: ${#CIDS[@]} | ${G}Running: ${c_run}${N} | ${R}Restarting: ${c_rst}${N} | ${R}Created(chet ngam): ${c_cre}${N} | ${Y}Exited/Other: ${c_ext}${N} | OOMKilled: ${c_oom} | Restart>=3: ${c_flap}"
if (( ${#BROKEN[@]} > 0 )); then
  echo -e "  ${R}Top 15 container dang loi (chet ngam/restarting):${N}"
  printf '    - %s\n' "${BROKEN[@]:0:15}"
fi

echo -e "\n${C}==================== [4. CHECK SAU TUNG FOLDER PROXY] ====================${N}"
while IFS= read -r cfile; do
  d=$(dirname "$cfile")
  pfile="${d}/proxies.txt"; prop="${d}/properties.conf"
  f_tot=0; f_run=0; f_bad=0; f_miss=0; f_tun=0
  while IFS= read -r cn || [[ -n "$cn" ]]; do
    cn="${cn//$'\r'/}"
    [[ -z "$cn" ]] && continue
    f_tot=$((f_tot+1))
    [[ "$cn" == tun* ]] && f_tun=$((f_tun+1))
    s="${ST[$cn]:-MISSING}"
    if [[ "$s" == "running" ]]; then f_run=$((f_run+1))
    elif [[ "$s" == "MISSING" ]]; then f_miss=$((f_miss+1))
    else f_bad=$((f_bad+1)); fi
  done < "$cfile"

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

  t2p=$(grep -E '^USE_TUN2PROXY=' "$prop" 2>/dev/null | tail -n1 | cut -d= -f2 || echo "?")
  doh=$(grep -E '^USE_DNS_OVER_HTTPS=' "$prop" 2>/dev/null | tail -n1 | cut -d= -f2 || echo "?")
  s5d=$(grep -E '^USE_SOCKS5_DNS=' "$prop" 2>/dev/null | tail -n1 | cut -d= -f2 || echo "?")

  badge="${G}[OK]${N}"
  (( f_bad > 0 || f_miss > 0 || p_badfmt > 0 )) && badge="${R}[LOI]${N}"
  echo -e "  ${badge} ${C}${d}${N}"
  echo -e "       Containers: ${f_run}/${f_tot} running (Loi: ${f_bad}, Thieu: ${f_miss}) | TUN: ${f_tun} vs Proxies: ${p_cnt}"
  echo -e "       Config: TUN2PROXY=${t2p:-?} | DoH=${doh:-?} | SOCKS5_DNS=${s5d:-?} | proxies_bad_fmt=${p_badfmt} | CRLF=${p_crlf}"
done < <(find /root /home /opt /srv /mnt /data -maxdepth 6 -name "containernames.txt" -type f 2>/dev/null | sort -u)

echo -e "\n${C}==================== [5. LOG FLAPGUARD & REPOCKET] ====================${N}"
[[ -f /var/log/ii-flapguard.log ]] && { echo "  ii-flapguard (3 dong cuoi):"; tail -n 3 /var/log/ii-flapguard.log | sed 's/^/    /'; } || echo "  ii-flapguard.log: Khong co canh bao"
[[ -f /var/log/ii-repocket.log ]] && { echo "  ii-repocket (3 dong cuoi):"; tail -n 3 /var/log/ii-repocket.log | sed 's/^/    /'; } || echo "  ii-repocket.log: Khong co canh bao"
echo -e "${C}========================================================================${N}"
DEEPCHECK
```

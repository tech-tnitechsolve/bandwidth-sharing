# Restart lại Traffmonetier khi thiếu device IP

```
sudo bash -c 'for c in $(docker ps --filter "name=traffmon" --format "{{.Names}}"); do docker restart "$c" >/dev/null 2>&1; echo " -> Đã làm mới: $c"; sleep 1; done'
```

# Restart lại các Container Lỗi (ko ảnh hưởng tới các container đang chạy)

```
sudo bash <<'SMARTHEAL_LITE'
set -uo pipefail

C_G='\033[1;32m'; C_R='\033[1;31m'; C_Y='\033[1;33m'; C_C='\033[1;36m'; C_0='\033[0m'

if ! docker info >/dev/null 2>&1; then
  echo -e "${C_R}[XX] Khong ket noi duoc Docker. Hay chay bang root/sudo.${C_0}"
  exit 1
fi

exec 9>/run/ii-smart-heal.lock
if ! flock -n 9; then
  echo -e "${C_Y}[!!] Dang co mot tien trinh hoi phuc khac dang chay.${C_0}"
  exit 1
fi

# Toi uu chong nghen phan manh MTU qua TUN (0% gian doan)
if [ "$(cat /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null || echo 0)" != "1" ]; then
  sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
  if [ -f /etc/sysctl.d/99-internetincome.conf ] && ! grep -q "tcp_mtu_probing" /etc/sysctl.d/99-internetincome.conf; then
    echo "net.ipv4.tcp_mtu_probing = 1" >> /etc/sysctl.d/99-internetincome.conf
  fi
fi

# Nap danh sach container thuoc InternetIncome tu containernames.txt
declare -A KNOWN_DIR
while IFS= read -r cfile; do
  d=$(dirname "$cfile")
  while IFS= read -r cn || [[ -n "$cn" ]]; do
    cn="${cn//$'\r'/}"
    [[ -n "$cn" ]] && KNOWN_DIR["$cn"]="$d"
  done < "$cfile"
done < <(find /root /home /opt /srv /mnt /data -maxdepth 6 -name "containernames.txt" -type f 2>/dev/null)

echo -e "\n${C_C}================ [GIAI DOAN 1: QUET NHE NHANG & HOI PHUC AN TOAN] ================${C_0}"

mapfile -t ALL_CIDS < <(docker ps -aq 2>/dev/null)
if (( ${#ALL_CIDS[@]} == 0 )); then
  echo "Khong tim thay container nao tren VPS."
  exit 0
fi

declare -A C_ID C_PID C_ST C_NET C_IMG C_START C_RPOL TUN_APPS TUN_BY_ID APP_PARENT_TUN TUN_HOSTPORT
TUN_NAMES=()
ALL_NON_TUN=()
NOW_TS=$(date +%s)

while IFS='|' read -r cid cpid cst cname cnet cimg cstart rpol; do
  [[ -z "$cid" ]] && continue
  cname="${cname#/}"
  C_ID["$cname"]="$cid"; C_PID["$cname"]="$cpid"; C_ST["$cname"]="$cst"
  C_NET["$cname"]="$cnet"; C_IMG["$cname"]="$cimg"; C_START["$cname"]="$cstart"; C_RPOL["$cname"]="$rpol"

  if [[ "$cname" =~ ^(dind|adnadedind|internetincomewatchtower|gluetun) ]]; then
    continue
  elif [[ "$cname" =~ ^(tun|hev|socks5) ]]; then
    if (( ${#KNOWN_DIR[@]} == 0 )) || [[ -n "${KNOWN_DIR[$cname]:-}" ]]; then
      TUN_NAMES+=("$cname")
      TUN_APPS["$cname"]=""
    fi
  else
    ALL_NON_TUN+=("$cname")
  fi
done < <(docker inspect --type container --format '{{.Id}}|{{.State.Pid}}|{{.State.Status}}|{{.Name}}|{{.HostConfig.NetworkMode}}|{{.Config.Image}}|{{.State.StartedAt}}|{{.HostConfig.RestartPolicy.Name}}' "${ALL_CIDS[@]}" 2>/dev/null)

for t in "${TUN_NAMES[@]}"; do
  TUN_BY_ID["${C_ID[$t]}"]="$t"
done

APP_NAMES=()
SKIP_UNRELATED=0
for a in "${ALL_NON_TUN[@]}"; do
  netm="${C_NET[$a]}"
  matched_tun=""
  if [[ "$netm" == container:* ]]; then
    p="${netm#container:}"
    if [[ -n "${TUN_APPS[$p]+_}" ]]; then
      matched_tun="$p"
    elif [[ -n "${TUN_BY_ID[$p]:-}" ]]; then
      matched_tun="${TUN_BY_ID[$p]}"
    fi
  fi

  if [[ -n "$matched_tun" ]]; then
    APP_NAMES+=("$a")
    APP_PARENT_TUN["$a"]="$matched_tun"
    TUN_APPS["$matched_tun"]+="${TUN_APPS[$matched_tun]:+ }$a"
  elif (( ${#KNOWN_DIR[@]} > 0 )) && [[ -n "${KNOWN_DIR[$a]:-}" ]]; then
    APP_NAMES+=("$a")
  else
    SKIP_UNRELATED=$((SKIP_UNRELATED + 1))
  fi
done

is_sensitive_app() {
  case "${1,,}${2,,}" in
    *honey*|*pawns*|*packetstream*|*packetshare*|*earnfm*|*earnapp*|*repocket*|*depinext*|*ebesucher*|*adnade*|*grass*|*gradient*|*nodepay*|*dawn*|*titan*|*uprock*|*customchrome*|*customfirefox*)
      return 0 ;;
  esac
  return 1
}

tun_has_interface() {
  local t="$1" tpid="${C_PID[$1]:-0}"
  [[ "${C_ST[$t]:-}" == "running" && "$tpid" -gt 0 ]] || return 1
  awk '/tun[0-9]*:|tap[0-9]*:/{f=1} END{exit (f?0:1)}' "/proc/${tpid}/net/dev" 2>/dev/null
}

count_tcp_estab() {
  local pid="$1"
  awk 'FNR>1 && $4=="01" && $3 !~ /^(0100007F|00000000000000000000000001000000|0000000000000000FFFF00000100007F):/ {c++} END{print c+0}' \
    "/proc/$pid/net/tcp" "/proc/$pid/net/tcp6" 2>/dev/null || echo 0
}

# Quet trang thai socket noi bo (chua check Proxy vội)
HEALTHY_BEFORE=0
SKIP_GUARD=0
SKIP_NEW=0
FIRST_PASS_ZERO=()
CANDIDATE_APPS=()
declare -A HEALTHY_BEFORE_SET NEED_TUN_INSPECT

for a in "${APP_NAMES[@]}"; do
  st="${C_ST[$a]:-}"
  pid="${C_PID[$a]:-0}"
  img="${C_IMG[$a]:-}"
  rpol="${C_RPOL[$a]:-}"

  if [[ "$st" != "running" ]] && { is_sensitive_app "$a" "$img" || [[ "$rpol" == "no" ]]; }; then
    SKIP_GUARD=$((SKIP_GUARD + 1))
    continue
  fi

  if [[ "$st" == "running" && -n "${C_START[$a]:-}" ]]; then
    st_ts=$(date -d "${C_START[$a]}" +%s 2>/dev/null || echo 0)
    if (( st_ts > 0 && (NOW_TS - st_ts) < 90 )); then
      SKIP_NEW=$((SKIP_NEW + 1))
      continue
    fi
  fi

  parent_tun="${APP_PARENT_TUN[$a]:-}"
  tun_ok=1
  if [[ -n "$parent_tun" ]]; then
    tun_has_interface "$parent_tun" || tun_ok=0
  fi

  if [[ "$st" == "running" && "$pid" -gt 0 && "$tun_ok" -eq 1 ]]; then
    if (( $(count_tcp_estab "$pid") > 0 )); then
      HEALTHY_BEFORE=$((HEALTHY_BEFORE + 1))
      HEALTHY_BEFORE_SET["$a"]=1
      continue
    fi
    FIRST_PASS_ZERO+=("$a")
  else
    CANDIDATE_APPS+=("$a")
    [[ -n "$parent_tun" ]] && NEED_TUN_INSPECT["$parent_tun"]=1
  fi
done

# Double-check sau 3 giay cho cac node nghi van 0 ESTAB
if (( ${#FIRST_PASS_ZERO[@]} > 0 )); then
  sleep 3
  for a in "${FIRST_PASS_ZERO[@]}"; do
    pid="${C_PID[$a]:-0}"
    if (( pid > 0 )) && (( $(count_tcp_estab "$pid") > 0 )); then
      HEALTHY_BEFORE=$((HEALTHY_BEFORE + 1))
      HEALTHY_BEFORE_SET["$a"]=1
      continue
    fi
    CANDIDATE_APPS+=("$a")
    pt="${APP_PARENT_TUN[$a]:-}"
    [[ -n "$pt" ]] && NEED_TUN_INSPECT["$pt"]=1
  done
fi

# CHI khi co container loi moi inspect & check Proxy tuan tu 1 luong (0 spawn thread)
declare -A PROXY_ALIVE
if (( ${#NEED_TUN_INSPECT[@]} > 0 )); then
  ERR_TUNS=("${!NEED_TUN_INSPECT[@]}")
  cur_tun=""; saw_pf=0; p_raw=""; s5_a=""; s5_p=""
  flush_hp() {
    local tn="$1" pr="$2" sa="$3" sp="$4"
    [[ -z "$tn" ]] && return
    if [[ -z "$pr" && -n "$sa" && -n "$sp" ]]; then
      TUN_HOSTPORT["$tn"]="${sa}:${sp}"
      return
    fi
    if [[ "${C_IMG[$tn]:-}" == xjasonlyu/tun2socks* && "${C_ST[$tn]:-}" == "running" ]]; then
      local ep
      ep=$(docker exec "$tn" sh -c "grep -m1 -- '--proxy ' entrypoint.sh 2>/dev/null | sed 's/.*--proxy[[:space:]]*//;s/[[:space:]\\\\]*$//'" 2>/dev/null || true)
      [[ -n "$ep" ]] && pr="$ep"
    fi
    if [[ -n "$pr" ]]; then
      local rest="${pr#*://}"
      [[ "$rest" == *"@"* ]] && rest="${rest##*@}"
      TUN_HOSTPORT["$tn"]="$rest"
    fi
  }
  while IFS= read -r line; do
    if [[ "$line" == ===TUN===:* ]]; then
      flush_hp "$cur_tun" "$p_raw" "$s5_a" "$s5_p"
      cur_tun="${line#===TUN===:}"; cur_tun="${cur_tun#/}"
      saw_pf=0; p_raw=""; s5_a=""; s5_p=""
    elif [[ "$line" == ARG:* ]]; then
      v="${line#ARG:}"
      if (( saw_pf == 1 )); then p_raw="$v"; saw_pf=0
      elif [[ "$v" == "--proxy" ]]; then saw_pf=1
      elif [[ "$v" == --proxy=* ]]; then p_raw="${v#--proxy=}"
      fi
    elif [[ "$line" == ENV:* ]]; then
      v="${line#ENV:}"
      case "$v" in
        PROXY=*)       p_raw="${v#PROXY=}" ;;
        SOCKS5_ADDR=*) s5_a="${v#SOCKS5_ADDR=}" ;;
        SOCKS5_PORT=*) s5_p="${v#SOCKS5_PORT=}" ;;
      esac
    fi
  done < <(docker inspect --type container --format '===TUN===:{{.Name}}
{{range .Args}}ARG:{{.}}
{{end}}{{range .Config.Env}}ENV:{{.}}
{{end}}' "${ERR_TUNS[@]}" 2>/dev/null)
  flush_hp "$cur_tun" "$p_raw" "$s5_a" "$s5_p"

  # Check Proxy tuan tu 1 luong duy nhat (khong tao nhieu thread, timeout 1s)
  for tn in "${ERR_TUNS[@]}"; do
    hp="${TUN_HOSTPORT[$tn]:-}"
    [[ -z "$hp" ]] && continue
    [[ -n "${PROXY_ALIVE[$hp]+_}" ]] && continue
    ph="${hp%:*}"; ph="${ph#[}"; ph="${ph%]}"
    pp="${hp##*:}"
    if [[ -n "$ph" && "$pp" =~ ^[0-9]+$ ]]; then
      if timeout 1 bash -c "exec 3<>/dev/tcp/${ph}/${pp}" 2>/dev/null; then
        exec 3<&- 3>&- 2>/dev/null || true
        PROXY_ALIVE["$hp"]="1"
      else
        PROXY_ALIVE["$hp"]="0"
      fi
    else
      PROXY_ALIVE["$hp"]="1"
    fi
  done
fi

DEAD_PROXY_LOGS=()
declare -A TUNS_RESTART_SET APPS_AFTER_TUN_SET APPS_ONLY_SET
TUNS_TO_RESTART=()
APPS_AFTER_TUN=()
APPS_ONLY=()
RECOVERED_TARGETS=()

for a in "${CANDIDATE_APPS[@]}"; do
  pt="${APP_PARENT_TUN[$a]:-}"
  if [[ -n "$pt" ]]; then
    hp="${TUN_HOSTPORT[$pt]:-}"
    if [[ -n "$hp" && "${PROXY_ALIVE[$hp]:-1}" == "0" ]]; then
      fdir="${KNOWN_DIR[$pt]:-${KNOWN_DIR[$a]:-unknown}}"
      DEAD_PROXY_LOGS+=("${fdir} | ${pt} | ${hp}")
      continue
    fi
    if ! tun_has_interface "$pt"; then
      if [[ -z "${TUNS_RESTART_SET[$pt]:-}" ]]; then
        TUNS_RESTART_SET["$pt"]=1
        TUNS_TO_RESTART+=("$pt")
        for sibling in ${TUN_APPS[$pt]:-}; do
          if [[ "${C_ST[$sibling]:-}" != "running" ]] && { is_sensitive_app "$sibling" "${C_IMG[$sibling]:-}" || [[ "${C_RPOL[$sibling]:-}" == "no" ]]; }; then
            continue
          fi
          if [[ -z "${APPS_AFTER_TUN_SET[$sibling]:-}" ]]; then
            APPS_AFTER_TUN_SET["$sibling"]=1
            APPS_AFTER_TUN+=("$sibling")
            RECOVERED_TARGETS+=("$sibling")
          fi
        done
      fi
    else
      if [[ -z "${APPS_ONLY_SET[$a]:-}" && -z "${APPS_AFTER_TUN_SET[$a]:-}" ]]; then
        APPS_ONLY_SET["$a"]=1
        APPS_ONLY+=("$a")
        RECOVERED_TARGETS+=("$a")
      fi
    fi
  else
    if [[ -z "${APPS_ONLY_SET[$a]:-}" ]]; then
      APPS_ONLY_SET["$a"]=1
      APPS_ONLY+=("$a")
      RECOVERED_TARGETS+=("$a")
    fi
  fi
done

echo -e " ${C_G}✔ Node dang chay tot (Giu nguyen 100%)      :${C_0} ${HEALTHY_BEFORE}"
echo -e " ${C_Y}⏸ Bo qua (FlapGuard / Restart=no / <90s)    :${C_0} $((SKIP_GUARD + SKIP_NEW)) (Ngoai luong: ${SKIP_UNRELATED})"
echo -e " ${C_R}✖ Node Proxy DIE (Khong restart tranh lag) :${C_0} ${#DEAD_PROXY_LOGS[@]}"
echo -e " ${C_C}↻ Node Proxy LIVE bi dut socket (Se cuu)    :${C_0} ${#RECOVERED_TARGETS[@]} App (Kem ${#TUNS_TO_RESTART[@]} TUN loi)"

if (( ${#DEAD_PROXY_LOGS[@]} > 0 )); then
  echo -e "\n${C_R}--- Danh sach Proxy DIE (khong dong cham) ---${C_0}"
  printf '  - %s\n' "${DEAD_PROXY_LOGS[@]:0:15}"
  (( ${#DEAD_PROXY_LOGS[@]} > 15 )) && echo "  ... (con $(( ${#DEAD_PROXY_LOGS[@]} - 15 )) node nua)"
fi

if (( ${#RECOVERED_TARGETS[@]} == 0 && ${#TUNS_TO_RESTART[@]} == 0 )); then
  echo -e "\n${C_G}=== KHONG CO NODE PROXY LIVE NAO CAN RESTART - HE THONG NHE NHANG 100%! ===${C_0}\n"
  exit 0
fi

# Khoi dong lai nhe nhang theo lo 3 container (nghi 2s) de CPU khong tang tai
BATCH=3
if (( ${#TUNS_TO_RESTART[@]} > 0 )); then
  echo -e "\n${C_Y}[1/3] Dang bat lai ${#TUNS_TO_RESTART[@]} TUN loi (lo ${BATCH}/luot)...${C_0}"
  for ((i=0; i<${#TUNS_TO_RESTART[@]}; i+=BATCH)); do
    batch=("${TUNS_TO_RESTART[@]:i:BATCH}")
    docker restart -t 2 "${batch[@]}" >/dev/null 2>&1 || true
    sleep 2
  done
  sleep 3
fi

if (( ${#APPS_AFTER_TUN[@]} > 0 )); then
  echo -e "${C_Y}[2/3] Dang dong bo lai ${#APPS_AFTER_TUN[@]} App theo TUN moi (lo ${BATCH}/luot)...${C_0}"
  for ((i=0; i<${#APPS_AFTER_TUN[@]}; i+=BATCH)); do
    batch=("${APPS_AFTER_TUN[@]:i:BATCH}")
    docker restart -t 2 "${batch[@]}" >/dev/null 2>&1 || true
    sleep 2
  done
fi

if (( ${#APPS_ONLY[@]} > 0 )); then
  echo -e "${C_Y}[3/3] Dang hoi phuc ${#APPS_ONLY[@]} App mat socket (GIU NGUYEN TUN song, lo ${BATCH}/luot)...${C_0}"
  for ((i=0; i<${#APPS_ONLY[@]}; i+=BATCH)); do
    batch=("${APPS_ONLY[@]:i:BATCH}")
    docker restart -t 2 "${batch[@]}" >/dev/null 2>&1 || true
    sleep 2
  done
fi

#============================================================================
# GIAI DOAN 2: CHO 18 GIAY -> QUET KIEM CHUNG LAI (READ-ONLY & GOM THEO FOLDER)
#============================================================================
echo -e "\n${C_C}================ [GIAI DOAN 2: CHO 18 GIAY & QUET KIEM CHUNG LAI] ================${C_0}"
sleep 18

declare -A V_ST V_PID
while IFS='|' read -r vname vst vpid; do
  vname="${vname#/}"
  V_ST["$vname"]="$vst"
  V_PID["$vname"]="$vpid"
done < <(docker inspect --type container --format '{{.Name}}|{{.State.Status}}|{{.State.Pid}}' "${ALL_CIDS[@]}" 2>/dev/null)

collateral_err=0
for h in "${!HEALTHY_BEFORE_SET[@]}"; do
  [[ "${V_ST[$h]:-}" != "running" ]] && collateral_err=$((collateral_err + 1))
done

rec_ok=0; rec_fail=0
declare -A FAIL_BY_DIR
for r in "${RECOVERED_TARGETS[@]}"; do
  rst="${V_ST[$r]:-}"
  rpid="${V_PID[$r]:-0}"
  pt="${APP_PARENT_TUN[$r]:-}"
  tun_live=1
  if [[ -n "$pt" ]]; then
    tpid="${V_PID[$pt]:-0}"
    if [[ "${V_ST[$pt]:-}" != "running" || "$tpid" -le 0 ]] || ! awk '/tun[0-9]*:|tap[0-9]*:/{f=1} END{exit (f?0:1)}' "/proc/${tpid}/net/dev" 2>/dev/null; then
      tun_live=0
    fi
  fi
  if [[ "$rst" == "running" && "$rpid" -gt 0 && "$tun_live" -eq 1 ]] && (( $(count_tcp_estab "$rpid") > 0 )); then
    rec_ok=$((rec_ok + 1))
  else
    rec_fail=$((rec_fail + 1))
    fdir="${KNOWN_DIR[$r]:-${KNOWN_DIR[$pt]:-unknown}}"
    FAIL_BY_DIR["$fdir"]=$(( ${FAIL_BY_DIR["$fdir"]:-0} + 1 ))
  fi
done

echo -e " ${C_G}✔ Node khoe ban dau bi anh huong :${C_0} ${collateral_err} (An toan tuyet doi)"
echo -e " ${C_G}✔ Node da hoi phuc thanh cong    :${C_0} ${rec_ok} / ${#RECOVERED_TARGETS[@]}"
echo -e " $([ $rec_fail -eq 0 ] && echo -e "${C_G}" || echo -e "${C_R}")✖ Node van 0 ESTAB sau 18s     :${C_0} ${rec_fail}"

if (( rec_fail > 0 )); then
  echo -e "\n${C_Y}--- Tong hop theo Folder bi loi Auth / Het Data / Loi Token ---${C_0}"
  for fd in "${!FAIL_BY_DIR[@]}"; do
    echo -e "  ${C_R}[!]${C_0} ${fd}  (${FAIL_BY_DIR[$fd]} node van 0 ESTAB)"
  done
else
  echo -e "\n${C_G}=== HOAN HAO! 100% NODE PROXY LIVE DA KET NOI & CHAY ON DINH! ===${C_0}\n"
fi
SMARTHEAL_LITE
```

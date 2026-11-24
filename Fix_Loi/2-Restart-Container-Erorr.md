# Restart lại Traffmonetier khi thiếu device IP

```
sudo bash -c 'for c in $(docker ps --filter "name=traffmon" --format "{{.Names}}"); do docker restart "$c" >/dev/null 2>&1; echo " -> Đã làm mới: $c"; sleep 1; done'
```
# Restart lại folder được chỉ định

```
curl -4 -sSL "https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/List_Proxy/fix_bandwidth.sh?v=$(date +%s)" -o fix_bandwidth.sh && chmod +x fix_bandwidth.sh && ./fix_bandwidth.sh
```

# Restart lại các Container Lỗi (ko ảnh hưởng tới các container đang chạy)

```
sudo bash <<'SMARTHEAL_PRO'
set -o pipefail

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

if [ "$(cat /proc/sys/net/ipv4/tcp_mtu_probing 2>/dev/null || echo 0)" != "1" ]; then
  sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1 || true
  if [ -f /etc/sysctl.d/99-internetincome.conf ] && ! grep -q "tcp_mtu_probing" /etc/sysctl.d/99-internetincome.conf; then
    echo "net.ipv4.tcp_mtu_probing = 1" >> /etc/sysctl.d/99-internetincome.conf
  fi
fi

declare -A KNOWN_DIR
while IFS= read -r cfile; do
  d=$(dirname "$cfile")
  while IFS= read -r cn || [[ -n "$cn" ]]; do
    cn="${cn//$'\r'/}"
    [[ -n "$cn" ]] && KNOWN_DIR["$cn"]="$d"
  done < "$cfile"
done < <(find /root /home /opt /srv /mnt /data -maxdepth 6 -name "containernames.txt" -type f 2>/dev/null)

echo -e "\n${C_C}================ [GIAI DOAN 1: QUET KERNEL + CHECK AUTH PROXY TU DAU] ================${C_0}"

mapfile -t ALL_CIDS < <(docker ps -aq 2>/dev/null)
if (( ${#ALL_CIDS[@]} == 0 )); then
  echo "Khong tim thay container nao tren VPS."
  exit 0
fi

declare -A C_ID C_PID C_ST C_NET C_IMG C_START C_RPOL TUN_APPS TUN_BY_ID APP_PARENT_TUN TUN_PROXY_RAW TUN_MASKED
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

declare -A PROXY_STATUS PROXY_REASON
if (( ${#NEED_TUN_INSPECT[@]} > 0 )); then
  ERR_TUNS=("${!NEED_TUN_INSPECT[@]}")
  cur_tun=""; saw_pf=0; p_raw=""; s5_a=""; s5_p=""; s5_u=""; s5_pw=""

  flush_proxy_rec() {
    local tn="$1" pr="$2" sa="$3" sp="$4" su="$5" spw="$6"
    [[ -z "$tn" ]] && return
    if [[ -z "$pr" && -n "$sa" && -n "$sp" ]]; then
      if [[ -n "$su" && -n "$spw" ]]; then
        pr="socks5://${su}:${spw}@${sa}:${sp}"
      else
        pr="socks5://${sa}:${sp}"
      fi
    fi
    if [[ "${C_IMG[$tn]:-}" == xjasonlyu/tun2socks* && "${C_ST[$tn]:-}" == "running" ]]; then
      local ep
      ep=$(docker exec "$tn" sh -c "grep -m1 -- '--proxy ' entrypoint.sh 2>/dev/null | sed 's/.*--proxy[[:space:]]*//;s/[[:space:]\\\\]*$//'" 2>/dev/null || true)
      [[ -n "$ep" ]] && pr="$ep"
    fi
    TUN_PROXY_RAW["$tn"]="$pr"
    if [[ -n "$pr" ]]; then
      local proto="" rest="$pr"
      [[ "$pr" == *"://"* ]] && { proto="${pr%%://*}://"; rest="${pr#*://}"; }
      if [[ "$rest" == *"@"* ]]; then
        TUN_MASKED["$tn"]="${proto}${rest##*@}"
      else
        TUN_MASKED["$tn"]="${proto}${rest}"
      fi
    fi
  }

  while IFS= read -r line; do
    if [[ "$line" == ===TUN===:* ]]; then
      flush_proxy_rec "$cur_tun" "$p_raw" "$s5_a" "$s5_p" "$s5_u" "$s5_pw"
      cur_tun="${line#===TUN===:}"; cur_tun="${cur_tun#/}"
      saw_pf=0; p_raw=""; s5_a=""; s5_p=""; s5_u=""; s5_pw=""
    elif [[ "$line" == ARG:* ]]; then
      v="${line#ARG:}"
      if (( saw_pf == 1 )); then p_raw="$v"; saw_pf=0
      elif [[ "$v" == "--proxy" ]]; then saw_pf=1
      elif [[ "$v" == --proxy=* ]]; then p_raw="${v#--proxy=}"
      fi
    elif [[ "$line" == ENV:* ]]; then
      v="${line#ENV:}"
      case "$v" in
        PROXY=*)           p_raw="${v#PROXY=}" ;;
        SOCKS5_ADDR=*)     s5_a="${v#SOCKS5_ADDR=}" ;;
        SOCKS5_PORT=*)     s5_p="${v#SOCKS5_PORT=}" ;;
        SOCKS5_USERNAME=*) s5_u="${v#SOCKS5_USERNAME=}" ;;
        SOCKS5_PASSWORD=*) s5_pw="${v#SOCKS5_PASSWORD=}" ;;
      esac
    fi
  done < <(docker inspect --type container --format '===TUN===:{{.Name}}
{{range .Args}}ARG:{{.}}
{{end}}{{range .Config.Env}}ENV:{{.}}
{{end}}' "${ERR_TUNS[@]}" 2>/dev/null)
  flush_proxy_rec "$cur_tun" "$p_raw" "$s5_a" "$s5_p" "$s5_u" "$s5_pw"

  echo "  Dang kiem tra xac thuc Proxy cho ${#ERR_TUNS[@]} TUN nghi van (1 luong nhe nhang)..."
  for tn in "${ERR_TUNS[@]}"; do
    pr="${TUN_PROXY_RAW[$tn]:-}"
    [[ -z "$pr" ]] && continue
    [[ -n "${PROXY_STATUS[$pr]+_}" ]] && continue

    if command -v curl >/dev/null 2>&1; then
      http_code=$(curl -4 -s -o /dev/null -w "%{http_code}" -m 4 --proxy "$pr" "http://cp.cloudflare.com/generate_204" 2>/dev/null)
      rc=$?
      if (( rc == 0 )) && [[ "$http_code" =~ ^(200|204|301|302)$ ]]; then
        PROXY_STATUS["$pr"]="1"
        PROXY_REASON["$pr"]="OK"
      else
        PROXY_STATUS["$pr"]="0"
        case "$rc" in
          97) PROXY_REASON["$pr"]="Tu choi Auth/Het Data (SOCKS5 rc=97)" ;;
          56) PROXY_REASON["$pr"]="Loi Proxy HTTP/407 (rc=56)" ;;
          28) PROXY_REASON["$pr"]="Timeout (Proxy khong phan hoi)" ;;
          7)  PROXY_REASON["$pr"]="Khong ket noi duoc Proxy (rc=7)" ;;
          *)  PROXY_REASON["$pr"]="Proxy loi (curl rc=${rc}, http=${http_code})" ;;
        esac
      fi
    else
      PROXY_STATUS["$pr"]="1"
      PROXY_REASON["$pr"]="NO_CURL"
    fi
  done
fi

declare -A DEAD_FOLDER_CNT DEAD_FOLDER_REASON TUNS_RESTART_SET APPS_AFTER_TUN_SET APPS_ONLY_SET
DEAD_PROXY_COUNT=0
TUNS_TO_RESTART=()
APPS_AFTER_TUN=()
APPS_ONLY=()
RECOVERED_TARGETS=()

for a in "${CANDIDATE_APPS[@]}"; do
  pt="${APP_PARENT_TUN[$a]:-}"
  if [[ -n "$pt" ]]; then
    pr="${TUN_PROXY_RAW[$pt]:-}"
    if [[ -n "$pr" && "${PROXY_STATUS[$pr]:-1}" == "0" ]]; then
      DEAD_PROXY_COUNT=$((DEAD_PROXY_COUNT + 1))
      fdir="${KNOWN_DIR[$pt]:-${KNOWN_DIR[$a]:-unknown}}"
      DEAD_FOLDER_CNT["$fdir"]=$(( ${DEAD_FOLDER_CNT["$fdir"]:-0} + 1 ))
      DEAD_FOLDER_REASON["$fdir"]="${PROXY_REASON[$pr]:-Proxy_Dead}"
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

echo -e " ${C_G}✔ Node dang chay tot (Giu nguyen 100%)          :${C_0} ${HEALTHY_BEFORE}"
echo -e " ${C_Y}⏸ Bo qua (FlapGuard / Restart=no / <90s)        :${C_0} $((SKIP_GUARD + SKIP_NEW)) (Ngoai luong: ${SKIP_UNRELATED})"
echo -e " ${C_R}✖ Node Proxy LOI/HET DATA (BO QUA KHONG RESTART):${C_0} ${DEAD_PROXY_COUNT}"
echo -e " ${C_C}↻ Node Proxy SONG that su bi dut socket (Se cuu):${C_0} ${#RECOVERED_TARGETS[@]} App (Kem ${#TUNS_TO_RESTART[@]} TUN loi)"

if (( DEAD_PROXY_COUNT > 0 )); then
  echo -e "\n${C_R}--- Cac Folder bi loi Proxy ngay tu buoc kiem tra (KHONG DONG CHAM) ---${C_0}"
  for fd in "${!DEAD_FOLDER_CNT[@]}"; do
    echo -e "  ${C_R}[!]${C_0} ${fd} (${DEAD_FOLDER_CNT[$fd]} node) -> ${C_Y}${DEAD_FOLDER_REASON[$fd]}${C_0}"
  done
fi

if (( ${#RECOVERED_TARGETS[@]} == 0 && ${#TUNS_TO_RESTART[@]} == 0 )); then
  echo -e "\n${C_G}=== HOAN TAT! KHONG CO NODE PROXY LIVE NAO CAN RESTART! ===${C_0}\n"
  exit 0
fi

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
  echo -e "\n${C_Y}--- Cac Folder co node van 0 ESTAB sau 18s (nghi van Token/Server app) ---${C_0}"
  for fd in "${!FAIL_BY_DIR[@]}"; do
    echo -e "  ${C_R}[!]${C_0} ${fd} (${FAIL_BY_DIR[$fd]} node)"
  done
else
  echo -e "\n${C_G}=== HOAN HAO! 100% NODE PROXY LIVE DA KET NOI & CHAY ON DINH! ===${C_0}\n"
fi
SMARTHEAL_PRO
```

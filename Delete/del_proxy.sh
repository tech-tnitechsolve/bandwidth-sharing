#!/usr/bin/env bash
#============================================================================
#  del_proxy.sh — MASTER PROXY DELETER (WINSCP / VSCODE READY)
#  - Đặt cùng thư mục với delete_proxies.txt (ví dụ thư mục Delete/)
#  - Quét toàn bộ folder InternetIncome trên VPS -> xóa đúng TUN + App
#  - Bảo toàn 100% các Proxy còn lại, không đụng dind/watchtower/hệ thống
#  - Xóa xong tự dọn sạch file delete_proxies.txt (giữ nguyên quyền WinSCP)
#============================================================================
set -uo pipefail

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'
  C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi

log()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!!]${C_0} $*"; }
err()  { echo -e "${C_R}[XX]${C_0} $*" >&2; }

LIST_FILE=""
ONLY_DIR=""
AUTO_YES=0
DRY_RUN=0
PURGE_DATA=0
ALLOW_MULTI_FOLDER=0

STATE_ROOT="/var/lib/ii-del-proxy"
BACKUP_ROOT="${STATE_ROOT}/backups"
HISTORY_ROOT="${STATE_ROOT}/history"
LOCK_FILE="/run/ii-del-proxy.lock"

usage() {
  cat <<'USAGE'
Cach dung:
  1. Dan proxy can xoa vao file delete_proxies.txt (cung thu muc voi del_proxy.sh)
  2. Chay xem truoc (an toan 100%, chua xoa gi):
       sudo bash del_proxy.sh --dry-run
  3. Chay xoa that:
       sudo bash del_proxy.sh

Tuy chon:
  -f, --file <path>      Chi dinh file list proxy khac
  -d, --dir <path>       Chi gioi han tim trong 1 folder InternetIncome cu the
      --multi-folder     Cho phep xoa neu 1 proxy trung o nhieu folder/TUN
      --purge-data       Xoa them thu muc data<idx>/node<idx> cua RIENG proxy bi xoa
      --dry-run          Chi kiem tra & in ra ke hoach xoa, KHONG xoa that
  -y, --yes              Bo qua buoc hoi xac nhan (y/N)
  -h, --help             Hien thi huong dan
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)       LIST_FILE="${2:-}"; shift 2 ;;
    --file=*)        LIST_FILE="${1#*=}"; shift ;;
    -d|--dir)        ONLY_DIR="${2:-}"; shift 2 ;;
    --dir=*)         ONLY_DIR="${1#*=}"; shift ;;
    --multi-folder)  ALLOW_MULTI_FOLDER=1; shift ;;
    --purge-data)    PURGE_DATA=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -y|--yes)        AUTO_YES=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               err "Tham so khong hop le: $1"; usage; exit 1 ;;
  esac
done

#----------------------------------------------------------------------------
# 0. Kiem tra quyen Docker & khoa chong chay song song
#----------------------------------------------------------------------------
if ! docker info >/dev/null 2>&1; then
  err "Khong the ket noi Docker. Hay chay bang quyen root/sudo: sudo bash $0"
  exit 1
fi

mkdir -p "$BACKUP_ROOT" "$HISTORY_ROOT" 2>/dev/null || true
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  err "Dang co mot tien trinh xoa proxy khac dang chay! Vui long cho hoan tat."
  exit 1
fi

#----------------------------------------------------------------------------
# 1. Tu dong tim file delete_proxies.txt (uu tien cung thu muc voi del_proxy.sh)
#----------------------------------------------------------------------------
resolve_list_file() {
  if [[ -n "$LIST_FILE" ]]; then
    if [[ ! -f "$LIST_FILE" ]]; then
      err "Khong tim thay file chi dinh: $LIST_FILE"
      exit 1
    fi
    return
  fi

  local script_dir
  script_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
  local candidates=("${script_dir}/delete_proxies.txt" "$PWD/delete_proxies.txt")

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    local sudo_home
    sudo_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
    [[ -n "$sudo_home" ]] && candidates+=("${sudo_home}/delete_proxies.txt")
  fi
  candidates+=("/root/delete_proxies.txt")

  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then
      LIST_FILE="$c"
      return
    fi
  done

  err "Khong tim thay file 'delete_proxies.txt' trong ${script_dir} hoac ${PWD}!"
  exit 1
}

resolve_list_file
log "Dang doc danh sach tu file: ${C_C}${LIST_FILE}${C_0}"

#----------------------------------------------------------------------------
# 2. Kiem tra cu phap tung dong trong delete_proxies.txt (Chong nhap nham)
#----------------------------------------------------------------------------
validate_entry_syntax() {
  local s="$1"
  # 1. Full URL: protocol://...host:port
  if [[ "$s" =~ ^(http|https|socks4|socks4a|socks5|socks5h|ss)://.+:([0-9]{1,5})$ ]]; then
    local p="${BASH_REMATCH[2]}"
    (( p >= 1 && p <= 65535 )) && return 0
  fi
  # 2. IPv4:PORT hoac domain:PORT
  if [[ "$s" =~ ^[a-zA-Z0-9._-]+:([0-9]{1,5})$ ]]; then
    local p="${BASH_REMATCH[1]}"
    (( p >= 1 && p <= 65535 )) && return 0
  fi
  # 3. [IPv6]:PORT
  if [[ "$s" =~ ^\[[0-9a-fA-F:]+\]:([0-9]{1,5})$ ]]; then
    local p="${BASH_REMATCH[1]}"
    (( p >= 1 && p <= 65535 )) && return 0
  fi
  # 4. IPv4 thuan
  if [[ "$s" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    (( ${BASH_REMATCH[1]} <= 255 && ${BASH_REMATCH[2]} <= 255 && ${BASH_REMATCH[3]} <= 255 && ${BASH_REMATCH[4]} <= 255 )) && return 0
  fi
  # 5. IPv6 thuan
  if [[ "$s" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; then
    return 0
  fi
  # 6. Ten TUN chinh xac (tun + 32 ky tu hex + so)
  if [[ "$s" =~ ^tun[a-f0-9]{32}[0-9]+$ ]]; then
    return 0
  fi
  return 1
}

RAW_ENTRIES=()
line_no=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line_no=$((line_no + 1))
  if (( line_no == 1 )); then
    line="${line#$'\xEF\xBB\xBF'}"
  fi
  line="${line//$'\r'/}"
  line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" || "$line" == \#* ]] && continue

  if ! validate_entry_syntax "$line"; then
    err "Dong ${line_no} khong hop le trong ${LIST_FILE}: '${line}'"
    err "De bao ve an toan tuyet doi, script TU CHOI chay khi co dong sai dinh dang."
    exit 1
  fi
  RAW_ENTRIES+=("$line")
done < "$LIST_FILE"

if (( ${#RAW_ENTRIES[@]} == 0 )); then
  warn "File ${LIST_FILE} hien dang trong (chua co proxy nao de xoa)."
  exit 0
fi

TARGETS=()
declare -A SEEN_TARGET
for e in "${RAW_ENTRIES[@]}"; do
  if [[ -z "${SEEN_TARGET[$e]:-}" ]]; then
    SEEN_TARGET["$e"]=1
    TARGETS+=("$e")
  fi
done

#----------------------------------------------------------------------------
# 3. Quet toan bo folder InternetIncome tren VPS
#----------------------------------------------------------------------------
SCAN_DIRS=()
if [[ -n "$ONLY_DIR" ]]; then
  ONLY_DIR="$(cd "$ONLY_DIR" 2>/dev/null && pwd || true)"
  if [[ -z "$ONLY_DIR" || ! -f "$ONLY_DIR/containernames.txt" ]]; then
    err "Thu muc '$ONLY_DIR' khong ton tai hoac khong co containernames.txt"
    exit 1
  fi
  SCAN_DIRS=("$ONLY_DIR")
else
  mapfile -t SCAN_DIRS < <(
    find /root /home /opt /srv /mnt /data -maxdepth 6 -name "containernames.txt" -type f 2>/dev/null \
      | xargs -r -n1 dirname | sort -u
  )
fi

if (( ${#SCAN_DIRS[@]} == 0 )); then
  err "Khong tim thay folder InternetIncome nao (co containernames.txt) tren VPS."
  exit 1
fi

#----------------------------------------------------------------------------
# 4. Inspect toan bo container tren VPS chi trong 2 lenh (chinh xac 100%)
#----------------------------------------------------------------------------
declare -A CTR_ID CTR_STATUS CTR_NETMODE CTR_IMAGE
mapfile -t ALL_CIDS < <(docker ps -aq 2>/dev/null)
if (( ${#ALL_CIDS[@]} > 0 )); then
  while IFS='|' read -r cid cname cstatus cnet cimg; do
    [[ -z "$cid" ]] && continue
    cname="${cname#/}"
    CTR_ID["$cname"]="$cid"
    CTR_STATUS["$cname"]="$cstatus"
    CTR_NETMODE["$cname"]="$cnet"
    CTR_IMAGE["$cname"]="$cimg"
  done < <(docker inspect --type container --format '{{.Id}}|{{.Name}}|{{.State.Status}}|{{.HostConfig.NetworkMode}}|{{.Config.Image}}' "${ALL_CIDS[@]}" 2>/dev/null)
fi

declare -A TUN_DIR TUN_INDEX TUN_PROXY_RAW TUN_HOST TUN_PORT TUN_HOSTPORT TUN_MASKED TUN_APPS
ALL_EXISTING_TUNS=()

for dir in "${SCAN_DIRS[@]}"; do
  cfile="${dir}/containernames.txt"
  sfile="${dir}/connection_state.txt"
  uid=""
  [[ -f "$sfile" ]] && uid=$(head -n1 "$sfile" | tr -d '\r\n[:space:]')

  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    TUN_DIR["$t"]="$dir"
    TUN_APPS["$t"]=""
    if [[ -n "$uid" && "$t" == "tun${uid}"* ]]; then
      TUN_INDEX["$t"]="${t#tun${uid}}"
    elif [[ "$t" =~ ^tun[a-f0-9]{32}([0-9]+)$ ]]; then
      TUN_INDEX["$t"]="${BASH_REMATCH[1]}"
    else
      TUN_INDEX["$t"]=""
    fi
    if [[ -n "${CTR_ID[$t]:-}" ]]; then
      ALL_EXISTING_TUNS+=("$t")
    fi
  done < <(grep -E '^tun' "$cfile" 2>/dev/null | sed 's/\r$//' | awk 'NF && !seen[$0]++')
done

if (( ${#ALL_EXISTING_TUNS[@]} == 0 )); then
  warn "Khong co TUN container nao dang ton tai trong Docker."
  exit 0
fi

parse_proxy_fields() {
  local tname="$1" raw="$2"
  TUN_PROXY_RAW["$tname"]="$raw"
  if [[ -z "$raw" ]]; then
    TUN_HOST["$tname"]=""; TUN_PORT["$tname"]=""; TUN_HOSTPORT["$tname"]=""
    TUN_MASKED["$tname"]="(khong doc duoc)"
    return
  fi
  local proto="" rest="$raw" hostport="" creds=""
  if [[ "$raw" == *"://"* ]]; then
    proto="${raw%%://*}://"
    rest="${raw#*://}"
  fi
  if [[ "$rest" == *"@"* ]]; then
    creds="${rest%@*}"
    hostport="${rest##*@}"
    local user="${creds%%:*}"
    TUN_MASKED["$tname"]="${proto}${user}:***@${hostport}"
  else
    hostport="$rest"
    TUN_MASKED["$tname"]="${proto}${hostport}"
  fi
  TUN_HOSTPORT["$tname"]="$hostport"
  TUN_HOST["$tname"]="${hostport%:*}"
  TUN_PORT["$tname"]="${hostport##*:}"
}

flush_tun_record() {
  local tname="$1" p_raw="$2" s5_addr="$3" s5_port="$4" s5_user="$5" s5_pass="$6"
  [[ -z "$tname" ]] && return
  if [[ -z "$p_raw" && -n "$s5_addr" && -n "$s5_port" ]]; then
    if [[ -n "$s5_user" && -n "$s5_pass" ]]; then
      p_raw="socks5://${s5_user}:${s5_pass}@${s5_addr}:${s5_port}"
    else
      p_raw="socks5://${s5_addr}:${s5_port}"
    fi
  fi
  if [[ "${CTR_IMAGE[$tname]:-}" == xjasonlyu/tun2socks* && "${CTR_STATUS[$tname]:-}" == "running" ]]; then
    local ep_proxy
    ep_proxy=$(docker exec "$tname" sh -c "grep -m1 -- '--proxy ' entrypoint.sh 2>/dev/null | sed 's/.*--proxy[[:space:]]*//;s/[[:space:]\\\\]*$//'" 2>/dev/null || true)
    [[ -n "$ep_proxy" ]] && p_raw="$ep_proxy"
  fi
  parse_proxy_fields "$tname" "$p_raw"
}

cur_tun=""; saw_proxy_flag=0
p_raw=""; s5_addr=""; s5_port=""; s5_user=""; s5_pass=""

while IFS= read -r line; do
  if [[ "$line" == ===TUN_RECORD_START===:* ]]; then
    flush_tun_record "$cur_tun" "$p_raw" "$s5_addr" "$s5_port" "$s5_user" "$s5_pass"
    cur_tun="${line#===TUN_RECORD_START===:}"
    cur_tun="${cur_tun#/}"
    saw_proxy_flag=0
    p_raw=""; s5_addr=""; s5_port=""; s5_user=""; s5_pass=""
  elif [[ "$line" == ARG:* ]]; then
    val="${line#ARG:}"
    if (( saw_proxy_flag == 1 )); then
      p_raw="$val"; saw_proxy_flag=0
    elif [[ "$val" == "--proxy" ]]; then
      saw_proxy_flag=1
    elif [[ "$val" == --proxy=* ]]; then
      p_raw="${val#--proxy=}"
    fi
  elif [[ "$line" == ENV:* ]]; then
    val="${line#ENV:}"
    case "$val" in
      PROXY=*)           p_raw="${val#PROXY=}" ;;
      SOCKS5_ADDR=*)     s5_addr="${val#SOCKS5_ADDR=}" ;;
      SOCKS5_PORT=*)     s5_port="${val#SOCKS5_PORT=}" ;;
      SOCKS5_USERNAME=*) s5_user="${val#SOCKS5_USERNAME=}" ;;
      SOCKS5_PASSWORD=*) s5_pass="${val#SOCKS5_PASSWORD=}" ;;
    esac
  fi
done < <(docker inspect --type container --format '===TUN_RECORD_START===:{{.Name}}
{{range .Args}}ARG:{{.}}
{{end}}{{range .Config.Env}}ENV:{{.}}
{{end}}' "${ALL_EXISTING_TUNS[@]}" 2>/dev/null)
flush_tun_record "$cur_tun" "$p_raw" "$s5_addr" "$s5_port" "$s5_user" "$s5_pass"

# Map toan bo App container theo tung TUN qua NetworkMode (bo qua dind/watchtower/tun)
declare -A TUN_BY_ID
for t in "${ALL_EXISTING_TUNS[@]}"; do
  TUN_BY_ID["${CTR_ID[$t]}"]="$t"
done

for cname in "${!CTR_NETMODE[@]}"; do
  # Khoa an toan kep: khong bao gio gan nhan app cho cac container he thong/dieu phoi
  case "$cname" in
    tun*|dind*|adnadedind*|internetincomewatchtower*|gluetun*) continue ;;
  esac
  netm="${CTR_NETMODE[$cname]}"
  [[ "$netm" == container:* ]] || continue
  parent="${netm#container:}"
  matched_tun=""
  if [[ -n "${TUN_APPS[$parent]+_}" ]]; then
    matched_tun="$parent"
  elif [[ -n "${TUN_BY_ID[$parent]:-}" ]]; then
    matched_tun="${TUN_BY_ID[$parent]}"
  fi
  if [[ -n "$matched_tun" ]]; then
    if [[ -z "${TUN_APPS[$matched_tun]}" ]]; then
      TUN_APPS["$matched_tun"]="$cname"
    else
      TUN_APPS["$matched_tun"]="${TUN_APPS[$matched_tun]} $cname"
    fi
  fi
done

#----------------------------------------------------------------------------
# 5. Doi chieu tung dong trong list voi TUN thuc te
#----------------------------------------------------------------------------
SELECTED_TUNS=()
declare -A SELECTED_SET
declare -A TARGET_TO_TUNS
UNMATCHED_TARGETS=()
AMBIGUOUS_ERRORS=0

for target in "${TARGETS[@]}"; do
  matched=()

  for t in "${ALL_EXISTING_TUNS[@]}"; do
    [[ "$target" == "$t" ]] && matched+=("$t")
  done

  if (( ${#matched[@]} == 0 )); then
    for t in "${ALL_EXISTING_TUNS[@]}"; do
      [[ -n "${TUN_PROXY_RAW[$t]:-}" && "$target" == "${TUN_PROXY_RAW[$t]}" ]] && matched+=("$t")
    done
  fi

  if (( ${#matched[@]} == 0 )); then
    for t in "${ALL_EXISTING_TUNS[@]}"; do
      [[ -n "${TUN_HOSTPORT[$t]:-}" && "$target" == "${TUN_HOSTPORT[$t]}" ]] && matched+=("$t")
    done
  fi

  if (( ${#matched[@]} == 0 )); then
    for t in "${ALL_EXISTING_TUNS[@]}"; do
      [[ -n "${TUN_HOST[$t]:-}" && "$target" == "${TUN_HOST[$t]}" ]] && matched+=("$t")
    done
    if (( ${#matched[@]} > 1 )); then
      declare -A _uniq_hp=()
      for m in "${matched[@]}"; do _uniq_hp["${TUN_HOSTPORT[$m]}"]=1; done
      if (( ${#_uniq_hp[@]} > 1 )); then
        err "NGUY HIEM: IP '${target}' khop voi ${#matched[@]} proxy KHAC PORT:"
        for m in "${matched[@]}"; do
          echo "   - [${TUN_DIR[$m]}] $m -> ${TUN_MASKED[$m]}"
        done
        err "Vui long ghi ro IP:PORT trong ${LIST_FILE}!"
        AMBIGUOUS_ERRORS=1
        unset _uniq_hp
        continue
      fi
      unset _uniq_hp
    fi
  fi

  if (( ${#matched[@]} > 1 && ALLOW_MULTI_FOLDER == 0 )); then
    err "CANH BAO: '${target}' xuat hien o ${#matched[@]} TUN khac nhau:"
    for m in "${matched[@]}"; do
      echo "   - [${TUN_DIR[$m]}] $m -> ${TUN_MASKED[$m]}"
    done
    err "Vui long ghi full proxy (user:pass@ip:port), hoac chay -d <folder>, hoac --multi-folder."
    AMBIGUOUS_ERRORS=1
    continue
  fi

  if (( ${#matched[@]} == 0 )); then
    UNMATCHED_TARGETS+=("$target")
  else
    TARGET_TO_TUNS["$target"]="${matched[*]}"
    for m in "${matched[@]}"; do
      if [[ -z "${SELECTED_SET[$m]:-}" ]]; then
        SELECTED_SET["$m"]=1
        SELECTED_TUNS+=("$m")
      fi
    done
  fi
done

if (( AMBIGUOUS_ERRORS == 1 )); then
  err "Da dung lai vi co proxy mo ho/trung lap. Chua co container nao bi xoa."
  exit 1
fi

if (( ${#UNMATCHED_TARGETS[@]} > 0 )); then
  warn "Cac dong sau KHONG tim thay container TUN nao tuong ung tren VPS (se giu lai trong ${LIST_FILE}):"
  for u in "${UNMATCHED_TARGETS[@]}"; do
    echo "   - $u"
  done
  echo ""
fi

if (( ${#SELECTED_TUNS[@]} == 0 )); then
  warn "Khong co TUN container nao khop de xoa. Ket thuc an toan."
  exit 0
fi

#----------------------------------------------------------------------------
# 6. Hien thi ke hoach chi tiet & xac nhan
#----------------------------------------------------------------------------
TOTAL_VPS_TUNS=${#ALL_EXISTING_TUNS[@]}
echo -e "${C_Y}==================== [KE HOACH XOA PROXY CHI DINH TOAN VPS] ====================${C_0}"
echo -e "  File list : ${C_C}${LIST_FILE}${C_0}"
echo -e "  Giu nguyen: ${C_G}$(( TOTAL_VPS_TUNS - ${#SELECTED_TUNS[@]} ))/${TOTAL_VPS_TUNS} TUN con lai tren VPS (KHONG CAN THIEP 100%)${C_0}"
echo -e "  Se xoa    : ${C_R}${#SELECTED_TUNS[@]} TUN${C_0} va cac App container dinh kem:"
echo ""

for t in "${SELECTED_TUNS[@]}"; do
  echo -e "  ${C_R}[-] Folder:${C_0} ${TUN_DIR[$t]}"
  echo -e "      ${C_R}TUN   :${C_0} $t (${CTR_STATUS[$t]:-?}) | ${C_Y}Proxy:${C_0} ${TUN_MASKED[$t]}"
  if [[ -n "${TUN_APPS[$t]:-}" ]]; then
    for a in ${TUN_APPS[$t]}; do
      echo -e "      └── App: $a (${CTR_STATUS[$a]:-?})"
    done
  else
    echo "      └── (Khong co app container nao gan vao TUN nay)"
  fi
done
echo -e "${C_Y}================================================================================${C_0}"

if (( DRY_RUN == 1 )); then
  warn "[DRY-RUN] Che do xem truoc - Khong xoa container va khong sua file nao."
  exit 0
fi

if (( AUTO_YES != 1 )); then
  read -r -p "Xac nhan xoa chinh xac cac Proxy/Container tren? (y/N): " confirm </dev/tty
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "Da huy thao tac."; exit 0 ;;
  esac
fi

#----------------------------------------------------------------------------
# 7. Thuc thi xoa an toan (App truoc -> xac nhan sach -> TUN sau)
#----------------------------------------------------------------------------
TS=$(date +%Y%m%d_%H%M%S)
cp -a "$LIST_FILE" "${HISTORY_ROOT}/delete_proxies_${TS}.txt" 2>/dev/null || true

declare -A DELETED_TUN_OK
declare -A DIR_DEL_CONTAINERS
declare -A DIR_DEL_PROXIES
declare -A DIR_DEL_INDICES
declare -A TOUCHED_DIRS

for t in "${SELECTED_TUNS[@]}"; do
  d="${TUN_DIR[$t]}"
  app_fail=0
  removed_apps=()

  if [[ -n "${TUN_APPS[$t]:-}" ]]; then
    for a in ${TUN_APPS[$t]}; do
      docker update --restart=no "$a" >/dev/null 2>&1 || true
      if [[ "${CTR_STATUS[$a]:-}" == "running" ]]; then
        docker stop -t 3 "$a" >/dev/null 2>&1 || true
      fi
      docker rm -f "$a" >/dev/null 2>&1 || true

      if docker inspect --type container "$a" >/dev/null 2>&1; then
        err "KHONG THE XOA App '$a' -> GIU LAI TUN '$t' de bao ve an toan!"
        app_fail=1
      else
        rm -f "/var/lib/ii-flapguard/${a}.state" "/var/lib/ii-repocket-watchdog/${a}.state" 2>/dev/null || true
        removed_apps+=("$a")
        log "Da xoa App : $a"
      fi
    done
  fi

  if (( app_fail == 1 )); then
    continue
  fi

  docker update --restart=no "$t" >/dev/null 2>&1 || true
  if [[ "${CTR_STATUS[$t]:-}" == "running" ]]; then
    docker stop -t 2 "$t" >/dev/null 2>&1 || true
  fi
  docker rm -f "$t" >/dev/null 2>&1 || true

  if docker inspect --type container "$t" >/dev/null 2>&1; then
    err "KHONG THE XOA TUN '$t'!"
    continue
  fi

  log "Da xoa TUN : $t (${TUN_MASKED[$t]})"
  DELETED_TUN_OK["$t"]=1
  TOUCHED_DIRS["$d"]=1

  DIR_DEL_CONTAINERS["$d"]+="${t}"$'\n'
  for ra in "${removed_apps[@]}"; do
    DIR_DEL_CONTAINERS["$d"]+="${ra}"$'\n'
  done
  if [[ -n "${TUN_PROXY_RAW[$t]:-}" ]]; then
    DIR_DEL_PROXIES["$d"]+="${TUN_PROXY_RAW[$t]}"$'\n'
  fi
  if [[ -n "${TUN_INDEX[$t]:-}" ]]; then
    DIR_DEL_INDICES["$d"]+=" ${TUN_INDEX[$t]}"
  fi
done

#----------------------------------------------------------------------------
# 8. Dong bo containernames.txt & proxies.txt (giu nguyen quyen file cu)
#----------------------------------------------------------------------------
for d in "${!TOUCHED_DIRS[@]}"; do
  safe_d=$(echo "$d" | sed 's|^/||;s|/|__|g')
  bdir="${BACKUP_ROOT}/${TS}/${safe_d}"
  mkdir -p "$bdir" 2>/dev/null || true

  cfile="${d}/containernames.txt"
  pfile="${d}/proxies.txt"

  if [[ -f "$cfile" && -n "${DIR_DEL_CONTAINERS[$d]:-}" ]]; then
    cp -a "$cfile" "${bdir}/containernames.txt" 2>/dev/null || true
    del_c_tmp=$(mktemp); new_c_tmp=$(mktemp)
    printf '%s' "${DIR_DEL_CONTAINERS[$d]}" > "$del_c_tmp"
    LC_ALL=C awk 'NR==FNR { if ($0 != "") del[$0]=1; next } { line=$0; sub(/\r$/, "", line); if (!(line in del)) print $0 }' \
      "$del_c_tmp" "$cfile" > "$new_c_tmp"
    cat "$new_c_tmp" > "$cfile"
    rm -f "$del_c_tmp" "$new_c_tmp"
    log "Da dong bo $cfile"
  fi

  if [[ -f "$pfile" && -n "${DIR_DEL_PROXIES[$d]:-}" ]]; then
    cp -a "$pfile" "${bdir}/proxies.txt" 2>/dev/null || true
    del_p_tmp=$(mktemp); new_p_tmp=$(mktemp)
    printf '%s' "${DIR_DEL_PROXIES[$d]}" > "$del_p_tmp"
    LC_ALL=C awk '
      NR==FNR {
        p=$0; gsub(/\r$/, "", p); gsub(/^[ \t]+|[ \t]+$/, "", p);
        if (p != "") del[p]++;
        next
      }
      {
        orig=$0; line=$0;
        gsub(/\r$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line);
        if (line == "" || line ~ /^#/) { print orig; next }
        if (del[line] > 0) { del[line]--; next }
        print orig
      }
    ' "$del_p_tmp" "$pfile" > "$new_p_tmp"
    cat "$new_p_tmp" > "$pfile"
    rm -f "$del_p_tmp" "$new_p_tmp"
    log "Da dong bo $pfile"
  fi

  if (( PURGE_DATA == 1 )) && [[ -n "${DIR_DEL_INDICES[$d]:-}" ]]; then
    for idx in ${DIR_DEL_INDICES[$d]}; do
      [[ "$idx" =~ ^[0-9]+$ ]] || continue
      for dpath in \
        "${d}/mysterium-data/node${idx}" \
        "${d}/traffmonetizerdata/data${idx}" \
        "${d}/bitping-data/data${idx}" \
        "${d}/earnappdata/data${idx}" \
        "${d}/titan-data/data${idx}" \
        "${d}/custom-chrome-data/data${idx}" \
        "${d}/custom-firefox-data/data${idx}" \
        "${d}/chromedata/data${idx}" \
        "${d}/firefoxdata/data${idx}" \
        "${d}/adnadedata/data${idx}"
      do
        if [[ -d "$dpath" ]]; then
          rm -rf "$dpath"
          log "Da xoa thu muc data: $dpath"
        fi
      done
    done
  fi
done

#----------------------------------------------------------------------------
# 9. Don sach cac proxy da xoa khoi delete_proxies.txt (giu quyen WinSCP)
#----------------------------------------------------------------------------
declare -A TARGET_FULLY_DONE
for target in "${!TARGET_TO_TUNS[@]}"; do
  all_ok=1
  for t in ${TARGET_TO_TUNS[$target]}; do
    if [[ -z "${DELETED_TUN_OK[$t]:-}" ]]; then
      all_ok=0
      break
    fi
  done
  (( all_ok == 1 )) && TARGET_FULLY_DONE["$target"]=1
done

if (( ${#TARGET_FULLY_DONE[@]} > 0 )); then
  done_tmp=$(mktemp); new_list_tmp=$(mktemp)
  for dt in "${!TARGET_FULLY_DONE[@]}"; do
    printf '%s\n' "$dt" >> "$done_tmp"
  done
  LC_ALL=C sed '1s/^\xEF\xBB\xBF//' "$LIST_FILE" | LC_ALL=C awk '
    NR==FNR {
      k=$0; gsub(/\r$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", k);
      if (k != "") done[k]=1;
      next
    }
    {
      orig=$0; line=$0;
      gsub(/\r$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line);
      if (line ~ /^#/) { print orig; next }
      if (line == "") next
      if (line in done) next
      print orig
    }
  ' "$done_tmp" - > "$new_list_tmp"
  cat "$new_list_tmp" > "$LIST_FILE"
  rm -f "$done_tmp" "$new_list_tmp"
  log "Da don sach ${#TARGET_FULLY_DONE[@]} proxy khoi ${LIST_FILE} (giu nguyen quyen WinSCP)."
fi

echo -e "\n${C_G}HOAN TAT! Lich su & backup duoc luu tai: ${STATE_ROOT}${C_0}"
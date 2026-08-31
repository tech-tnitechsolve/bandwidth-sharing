#!/bin/bash
#=============================================================================
#  winIncome.sh — Win_Proxy orchestrator
#  Chạy các nền tảng CHỈ CÓ BẢN WINDOWS (PassiveApp, ByteBenefit, Trees, ...)
#  trong container Docker trên Linux VPS:
#     mỗi proxy = 1 container TUN (tun2proxy) + 1 container "Windows-box" (Wine+Xvfb)
#
#  Kiến trúc chống lộ (leak-proof):
#   * App container dùng --network=container:<TUN> -> KHÔNG có đường mạng nào khác
#     ngoài TUN->proxy. TUN chết = app mất mạng = kill-switch tự nhiên.
#   * DNS đi qua proxy (tun2proxy --dns over-tcp) -> không lộ query ra DNS VPS.
#   * IPv6 bị tắt. MAC, hostname, timezone, MachineGuid... được sinh khớp proxy.
#   * Wine bỏ ổ Z: (không đọc được filesystem host). Không mount docker.sock.
#
#  Cách dùng:
#   sudo bash winIncome.sh --install        # cài docker (lần đầu)
#   sudo bash winIncome.sh --build          # build image windows-box
#   sudo bash winIncome.sh --validate       # kiểm tra format proxy/conf (0 bandwidth)
#   sudo bash winIncome.sh --start          # khởi tạo toàn bộ container
#   sudo bash winIncome.sh --status         # bảng trạng thái
#   sudo bash winIncome.sh --probe [N]      # kiểm tra egress IP == proxy IP
#   sudo bash winIncome.sh --logs [N]       # log container
#   sudo bash winIncome.sh --restart | --stop | --delete | --deleteBackup
#   sudo bash winIncome.sh --heal           # quét 1 lượt, sửa container chết
#   sudo bash winIncome.sh --watch          # canh 24/7 (đặt vào cron/systemd)
#=============================================================================
set -uo pipefail

VERSION="1.0.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CONF="$ROOT/properties.conf"
PROXIES="$ROOT/proxies.txt"
INSTALLERS="$ROOT/installers"
INSTANCES="$ROOT/instances"
STATE="$ROOT/win-state.tsv"
CONTAINERS_FILE="$ROOT/win-containers.txt"
IDENTITY_BIN="$ROOT/image/identity.sh"
DOCKERFILE="$ROOT/Dockerfile.wine"

PROJECT_ID="$(printf '%s' "$ROOT" | sha256sum | awk '{print substr($1,1,10)}')"
PROJECT_LABEL="com.winproxy.project=$PROJECT_ID"

#---------------------- defaults
DEVICE_PREFIX=winbox
WIN_IMAGE=winproxy/windows-box:1.0
VPS_IP="${VPS_IP:-}"
IP_CACHE_TTL="${IP_CACHE_TTL:-86400}"
WIN_VNC=false; WIN_SCREEN=1280x720x24; WIN_APPS=""
USE_PROXIES=true; USE_SOCKS5_DNS=false; USE_DNS_OVER_HTTPS=true; VALIDATE_PROXIES=false
TUN_IMAGE=ghcr.io/tun2proxy/tun2proxy:v0.8.3
TUN_MTU=1400; TUN_TCP_MSS=1360; TUN_TCP_TIMEOUT=300; TUN_VERBOSITY=warn
TUN_MAX_MEMORY=auto; TUN_MEMORY_SWAP=auto; TUN_CPU=auto
WIN_MAX_MEMORY=auto; WIN_MEMORY_RESERVATION=auto; WIN_MEMORY_SWAP=auto; WIN_CPU=auto
WIN_TMPFS=128m; DELAY_BETWEEN_CONTAINER=2; ALLOW_GEO_LOOKUP=true; ENABLE_LOGS=false
# Mạng & leak-proof: DNS của app pin đi qua TUN (KHÔNG lộ query ra DNS VPS)
WIN_DNS_SERVERS="8.8.8.8,1.1.1.1"
# Đặt hostname máy = tên máy Windows (realism). Cần --cap-add SYS_ADMIN (chỉ để sethostname).
# Đặt false nếu muốn sandbox chặt hơn (hostname sẽ là container-id, không ảnh hưởng leak).
WIN_SET_HOSTNAME=true
# Log thông minh: giữ N ngày rồi tự xóa, mỗi file tối đa N KB (xoay giữ 1 bản cũ)
WIN_LOG_RETENTION_DAYS=4
WIN_LOG_MAX_KB=2048
WIN_LOG_LOOKBACK_MIN=60
WIN_LOG_MAX_LINE=400
# Từ khóa (ERE, phân tách |) để --health đánh giá online/earning vs lỗi từ log app.
LOG_ONLINE="online|earning|connected|active|success|started|synced|ready|logged in|mining|traffic|balance|paid|reward"
LOG_ERROR="error|failed|refus|timeout|unauthor|offline|disconnect|block|ban|denied|unreachable|expired|dead|502|503|500|401|403|reset"

if [[ -t 1 ]]; then G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; C_=$'\033[1;36m'; N=$'\033[0m'; else G=''; Y=''; R=''; C_=''; N=''; fi
log(){ printf '%s[OK]%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s[!!]%s %s\n' "$Y" "$N" "$*" >&2; }
die(){ printf '%s[XX]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage(){ cat <<EOF
Win_Proxy v$VERSION — chạy app Windows-only trong Docker (Wine + TUN proxy)

  ⭐ 1 LỆNH DUY NHẤT (tự động toàn bộ):
  sudo bash winIncome.sh --setup           Docker -> build -> tải installer -> validate -> start

  Quản lý:
  sudo bash winIncome.sh --validate        Kiểm tra config + proxy (0 bandwidth)
  sudo bash winIncome.sh --checkproxy      Kiểm tra proxy bằng CHÍNH IP VPS (không gọi qua proxy)
  sudo bash winIncome.sh --start           Tạo container cho toàn bộ proxies.txt
  sudo bash winIncome.sh --status          Bảng trạng thái
  sudo bash winIncome.sh --probe [N]       (chẩn đoán tay) egress qua proxy == IP proxy
  sudo bash winIncome.sh --leaktest [N]    (chẩn đoán tay) IP + ASN + DNS leak
  sudo bash winIncome.sh --fetch           Tự tải installer từ link chính thức
  sudo bash winIncome.sh --login [N] [KEY] Tự đăng nhập app (xdotool)
  sudo bash winIncome.sh --shot [N] [KEY]  Chụp ảnh màn hình app
  sudo bash winIncome.sh --logs [N]        Xem log instance N (docker + log app thông minh)
  sudo bash winIncome.sh --health [N]      Chẩn đoán online/earning từ log app (KHÔNG qua proxy)
  sudo bash winIncome.sh --cleanlogs       Xóa log/ảnh cũ (giữ N ngày) — chống nghẽn ổ
  sudo bash winIncome.sh --doctor          Chẩn đoán toàn diện 1 lệnh
  sudo bash winIncome.sh --myip            Hiển thị IP VPS (whitelist cho proxy IP-Auth)
  sudo bash winIncome.sh --install-watch   Cài systemd tự heal 24/7

  Vòng đời:
  sudo bash winIncome.sh --restart | --stop | --delete | --deleteBackup
  sudo bash winIncome.sh --heal            Sửa container chết (1 lượt)
  sudo bash winIncome.sh --watch           Canh chừng 24/7 (tự heal)
EOF
}

need(){ command -v "$1" >/dev/null 2>&1 || die "thiếu lệnh: $1"; }
dk(){
  if docker info >/dev/null 2>&1; then docker "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then sudo docker "$@"
  else die "không truy cập được Docker daemon (chạy: sudo bash winIncome.sh --install)"; fi
}

#---------------------- config parser (AN TOÀN, không eval)
load_config(){
  [[ -f "$CONF" ]] || die "thiếu $CONF (chép mẫu từ properties.conf)"
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                                  # bóc \r (file Windows) KHÔNG cần ghi lại file
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "$line" || "$line" == \#* || "$line" != *"="* ]] && continue
    key="${line%%=*}"; value="${line#*=}"
    key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # bóc nháy đơn/kép ngoài cùng
    if [[ "$value" =~ ^[\'\"](.*)[\'\"]$ ]]; then value="${BASH_REMATCH[1]}"; fi
    # chỉ export khi có giá trị (giá trị rỗng = "không set" -> giữ env/default, vd VPS_IP truyền qua env)
    [[ -n "$key" && -n "$value" ]] && export "$key"="$value"
  done < "$CONF"
}

auto_resources(){
  local mem tier
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if   (( mem <= 4000 )); then tier=1
  elif (( mem <= 8000 )); then tier=2
  elif (( mem <= 16000 )); then tier=3
  else tier=4; fi
  # Mục tiêu: vài trăm MB RAM/máy (Win box ~384-512MB + TUN ~64-96MB)
  local A_WIN_MEM A_WIN_RES A_WIN_SWAP A_TUN_MEM A_TUN_SWAP
  case "$tier" in
    1) A_WIN_MEM=384m;  A_WIN_RES=192m; A_WIN_SWAP=640m;  A_TUN_MEM=64m;  A_TUN_SWAP=128m ;;
    2) A_WIN_MEM=448m;  A_WIN_RES=224m; A_WIN_SWAP=704m;  A_TUN_MEM=96m;  A_TUN_SWAP=192m ;;
    3) A_WIN_MEM=512m;  A_WIN_RES=256m; A_WIN_SWAP=768m;  A_TUN_MEM=128m; A_TUN_SWAP=256m ;;
    *) A_WIN_MEM=640m;  A_WIN_RES=320m; A_WIN_SWAP=896m;  A_TUN_MEM=160m; A_TUN_SWAP=320m ;;
  esac
  [[ "$WIN_MAX_MEMORY" == auto ]] && WIN_MAX_MEMORY=$A_WIN_MEM
  [[ "$WIN_MEMORY_RESERVATION" == auto ]] && WIN_MEMORY_RESERVATION=$A_WIN_RES
  [[ "$WIN_MEMORY_SWAP" == auto ]] && WIN_MEMORY_SWAP=$A_WIN_SWAP
  [[ "$TUN_MAX_MEMORY" == auto ]] && TUN_MAX_MEMORY=$A_TUN_MEM
  [[ "$TUN_MEMORY_SWAP" == auto ]] && TUN_MEMORY_SWAP=$A_TUN_SWAP
}

prereq(){
  for c in docker sha256sum awk sed grep head date; do need "$c"; done
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "Wine tier cần VPS x86_64/amd64 (VPS $(uname -m) không chạy mượt app Windows 64-bit). Dùng VPS amd64 hoặc xem tier-b." ;;
  esac
  if [[ "$USE_PROXIES" == true ]]; then
    [[ -c /dev/net/tun ]] || die "không có /dev/net/tun (chạy setup_vps.sh / modprobe tun trước)"
  fi
  mkdir -p "$INSTANCES" "$INSTALLERS"
}

#---------------------- proxies
hash_proxy(){ printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'; }
mask_proxy(){ local p="$1"; if [[ "$p" == *"@"* ]]; then printf '%s://%s@%s' "${p%%://*}" "***" "${p##*@}"; else echo "$p"; fi; }

#------------------------------------------------------------ IP VPS (cho proxy IP-Authentication)
# QUAN TRỌNG: proxy IP-Auth whitelist IP NGUỒN. Mọi kết nối TỚI proxy đều đi ra từ
# IP VPS -> IP VPS PHẢI được whitelist trong dashboard proxy. Hàm này lấy IP VPS
# (direct, cache 24h, KHÔNG qua proxy) để: (1) hiển thị cho bạn whitelist, (2) không
# probe nhầm proxy IP-Auth gây lỗi auth.
get_vps_ip(){
  [[ -n "$VPS_IP" ]] && { echo "$VPS_IP"; return 0; }
  local cache="$INSTANCES/.vps-ip" now ip
  now=$(date +%s)
  if [[ -f "$cache" ]]; then
    local age=$(( now - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    if (( age < ${IP_CACHE_TTL:-86400} )); then ip=$(cat "$cache" 2>/dev/null); [[ -n "$ip" ]] && { echo "$ip"; return 0; }; fi
  fi
  local ua="Mozilla/5.0"
  # ưu tiên HTTPS direct; tất cả đều đi từ IP VPS (default route)
  for u in "https://api.ipify.org" "https://icanhazip.com" "https://ifconfig.me/ip" "https://ipinfo.io/ip"; do
    ip=$(curl -4 -s --max-time 8 -A "$ua" "$u" 2>/dev/null | tr -dc '0-9.')
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    ip=""
  done
  [[ -z "$ip" ]] && return 1
  mkdir -p "$INSTANCES"; echo "$ip" > "$cache" 2>/dev/null || true
  echo "$ip"
}

# GHI CHÚ QUAN TRỌNG: nhiều proxy dạng user:pass nhưng BẢN CHẤT vẫn là IP-Authentication
# (whitelist IP nguồn). Vì vậy: mọi kiểm tra proxy đều dùng CHÍNH IP VPS, KHÔNG gửi
# request nào QUA proxy. Hàm proxy_auth_type chỉ dùng để phân biệt cách bắt tay (creds),
# KHÔNG có nghĩa "user:pass thì không cần whitelist".
proxy_auth_type(){
  local p="$1" rest="${p#*://}"
  [[ "$rest" == *"@"* ]] && { echo "creds"; return 0; }
  echo "ipauth"
}

#------------------------------------------------------------ CHECK PROXY bằng IP VPS (không qua proxy)
proxy_hostport(){ # <proxy> -> "host|port"
  local p="$1" rest hostport host port
  rest="${p#*://}"
  hostport="${rest##*@}"            # bỏ credentials
  host="${hostport%:*}"; port="${hostport##*:}"
  [[ "$host" == \[*\] ]] && host="${host:1:${#host}-2}"
  printf '%s|%s' "$host" "$port"
}

# TCP connect thuần túy (từ IP VPS) — KHÔNG gửi gì QUA proxy, chỉ test kết nối tới cổng proxy
tcp_reachable(){
  local host="$1" port="$2"
  timeout 10 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# Bắt tay SOCKS5 (greeting + user/pass) — KHÔNG gửi lệnh CONNECT => KHÔNG có traffic QUA proxy.
# Trả 0 nếu: TCP được chấp nhận VÀ (no-auth OK | user/pass OK).
# LƯU Ý: so sánh theo HEX (od) vì bash KHÔNG chứa được byte NUL trong biến.
socks5_auth(){
  local host="$1" port="$2" user="$3" pass="$4" ul pl
  ul=${#user}; pl=${#pass}
  timeout 12 bash -c '
    host="$1"; port="$2"; user="$3"; pass="$4"; ul="$5"; pl="$6"
    exec 3<>/dev/tcp/${host}/${port} || exit 1
    # greeting: SOCKS5, chào 2 method (0x00 = no-auth, 0x02 = user/pass)
    printf "\x05\x02\x00\x02" >&3 || exit 1
    resp=$(dd bs=1 count=2 <&3 2>/dev/null | od -An -tx1 | tr -d " \n\t") || exit 1
    [ "$resp" = "0500" ] && exit 0           # server chọn no-auth (IP-auth đã pass)
    [ "$resp" = "0502" ] || exit 1
    # gửi user/pass (length là 1 byte, creds proxy là ASCII)
    printf "\x01" >&3 || exit 1
    printf "\\$(printf "%03o" "$ul")" >&3 || exit 1
    printf "%s" "$user" >&3 || exit 1
    printf "\\$(printf "%03o" "$pl")" >&3 || exit 1
    printf "%s" "$pass" >&3 || exit 1
    resp=$(dd bs=1 count=2 <&3 2>/dev/null | od -An -tx1 | tr -d " \n\t") || exit 1
    [ "$resp" = "0100" ] || exit 1
    exit 0
  ' _ "$host" "$port" "$user" "$pass" "$ul" "$pl" 2>/dev/null
}

checkproxy(){
  load_config
  local vip; vip=$(get_vps_ip 2>/dev/null || echo "<chưa rõ>")
  [[ -f "$PROXIES" ]] || die "thiếu $PROXIES"
  mapfile -t RAWL < <(sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$PROXIES" | grep -vE '^(#|$)' || true)
  ((${#RAWL[@]} > 0)) || die "proxies.txt rỗng!"
  log "=== CHECK PROXY bằng CHÍNH IP VPS = $vip ==="
  log "Cơ chế: TCP connect tới host:port proxy + bắt tay auth SOCKS5 (nếu user:pass)."
  log "KHÔNG gửi lệnh CONNECT -> proxy không tốn bandwidth, không bị 'bẩn', không lỗi IP-Auth."
  log "Nếu proxy dùng IP-Auth: phải whitelist IP VPS $vip trong dashboard proxy."
  echo
  printf '%-3s %-26s %-8s %-18s %s\n' "IDX" "PROXY" "TCP" "AUTH" "KẾT LUẬN"
  local i=0 p host port ok auth rest creds user pass
  for p in "${RAWL[@]}"; do
    i=$((i+1))
    p="${p%%#*}"; p=$(echo "$p" | sed 's/[[:space:]]*$//')
    if [[ ! "$p" =~ ^(http|https|socks4|socks5)://.+:[0-9]{1,5}$ ]]; then
      printf '%-3s %-26s %-8s %-18s %s\n' "$i" "$(mask_proxy "$p")" "-" "-" "❌ format lỗi"
      continue
    fi
    IFS='|' read -r host port <<< "$(proxy_hostport "$p")"
    if tcp_reachable "$host" "$port"; then ok=1; else ok=0; fi
    auth="IP-Auth (TCP)"
    if [[ "$p" == socks5://* ]]; then
      rest="${p#*://}"
      if [[ "$rest" == *"@"* ]]; then
        creds="${rest%@*}"; user="${creds%%:*}"; pass="${creds#*:}"
        if socks5_auth "$host" "$port" "$user" "$pass"; then auth="OK (user/pass)"; else auth="FAIL (user/pass)"; fi
      fi
    fi
    if [[ $ok == 1 && "$auth" != FAIL* ]]; then
      printf '%-3s %-26s %-8s %-18s %s\n' "$i" "$(mask_proxy "$p")" "OK" "$auth" "✅ reachable"
    elif [[ $ok == 1 ]]; then
      printf '%-3s %-26s %-8s %-18s %s\n' "$i" "$(mask_proxy "$p")" "OK" "$auth" "❌ auth lỗi (sai user/pass HOẶC chưa whitelist IP VPS)"
    else
      printf '%-3s %-26s %-8s %-18s %s\n' "$i" "$(mask_proxy "$p")" "FAIL" "$auth" "❌ proxy chết / chưa whitelist IP VPS"
    fi
  done
  echo
  log "Đây là check tầng KẾT NỐI từ IP VPS (an toàn tuyệt đối cho IP-Auth)."
  log "Xác nhận IP egress thật trên dashboard nền tảng (không cần gọi qua proxy từ đây)."
}

proxy_ip(){ # -> ipv4 của proxy (resolve hostname nếu cần)
  local p="${1%%#*}" rest host
  rest="${p#*://}"; host="${rest##*@}"; host="${host%%:*}"
  [[ "$host" == \[*\] ]] && host="${host:1:${#host}-2}"
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$host"
  else getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}'; fi
}

parse_geo_hint(){ # -> "CC|City|TZ" hoặc rỗng
  local line="$1" hint="" cc="" city="" tz=""
  [[ "$line" == *"#"* ]] || return 0
  hint="${line##*#}"
  [[ "$hint" =~ ^[[:space:]]*([A-Za-z]{2})(:[^:]*)?(:[^:]*)? ]] || return 0
  cc="${BASH_REMATCH[1],,}"; cc="${cc^^}"
  local rest="${hint#*:}"
  city="${rest%%:*}"; tz="${rest#*:}"
  [[ "$city" == "$rest" ]] && tz=""
  printf '%s|%s|%s' "$cc" "${city:-Unknown}" "${tz:-}"
}

read_proxies(){
  [[ -f "$PROXIES" ]] || die "thiếu $PROXIES"
  mapfile -t RAW < <(sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$PROXIES" | grep -vE '^(#|$)' || true)
  ((${#RAW[@]} > 0)) || die "$PROXIES rỗng!"
  PROXY_LIST=(); declare -gA SEEN=(); declare -gA HINT_MAP=(); declare -gA AUTH_MAP=()
  local orig p h
  for orig in "${RAW[@]}"; do
    p="${orig%%#*}"          # bỏ hint geo
    p=$(echo "$p" | sed 's/[[:space:]]*$//')
    [[ "$p" =~ ^(http|https|socks4|socks5)://.+:[0-9]{1,5}$ ]] || die "proxy sai format: $p"
    h=$(hash_proxy "$p")
    [[ -n "${SEEN[$h]:-}" ]] && { warn "bỏ proxy trùng: $(mask_proxy "$p")"; continue; }
    SEEN[$h]=1; PROXY_LIST+=("$p"); HINT_MAP[$h]="$orig"; AUTH_MAP[$h]=$(proxy_auth_type "$p")
  done
}

tun_dns_mode(){ [[ "$USE_DNS_OVER_HTTPS" == true ]] && echo "over-tcp" || echo "virtual"; }
tun_name(){ printf 'wintun-%s-%03d-%s' "$PROJECT_ID" "$1" "${2:0:6}"; }
app_name(){ printf 'winapp-%s-%03d-%s' "$PROJECT_ID" "$1" "${2:0:6}"; }

wait_running(){
  local name="$1" timeout="${2:-20}" i=0 state
  while (( i < timeout )); do
    state=$(dk inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)
    case "$state" in running) return 0;; exited|dead) return 1;; esac
    sleep 1; i=$((i+1))
  done
  return 1
}

ensure_tun_image(){
  local img="$1"
  dk image inspect "$img" >/dev/null 2>&1 && return 0
  log "kéo image TUN $img ..."
  dk pull "$img" >/dev/null 2>&1 || die "không pull được image TUN $img (VPS cần mạng tới ghcr.io). Kiểm tra DNS/mạng hoặc pin version khác trong properties.conf."
}

ensure_win_image(){
  local img="$1"
  dk image inspect "$img" >/dev/null 2>&1 && return 0
  log "build image Windows-box $img (image local, build từ Dockerfile.wine)..."
  dk build -f "$DOCKERFILE" -t "$img" "$ROOT" || die "build image thất bại"
}

#---------------------- identity per proxy
gen_identity(){ # <idx> <proxy> -> "hash|comp|tz|mac|country" (đọc từ env.sh)
  local idx="$1" p="$2" h ip cc="" city="" tz="" idir geoline orig
  h=$(hash_proxy "$p")
  ip=$(proxy_ip "$p"); ip=${ip:-0.0.0.0}
  idir="$INSTANCES/$h/identity"
  mkdir -p "$idir"
  if [[ ! -f "$idir/env.sh" ]]; then
    # giữ nguyên danh tính đã tạo (ổn định qua các lần chạy); chỉ sinh khi chưa có
    orig="${HINT_MAP[$h]:-}"
    geoline=$(parse_geo_hint "$orig")
    if [[ -n "$geoline" ]]; then
      IFS='|' read -r cc city tz <<< "$geoline"
    fi
    ALLOW_GEO_LOOKUP="$ALLOW_GEO_LOOKUP" OUTDIR="$idir" \
      bash "$IDENTITY_BIN" gen "$p" "$ip" "${cc:-}" "${city:-}" "${tz:-}" >/dev/null || \
      warn "sinh identity thất bại cho $(mask_proxy "$p")"
  fi
  set +u
  # shellcheck disable=SC1090
  source "$idir/env.sh" 2>/dev/null || true
  set -u
  printf '%s|%s|%s|%s|%s|%s' "$h" "${WIN_COMPUTER_NAME:-WINBOX}" "${WIN_TZ:-UTC}" \
    "${WIN_MAC:-02:00:00:00:00:01}" "${WIN_COUNTRY:-XX}" "${WIN_SCREEN:-1280x720x24}"
}

#---------------------- run containers
log_params(){
  if [[ "$ENABLE_LOGS" != true ]]; then
    echo "--log-driver local --log-opt max-size=1m --log-opt max-file=2"
  else
    echo "--log-driver json-file --log-opt max-size=1m --log-opt max-file=3"
  fi
}

run_tun(){ # <idx> <proxy> <hash> <mac> <vnc_port>
  local idx="$1" p="$2" h="$3" mac="$4" vnc="$5" name dns_mode vncarg=""
  name=$(tun_name "$idx" "$h"); dns_mode=$(tun_dns_mode)
  if [[ "$WIN_VNC" == true ]]; then vncarg="-p 127.0.0.1:$vnc:5900"; fi
  # shellcheck disable=SC2046
  # --tun tun0        : tên interface cố định để kill-switch/net-guard dò route chính xác
  # --exit-on-fatal-error: proxy chết/auth lỗi -> thoát -> Docker restart -> tự nối lại (dễ phát hiện)
  dk run -d --name "$name" --restart unless-stopped \
    --label "$PROJECT_LABEL" --label "com.winproxy.role=tun" --label "com.winproxy.hash=$h" \
    --device /dev/net/tun --cap-add NET_ADMIN --security-opt no-new-privileges:true \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 \
    --ulimit nofile=65536:65536 --pids-limit 96 --cpu-shares 256 \
    --memory "$TUN_MAX_MEMORY" --memory-swap "$TUN_MEMORY_SWAP" \
    --mac-address "$mac" $vncarg $(log_params) \
    "$TUN_IMAGE" --dns "$dns_mode" --proxy "$p" --tun tun0 \
    --mtu "$TUN_MTU" --tcp-mss "$TUN_TCP_MSS" --tcp-timeout "$TUN_TCP_TIMEOUT" \
    --verbosity "$TUN_VERBOSITY" --exit-on-fatal-error >/dev/null
  sed -i "/^$name$/d" "$CONTAINERS_FILE" 2>/dev/null || true
  echo "$name" >> "$CONTAINERS_FILE"
  wait_running "$name" "${TUN_READY_TIMEOUT:-15}" || return 1
}

run_app(){ # <idx> <proxy> <hash> <tun> <comp> <tz> <screen> <vnc>
  local idx="$1" p="$2" h="$3" tun="$4" comp="$5" tz="$6" screen="$7" vnc="$8" name inst
  name=$(app_name "$idx" "$h")
  inst="$INSTANCES/$h"
  mkdir -p "$inst/prefix" "$inst/identity"
  chmod -R 777 "$inst" 2>/dev/null || true
  [[ -n "$screen" ]] || screen="$WIN_SCREEN"

  # build env cho từng app
  local k appenv=()
  for k in ${WIN_APPS//,/ }; do
    k="${k//[^A-Za-z0-9_]/}"; [[ -z "$k" ]] && continue
    eval "local v=\${${k}_INSTALLER:-}";   [[ -n "$v" ]] && appenv+=("-e" "${k}_INSTALLER=$v")
    eval "v=\${${k}_LAUNCH:-}";            [[ -n "$v" ]] && appenv+=("-e" "${k}_LAUNCH=$v")
    eval "v=\${${k}_DETECT:-}";            [[ -n "$v" ]] && appenv+=("-e" "${k}_DETECT=$v")
    eval "v=\${${k}_ARGS:-}";              [[ -n "$v" ]] && appenv+=("-e" "${k}_ARGS=$v")
    eval "v=\${${k}_CWD:-}";               [[ -n "$v" ]] && appenv+=("-e" "${k}_CWD=$v")
    eval "v=\${${k}_INSTALL_FLAGS:-}";     [[ -n "$v" ]] && appenv+=("-e" "${k}_INSTALL_FLAGS=$v")
    eval "v=\${${k}_LOGIN_EMAIL:-}";       [[ -n "$v" ]] && appenv+=("-e" "${k}_LOGIN_EMAIL=$v")
    eval "v=\${${k}_LOGIN_PASSWORD:-}";    [[ -n "$v" ]] && appenv+=("-e" "${k}_LOGIN_PASSWORD=$v")
    eval "v=\${${k}_WIN_TITLE:-}";         [[ -n "$v" ]] && appenv+=("-e" "${k}_WIN_TITLE=$v")
    eval "v=\${${k}_LOGIN_SCRIPT:-}";      [[ -n "$v" ]] && appenv+=("-e" "${k}_LOGIN_SCRIPT=$v")
  done

  # shellcheck disable=SC2046
  # CHÚ Ý: KHÔNG dùng --hostname với --network=container: (Docker từ chối: "conflicting
  # options: hostname and the network mode"). Hostname được đặt trong entrypoint (win-init).
  local cap=""
  [[ "$WIN_SET_HOSTNAME" == true ]] && cap="--cap-add SYS_ADMIN"
  dk run -d --name "$name" --restart unless-stopped \
    --label "$PROJECT_LABEL" --label "com.winproxy.role=app" --label "com.winproxy.hash=$h" \
    --network "container:$tun" \
    -e TZ="$tz" -e WIN_APPS="$WIN_APPS" -e WIN_VNC="$([[ "$WIN_VNC" == true ]] && echo 1 || echo 0)" \
    -e WIN_SCREEN="$screen" \
    -e WIN_COMPUTER_NAME="$comp" \
    -e WIN_DNS_SERVERS="$WIN_DNS_SERVERS" \
    -e WIN_SET_HOSTNAME="$([[ "$WIN_SET_HOSTNAME" == true ]] && echo 1 || echo 0)" \
    -e WIN_LOG_RETENTION_DAYS="$WIN_LOG_RETENTION_DAYS" \
    -e WIN_LOG_MAX_KB="$WIN_LOG_MAX_KB" \
    -e WIN_LOG_MAX_LINE="$WIN_LOG_MAX_LINE" \
    "${appenv[@]}" \
    $cap \
    --mount "type=bind,source=$inst/prefix,target=/prefix" \
    --mount "type=bind,source=$inst/identity,target=/identity,readonly" \
    --mount "type=bind,source=$INSTALLERS,target=/installers,readonly" \
    --tmpfs "/winehome:size=$WIN_TMPFS,mode=0777" \
    --security-opt no-new-privileges:true \
    --cap-drop NET_ADMIN --cap-drop NET_RAW --cap-drop MKNOD --cap-drop SYS_CHROOT \
    --cap-drop FSETID --cap-drop SETFCAP --cap-drop SETPCAP --cap-drop AUDIT_WRITE \
    --cap-drop NET_BIND_SERVICE --cap-drop SYS_PTRACE --cap-drop SYS_MODULE --cap-drop SYSLOG \
    --pids-limit 160 \
    --ulimit nofile=65536:65536 --cpu-shares 512 \
    --memory "$WIN_MAX_MEMORY" --memory-reservation "$WIN_MEMORY_RESERVATION" --memory-swap "$WIN_MEMORY_SWAP" \
    $(log_params) \
    "$WIN_IMAGE" >/dev/null
  sed -i "/^$name$/d" "$CONTAINERS_FILE" 2>/dev/null || true
  echo "$name" >> "$CONTAINERS_FILE"
  wait_running "$name" 20 || return 1
}

#---------------------- start
start_all(){
  load_config; auto_resources; prereq; read_proxies
  ensure_tun_image "$TUN_IMAGE"
  ensure_win_image "$WIN_IMAGE"
  local i=0 p h mac comp tz country screen idx info vnc_port tun
  : > "$STATE"; : > "$CONTAINERS_FILE"

  log "Chế độ PROXY: tạo ${#PROXY_LIST[@]} máy Windows (image: $WIN_IMAGE)"
  for p in "${PROXY_LIST[@]}"; do
    i=$((i+1)); idx=$i
    info=$(gen_identity "$idx" "$p")
    IFS='|' read -r h comp tz mac country screen <<< "$info"
    # VNC bind 127.0.0.1; port nền trượt theo PROJECT_ID để nhiều thư mục trên CÙNG 1 VPS không đụng cổng
    vnc_port=$(( 5900 + (16#${PROJECT_ID:0:2} % 40) * 10 + idx ))

    log "[$i/${#PROXY_LIST[@]}] TUN cho $(mask_proxy "$p")"
    tun=$(tun_name "$idx" "$h")
    if dk inspect --type container "$tun" >/dev/null 2>&1; then
      warn "container $tun đã tồn tại — bỏ qua (chạy --delete trước)."; continue
    fi
    run_tun "$idx" "$p" "$h" "$mac" "$vnc_port" || { warn "TUN $tun không lên — bỏ qua proxy"; dk rm -f "$tun" >/dev/null 2>&1 || true; sed -i "/^$tun$/d" "$CONTAINERS_FILE"; continue; }

    log "[$i/${#PROXY_LIST[@]}] Windows-box $comp ($country/$tz, $screen) cho $(mask_proxy "$p")"
    run_app "$idx" "$p" "$h" "$tun" "$comp" "$tz" "$screen" "$vnc_port" || warn "app container lỗi — xem log"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$h" "$p" "$tun" "$(app_name "$idx" "$h")" "$comp" "$tz" "$country" "$screen" "$vnc_port" >> "$STATE"
    sleep "$DELAY_BETWEEN_CONTAINER"
  done
  log "Hoàn tất. Xem: sudo bash winIncome.sh --status"
}

#---------------------- status / logs / probe
status(){
  [[ -s "$STATE" ]] || die "chưa có instance (chạy --start trước)"
  printf '\n%-4s %-14s %-22s %-20s %-16s %-10s %-9s %-8s\n' "IDX" "HASH" "PROXY" "TUN" "MACHINE" "SCREEN" "NET" "STATE"
  local idx h p tun app comp tz country screen vnc st net hb
  while IFS=$'\t' read -r idx h p tun app comp tz country screen vnc; do
    st=$(dk inspect -f '{{.State.Status}}' "$app" 2>/dev/null || echo missing)
    net=$(cut -d'|' -f2 <<< "$(netstate_of "$h")"); [[ -z "$net" ]] && net="-"
    hb=$(fmt_age "$(hb_age "$h")")
    printf '%-4s %-14s %-22s %-20s %-16s %-10s %-9s %-8s\n' "$idx" "${h:0:8}..." "$(mask_proxy "$p")" "$tun" "$comp" "$screen" "$net/$hb" "$st"
  done < "$STATE"
  echo "NET: UP=tunnel OK · LEAK=NGUY CƠ LỘ IP · DOWN=proxy chết/offline (an toàn) · ALIVE=nhịp tim app cuối"
  echo "Chi tiết online/earning từng app: sudo bash winIncome.sh --health [N]"
  echo
}

get_by_idx(){ # <idx> -> prints "hash|tun|app|proxy" line
  local want="$1" line idx
  while IFS=$'\t' read -r idx h p tun app comp tz country screen vnc; do
    [[ "$idx" == "$want" ]] && { printf '%s\t%s\t%s\t%s\n' "$h" "$tun" "$app" "$p"; return 0; }
  done < "$STATE"
  die "không tìm thấy instance index $want"
}

fmt_age(){ # <seconds> -> "5s"/"3m"/"2h"/"4d"
  local s="${1:-}" 
  [[ -z "$s" ]] && { echo "-"; return; }
  if   (( s < 60 ));  then echo "${s}s"
  elif (( s < 3600 )); then echo "$((s/60))m"
  elif (( s < 86400 )); then echo "$((s/3600))h"
  else echo "$((s/86400))d"; fi
}
inst_apps_dir(){ echo "$INSTANCES/$1/prefix/apps"; }
netstate_of(){ # <hash> -> "UP|epoch" ... hoặc rỗng
  local f
  f="$(inst_apps_dir "$1")/.netstate"
  [[ -f "$f" ]] && cat "$f" 2>/dev/null
}
hb_age(){ # <hash> -> tuổi heartbeat nhỏ nhất (giây) của các app đang chạy (rỗng nếu chưa có)
  local dir now min=999999 f a
  dir="$(inst_apps_dir "$1")"; now=$(date +%s)
  shopt -s nullglob
  for f in "$dir"/.alive_*; do
    a=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    (( a < min )) && min=$a
  done
  shopt -u nullglob
  [[ "$min" == 999999 ]] && echo "" || echo "$min"
}
app_net_state(){ # <app-container> -> UP|LEAK|DOWN|?  (đọc live /proc/net/route trong netns chung)
  local c="$1" out
  out=$(dk exec "$c" awk 'NR==1{next}{i=$1;d=$2;m=$8;if(d=="00000000"&&m=="00000000"){if(i~/^tun/)td=1;else od=1}if(d=="00000000"&&m=="80000000"&&i~/^tun/)tl=1;if(d=="80000000"&&m=="80000000"&&i~/^tun/)th=1}END{if(td||(tl&&th))print "UP";else if(od)print "LEAK";else print "DOWN"}' /proc/net/route 2>/dev/null)
  printf '%s' "${out:-?}"
}

logs(){
  load_config
  local idx="${1:-1}"; local IFS line h tun app p
  IFS=$'\t' read -r h tun app p <<< "$(get_by_idx "$idx")"
  [[ -n "$app" ]] || die "instance $idx không tồn tại"
  local dir; dir="$(inst_apps_dir "$h")"
  log "=== docker logs (container $app) ==="
  dk logs --tail 200 "$app" 2>&1
  echo
  local k f
  for k in ${WIN_APPS//,/ }; do
    k="${k//[^A-Za-z0-9_]/}"; [[ -z "$k" ]] && continue
    f="$dir/logs/${k}.log"
    if [[ -f "$f" ]]; then
      log "=== log thông minh $k (${f} — giữ ${WIN_LOG_RETENTION_DAYS} ngày, max ${WIN_LOG_MAX_KB}KB) ==="
      tail -n 60 "$f" 2>/dev/null
      echo
    fi
  done
}

probe(){
  load_config
  local idx="${1:-1}"; local IFS line h tun app p
  IFS=$'\t' read -r h tun app p <<< "$(get_by_idx "$idx")"
  [[ -n "$tun" ]] || die "instance $idx không tồn tại"
  local vip auth; vip=$(get_vps_ip 2>/dev/null || echo "<chưa rõ>"); auth=$(proxy_auth_type "$p")
  log "⚠️  ĐÂY LÀ CHẨN ĐOÁN THỦ CÔNG: gửi request QUA proxy để xác minh egress (KHÔNG nằm trong luồng tự động)."
  log "    Kiểm tra proxy an toàn hằng ngày dùng: --checkproxy (chỉ IP VPS, không qua proxy)."
  log "Kiểm tra egress của instance $idx (qua proxy $(mask_proxy "$p"))..."
  log "Egress IP PHẢI = IP proxy. Nếu khác -> rò rỉ, dừng ngay."
  dk run --rm --network "container:$tun" curlimages/curl:latest -s --max-time 20 https://api.ipify.org 2>&1; echo
}

leaktest(){
  load_config
  local idx="${1:-1}"; local IFS line h tun app p
  IFS=$'\t' read -r h tun app p <<< "$(get_by_idx "$idx")"
  [[ -n "$tun" ]] || die "instance $idx không tồn tại"
  local vip auth; vip=$(get_vps_ip 2>/dev/null || echo "<chưa rõ>"); auth=$(proxy_auth_type "$p")
  log "=== LEAK TEST instance $idx — proxy: $(mask_proxy "$p") ==="
  log "⚠️  ĐÂY LÀ CHẨN ĐOÁN THỦ CÔNG: gửi request QUA proxy (để bắt lỗi rò rỉ)."
  log "    Kiểm tra proxy an toàn hằng ngày: --checkproxy (chỉ IP VPS, không qua proxy)."
  log "IP VPS (nguồn tới proxy) = $vip"
  echo
  echo "--- [1] Egress IP (phải = IP proxy) ---"
  dk run --rm --network "container:$tun" curlimages/curl:latest -s --max-time 20 https://api.ipify.org 2>&1; echo
  echo "--- [2] ASN/Org/Country (Org phải là ISP residential, KHÔNG phải datacenter VPS) ---"
  dk run --rm --network "container:$tun" curlimages/curl:latest -s --max-time 20 https://ipinfo.io/json 2>&1; echo
  echo "--- [3] DNS path (trace của Cloudflare; 'ip' phải = IP proxy, remote_ip = Cloudflare) ---"
  dk run --rm --network "container:$tun" curlimages/curl:latest -s --max-time 20 -w '\nremote_ip=%{remote_ip}\n' https://one.one.one.one/cdn-cgi/trace 2>&1; echo
  echo
  log "Verdict: [1] IP == proxy · [2] org != datacenter · [3] remote_ip != IP VPS => PASS (không lộ)"
}

fetch_installers(){
  load_config
  need curl
  mkdir -p "$INSTALLERS"
  [[ -z "${WIN_APPS:-}" ]] && die "WIN_APPS rỗng trong properties.conf"
  local k inst url out sz manifest="$INSTALLERS/.sha256"
  touch "$manifest"
  for k in ${WIN_APPS//,/ }; do
    k="${k//[^A-Za-z0-9_]/}"; [[ -z "$k" ]] && continue
    eval "inst=\${${k}_INSTALLER:-}"
    eval "url=\${${k}_URL:-}"
    [[ -n "$url" ]] || eval "url=\${${k}_URL_FALLBACK:-}"
    [[ -n "$url" ]] || { warn "$k: không có <KEY>_URL — bỏ qua (tải tay vào installers/)"; continue; }
    [[ -n "$inst" ]] || inst="$(basename "$url")"
    out="$INSTALLERS/$inst"
    if [[ -f "$out" ]]; then
      log "$inst đã có — giữ bản hiện tại (ổn định, không tải lại)."
      continue
    fi
    log "Tải $inst ..."
    log "  URL: $url"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
      -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36" \
      -o "$out.tmp" "$url" || { warn "tải thất bại: $url"; rm -f "$out.tmp"; continue; }
    sz=$(stat -c%s "$out.tmp" 2>/dev/null || echo 0)
    if (( sz < 1000000 )); then
      warn "$inst chỉ $sz bytes — có thể là trang lỗi, không phải installer. Kiểm tra lại URL."
      rm -f "$out.tmp"; continue
    fi
    mv "$out.tmp" "$out"
    (cd "$INSTALLERS" && sha256sum "$inst" >> "$manifest" 2>/dev/null || true)
    log "OK: $inst ($((sz/1024/1024))MB)"
  done
  log "Hoàn tất. Chạy --start để cài tự động."
}

#---------------------- stop / restart / delete
stop_all(){ [[ -f "$CONTAINERS_FILE" ]] || die "chưa có container"; local c; while read -r c; do [[ -n "$c" ]] && dk stop "$c" >/dev/null 2>&1 || true; done < "$CONTAINERS_FILE"; log "đã dừng toàn bộ container"; }
restart_all(){ [[ -f "$CONTAINERS_FILE" ]] || die "chưa có container"; local c; while read -r c; do [[ -n "$c" ]] && dk restart "$c" >/dev/null 2>&1 || true; done < "$CONTAINERS_FILE"; log "đã restart toàn bộ container"; }

delete_all(){
  local c
  if [[ -f "$CONTAINERS_FILE" ]]; then
    while read -r c; do [[ -n "$c" ]] && dk rm -f "$c" >/dev/null 2>&1 || true; done < "$CONTAINERS_FILE"
  fi
  # quét sạch container theo label (an toàn nếu mất file)
  while IFS= read -r c; do [[ -n "$c" ]] && dk rm -f "$c" >/dev/null 2>&1 || true; done < <(dk ps -a --filter "label=$PROJECT_LABEL" --format '{{.Names}}' 2>/dev/null)
  rm -f "$CONTAINERS_FILE" "$STATE"
  log "đã xóa container + file run. GIỮ instances/ (danh tính + login app)."
  log "Muốn xóa luôn danh tính/login: sudo bash winIncome.sh --deleteBackup"
}

delete_backup(){
  [[ -d "$INSTANCES" ]] && { warn "xóa $INSTANCES (mất MachineGuid + login app vĩnh viễn!)"; rm -rf "$INSTANCES"; }
  log "đã xóa toàn bộ backup."
}

#---------------------- heal / watch
#  Lưu ý: heal KHÔNG gửi bất kỳ request nào qua proxy (chỉ dk inspect/start/exec đọc
#  route). Mọi kiểm tra proxy dùng IP VPS: sudo bash winIncome.sh --checkproxy
heal_once(){
  [[ -s "$STATE" ]] || return 0
  load_config; auto_resources
  local idx h p tun app comp tz country screen vnc
  while IFS=$'\t' read -r idx h p tun app comp tz country screen vnc; do
    [[ -n "$tun" && -n "$app" ]] || continue
    local tun_st app_st net tun_started app_started mark now
    tun_st=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
    app_st=$(dk inspect -f '{{.State.Status}}' "$app" 2>/dev/null || echo missing)

    # 1) TUN chết hẳn -> start (bỏ qua khi Docker đang tự restart: "restarting")
    case "$tun_st" in
      running|restarting) ;;
      *)
        warn "heal: TUN $tun (state=$tun_st) -> start"
        dk start "$tun" >/dev/null 2>&1 || { warn "không start được $tun (proxy chết/auth lỗi?)"; continue; } ;;
    esac

    # 2) Đọc trạng thái route live qua app container (netns chung với TUN)
    net="?"
    if [[ "$app_st" == running ]]; then net=$(app_net_state "$app"); fi
    # fallback về file .netstate (do win-init ghi) nếu app chưa chạy hoặc exec lỗi
    [[ "$net" == "?" ]] && net=$(cut -d'|' -f2 <<< "$(netstate_of "$h")")
    [[ -z "$net" ]] && net="?"

    if [[ "$net" == "LEAK" ]]; then
      # NGHIÊM TRỌNG: default route không qua tun -> app có thể lộ IP VPS. Khôi phục ngay.
      warn "heal: LEAK RISK ở $app — restart TUN để khôi phục route tun"
      mark="$INSTANCES/.tun-restart-$h"; now=$(date +%s)
      if [[ ! -f "$mark" || $(( now - $(stat -c %Y "$mark" 2>/dev/null || echo 0) )) -gt 60 ]]; then
        touch "$mark" 2>/dev/null || true
        dk restart "$tun" >/dev/null 2>&1 || true
      fi
    fi

    # 2b) TUN container CHẠY nhưng tunnel chưa lên (không có route tun) LÂU > 2 phút
    #     -> restart TUN để buộc nối lại proxy (vd proxy hết hạn rồi được gia hạn).
    #     KHÔNG gửi traffic qua proxy (chỉ dk restart), an toàn cho IP-Auth.
    if [[ "$net" == "DOWN" && "$tun_st" == running ]]; then
      tun_started=$(dk inspect -f '{{.State.StartedAt}}' "$tun" 2>/dev/null || echo "")
      local tun_epoch=0
      [[ -n "$tun_started" ]] && tun_epoch=$(date -u -d "$tun_started" +%s 2>/dev/null || echo 0)
      now=$(date +%s)
      if (( now - tun_epoch > 120 )); then
        warn "heal: $tun chạy nhưng tunnel DOWN > 2 phút — restart TUN để nối lại proxy"
        mark="$INSTANCES/.tun-restart-$h"
        if [[ ! -f "$mark" || $(( now - $(stat -c %Y "$mark" 2>/dev/null || echo 0) )) -gt 120 ]]; then
          touch "$mark" 2>/dev/null || true
          dk restart "$tun" >/dev/null 2>&1 || true
        fi
      fi
    fi

    # 3) App chết hẳn -> tạo lại (để JOIN lại netns TUN hiện tại)
    case "$app_st" in
      running|restarting) ;;
      *)
        warn "heal: app $app (state=$app_st) -> tạo lại"
        dk rm -f "$app" >/dev/null 2>&1 || true
        run_app "$idx" "$p" "$h" "$tun" "$comp" "$tz" "$screen" "$vnc" && log "heal: đã tạo lại $app"
        continue ;;
    esac

    # 4) TUN khởi động SAU app (TUN vừa restart/recreate) -> app phải tạo lại để JOIN netns mới.
    #    Dùng StartedAt (RFC3339, so sánh chuỗi được) — bắt được cả docker restart tự động.
    tun_started=$(dk inspect -f '{{.State.StartedAt}}' "$tun" 2>/dev/null || echo "")
    app_started=$(dk inspect -f '{{.State.StartedAt}}' "$app" 2>/dev/null || echo "")
    if [[ -n "$tun_started" && -n "$app_started" && "$tun_started" > "$app_started" ]]; then
      warn "heal: TUN $tun khởi động sau app -> tạo lại $app để join netns mới"
      mark="$INSTANCES/.app-recreate-$h"; now=$(date +%s)
      if [[ ! -f "$mark" || $(( now - $(stat -c %Y "$mark" 2>/dev/null || echo 0) )) -gt 120 ]]; then
        touch "$mark" 2>/dev/null || true
        dk rm -f "$app" >/dev/null 2>&1 || true
        run_app "$idx" "$p" "$h" "$tun" "$comp" "$tz" "$screen" "$vnc" && log "heal: đã tạo lại $app"
      fi
      continue
    fi

    # 5) App chạy nhưng heartbeat cũ (treo) > 10 phút -> restart app.
    #    CHỈ khi tunnel UP (DOWN/LEAK thì restart app vô ích — app sẽ chờ net; tránh churn).
    if [[ "$net" == "UP" ]]; then
      local hb
      hb=$(hb_age "$h")
      if [[ -n "$hb" && "$hb" -gt 600 ]]; then
        warn "heal: $app không cập nhật heartbeat ${hb}s (treo?) -> restart"
        dk restart "$app" >/dev/null 2>&1 || true
      fi
    fi
  done < "$STATE"
}
watch_loop(){ log "bắt đầu watch 24/7 (Ctrl-C để dừng)"; while true; do heal_once; sleep 60; done; }

#---------------------- cleanlogs / health (online-earning từ log — KHÔNG qua proxy)
cleanlogs(){
  load_config
  [[ -d "$INSTANCES" ]] || die "chưa có instances/"
  local dir f now age removed=0 bytes=0
  now=$(date +%s)
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    age=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
    if (( age > WIN_LOG_RETENTION_DAYS * 86400 )); then
      bytes=$(( bytes + $(stat -c%s "$f" 2>/dev/null || echo 0) ))
      rm -f "$f" && removed=$((removed+1))
    fi
  done < <(find "$INSTANCES" -type f \( -path '*/apps/logs/*' -o -name '*.png' -o -name '.netstate' -o -name '.alive_*' -o -name '.restarts_*' \) 2>/dev/null)
  log "cleanlogs: đã xóa $removed file cũ (> ${WIN_LOG_RETENTION_DAYS} ngày), giải phóng $((bytes/1024))KB."
}

health(){
  load_config
  [[ -s "$STATE" ]] || die "chưa có instance (chạy --start trước)"
  local want="${1:-}"
  local idx h p tun app comp tz country screen vnc
  local online_pat="${LOG_ONLINE:-online|earning|connected}"
  local error_pat="${LOG_ERROR:-error|failed|refus|timeout}"
  local lookback="${WIN_LOG_LOOKBACK_MIN:-60}"
  local cutoff; cutoff=$(date -u -d "-${lookback} min" "+%Y-%m-%dT%H:%M:%S" 2>/dev/null || echo "0000-00-00T00:00:00")
  printf '\n=== HEALTH / ONLINE-EARNING (parse log %s phút gần nhất — KHÔNG gọi qua proxy) ===\n' "$lookback"
  local k dir f filtered on er st net hb rest lastline lastage app_st tun_st host port ok auth restc creds user pass
  while IFS=$'\t' read -r idx h p tun app comp tz country screen vnc; do
    [[ -n "$want" && "$idx" != "$want" ]] && continue
    dir="$(inst_apps_dir "$h")"
    tun_st=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
    app_st=$(dk inspect -f '{{.State.Status}}' "$app" 2>/dev/null || echo missing)
    net=$(app_net_state "$app"); [[ "$net" == "?" ]] && net=$(cut -d'|' -f2 <<< "$(netstate_of "$h")"); [[ -z "$net" ]] && net="-"

    # proxy tầng kết nối (CHỈ từ IP VPS, TCP connect + bắt tay — không qua proxy)
    IFS='|' read -r host port <<< "$(proxy_hostport "$p")"
    if tcp_reachable "$host" "$port"; then ok="OK"; else ok="FAIL"; fi
    auth="TCP"
    if [[ "$p" == socks5://* ]]; then
      restc="${p#*://}"
      if [[ "$restc" == *"@"* ]]; then
        creds="${restc%@*}"; user="${creds%%:*}"; pass="${creds#*:}"
        socks5_auth "$host" "$port" "$user" "$pass" && auth="OK" || auth="FAIL"
      fi
    fi

    echo "--------------------------------------------------------------------------"
    printf 'IDX %s  %s (%s/%s)\n' "$idx" "$comp" "$country" "$tz"
    printf '  proxy : %s  [TCP=%s AUTH=%s]\n' "$(mask_proxy "$p")" "$ok" "$auth"
    printf '  TUN   : %-8s  app: %-8s  net=%s  heartbeat=%s\n' "$tun_st" "$app_st" "$net" "$(fmt_age "$(hb_age "$h")")"

    for k in ${WIN_APPS//,/ }; do
      k="${k//[^A-Za-z0-9_]/}"; [[ -z "$k" ]] && continue
      eval "local onp=\${${k}_LOG_ONLINE:-}"
      eval "local erp=\${${k}_LOG_ERROR:-}"
      onp="${onp:-$online_pat}"; erp="${erp:-$error_pat}"
      f="$dir/logs/${k}.log"
      filtered=""
      [[ -f "$f" ]] && filtered=$(awk -v c="$cutoff" 'length($0)>=20 && substr($0,2,19) >= c' "$f" 2>/dev/null)
      [[ -f "$f.1" ]] && filtered+=$'\n'"$(awk -v c="$cutoff" 'length($0)>=20 && substr($0,2,19) >= c' "$f.1" 2>/dev/null)"
      on=$(grep -cE "$onp" <<< "$filtered" 2>/dev/null); [[ -z "$on" || ! "$on" =~ ^[0-9]+$ ]] && on=0
      er=$(grep -cE "$erp" <<< "$filtered" 2>/dev/null); [[ -z "$er" || ! "$er" =~ ^[0-9]+$ ]] && er=0
      rest=$(cat "$dir/.restarts_${k}" 2>/dev/null); [[ "$rest" =~ ^[0-9]+$ ]] || rest=0
      if [[ ! -f "$f" ]]; then st="NOLOG"
      elif (( er > 0 && on == 0 )); then st="ERROR"
      elif (( er > 0 )); then st="WARN"
      elif (( on > 0 )); then st="ONLINE"
      else st="IDLE"; fi
      lastage=""; lastline=""
      if [[ -f "$f" ]]; then
        lastline=$(tail -n 1 "$f" 2>/dev/null)
        local lastts; lastts=$(echo "$lastline" | sed -nE 's/^\[(.*)Z\].*/\1/p' | tr 'T' ' ')
        [[ -n "$lastts" ]] && lastage=$(( $(date +%s) - $(date -u -d "$lastts" +%s 2>/dev/null || echo $(date +%s)) ))
      fi
      printf '  %-14s %-8s (online=%s, err=%s, restarts=%s, lastlog=%s)\n' "$k" "$st" "$on" "$er" "$rest" "$(fmt_age "${lastage:-}")"
    done
    echo
  done < "$STATE"
  echo "Gợi ý: ONLINE=đang có tín hiệu · WARN=vừa online vừa có lỗi · ERROR=log toàn lỗi (proxy/auth/mạng)"
  echo "        IDLE=chạy nhưng im · NOLOG=chưa ghi log. net=LEAK là NGHIÊM TRỌNG (lộ IP VPS) — chạy --heal ngay."
  echo "        Proxy TCP/AUTH chỉ kiểm tra từ IP VPS (không gọi qua proxy)."
}

#---------------------- validate / build / install
validate(){
  load_config
  # --- IP VPS: bắt buộc biết để whitelist cho proxy IP-Auth
  local vip
  if vip=$(get_vps_ip 2>/dev/null); then
    log "IP VPS (nguồn đi tới proxy) = ${vip}  <- whitelist IP này trong dashboard proxy IP-Auth"
  else
    warn "không lấy được IP VPS. Đặt VPS_IP=<ip> trong properties.conf (hoặc để trống proxy IP-Auth)."
  fi

  if [[ ! -f "$PROXIES" ]] || ! grep -qE '^[[:space:]]*[^#[:space:]]' "$PROXIES" 2>/dev/null; then
    warn "proxies.txt chưa có dòng proxy nào (chỉ đang là mẫu). Thêm proxy trước khi --start."
  else
    read_proxies
    log "proxy hợp lệ: ${#PROXY_LIST[@]} dòng"
    log "  Kiểm tra proxy: sudo bash winIncome.sh --checkproxy  (chỉ dùng IP VPS $vip, KHÔNG gọi qua proxy)."
    log "  MỌI proxy (kể cả user:pass) đều phải whitelist IP VPS $vip nếu proxy dùng IP-Auth."
  fi
  log "WIN_APPS: ${WIN_APPS:-<rỗng>}"
  local k
  for k in ${WIN_APPS//,/ }; do
    k="${k//[^A-Za-z0-9_]/}"
    eval "local exe=\${${k}_LAUNCH:-}"; eval "local inst=\${${k}_INSTALLER:-}"
    log "  $k : installer=$inst launch=$exe"
    if [[ -n "$inst" && ! -f "$INSTALLERS/$inst" ]]; then
      eval "local u=\${${k}_URL:-}"
      if [[ -n "$u" ]]; then
        warn "    chưa có installers/$inst -> chạy: sudo bash winIncome.sh --fetch"
      else
        warn "    chưa có installers/$inst (tải tay hoặc thêm ${k}_URL vào properties.conf)"
      fi
    fi
  done
  [[ -f "$IDENTITY_BIN" ]] || die "thiếu $IDENTITY_BIN"
  log "validate xong (không tốn bandwidth)."
}

build(){
  need docker
  # MSFONTS=1 -> cài font MS thật (Arial/Times...) cho canvas fingerprint sát hơn
  dk build --build-arg MSFONTS="${MSFONTS:-1}" -f "$DOCKERFILE" -t "$WIN_IMAGE" "$ROOT" || die "build thất bại"
  log "đã build $WIN_IMAGE (MSFONTS=${MSFONTS:-1})"
}

install_docker(){
  if command -v docker >/dev/null 2>&1; then log "docker đã có: $(docker --version)"; return 0; fi
  (command -v apt-get >/dev/null && apt-get update -y && apt-get install -y docker.io) \
    || (command -v yum >/dev/null && yum install -y docker) \
    || die "không cài được docker tự động — xem https://docs.docker.com/engine/install/"
  systemctl enable --now docker 2>/dev/null || true
  log "đã cài docker."
}

#---------------------- setup (1 lệnh từ A-Z) / doctor / watch service
setup(){
  local auto=1
  [[ "${2:-}" == "--no-start" ]] && auto=0
  log "=== WIN_PROXY SETUP (tự động toàn bộ) ==="
  install_docker
  load_config
  local vip; vip=$(get_vps_ip 2>/dev/null || echo "")
  if [[ -n "$vip" ]]; then
    log "IP VPS = $vip  -> đây là IP cần WHITELIST cho proxy IP-Authentication."
  else
    warn "Không xác định được IP VPS (nếu dùng proxy IP-Auth, đặt VPS_IP=<ip> trong properties.conf)."
  fi
  build
  fetch_installers
  validate
  if [[ "$auto" == 1 ]]; then
    if grep -qE '^[[:space:]]*[^#[:space:]]' "$PROXIES" 2>/dev/null; then
      log "đã có proxy trong $PROXIES -> --start ngay."
      start_all
    else
      warn "chưa có proxy. Điền proxies.txt rồi chạy: sudo bash winIncome.sh --start"
    fi
  fi
  log "=== SETUP HOÀN TẤT ==="
}

doctor(){
  log "=== CHẨN ĐOÁN (doctor) ==="
  local ok=1
  command -v docker >/dev/null 2>&1 && { docker info >/dev/null 2>&1 && log "Docker        : OK" || { warn "Docker daemon chưa chạy (sudo systemctl start docker)"; ok=0; }; } || { warn "Docker chưa cài (sudo bash winIncome.sh --install)"; ok=0; }
  case "$(uname -m)" in x86_64|amd64) log "Kiến trúc     : amd64 (OK)" ;; *) warn "Kiến trúc $(uname -m): Wine tier cần amd64"; ok=0 ;; esac
  # nhiều default route = nguy cơ egress đi sai NIC -> proxy IP-Auth thấy sai IP nguồn
  if command -v ip >/dev/null 2>&1; then
    local nroute; nroute=$(ip -4 route show default 2>/dev/null | wc -l)
    (( nroute == 1 )) && log "Default route : 1 (OK)" || warn "Có $nroute default route — nhiều NIC có thể làm proxy IP-Auth thấy sai IP nguồn!"
  else
    warn "không có lệnh 'ip' — bỏ qua kiểm tra default route."
  fi
  local vip; vip=$(get_vps_ip 2>/dev/null || echo "")
  [[ -n "$vip" ]] && log "IP VPS        : $vip (whitelist cho proxy IP-Auth)" || warn "Không lấy được IP VPS (đặt VPS_IP= trong properties.conf)"
  [[ -f "$CONF" ]] && log "properties.conf: OK" || { warn "thiếu $CONF"; ok=0; }
  [[ -f "$IDENTITY_BIN" ]] && log "identity.sh   : OK" || { warn "thiếu identity.sh"; ok=0; }
  grep -qE '^[[:space:]]*[^#[:space:]]' "$PROXIES" 2>/dev/null && log "proxies.txt   : có proxy" || { warn "proxies.txt rỗng (thêm proxy)"; ok=0; }
  [[ -c /dev/net/tun ]] && log "/dev/net/tun  : OK" || { warn "/dev/net/tun chưa có (modprobe tun hoặc chạy setup_vps.sh)"; ok=0; }
  if command -v docker >/dev/null 2>&1; then
    load_config 2>/dev/null
    docker image inspect "$TUN_IMAGE" >/dev/null 2>&1 && log "image TUN     : OK" || { warn "chưa có image $TUN_IMAGE (sẽ pull lúc --start)"; ok=0; }
    docker image inspect "$WIN_IMAGE" >/dev/null 2>&1 && log "image Win-box : OK" || { warn "chưa có image $WIN_IMAGE (sudo bash winIncome.sh --build)"; ok=0; }
  fi
  local k miss=0
  for k in ${WIN_APPS//,/ }; do
    k="${k//[^A-Za-z0-9_]/}"; [[ -z "$k" ]] && continue
    eval "local inst=\${${k}_INSTALLER:-}"
    [[ -n "$inst" && ! -f "$INSTALLERS/$inst" ]] && { warn "thiếu installer $inst (--fetch)"; miss=1; ok=0; }
  done
  [[ "$miss" == 0 ]] && log "installers    : OK"
  if [[ "$ok" == 1 ]]; then
    log "Doctor: mọi thứ sẵn sàng -> sudo bash winIncome.sh --start"
  else
    warn "Doctor: còn mục cần xử lý (xem ở trên). Chạy --setup để tự động hóa hết."
  fi
}

myip(){
  load_config
  local vip
  if vip=$(get_vps_ip 2>/dev/null); then
    log "IP VPS (nguồn kết nối tới proxy) = $vip"
    log "Proxy IP-Auth: whitelist chính xác IP $vip trong dashboard proxy."
  else
    die "Không lấy được IP VPS. Đặt VPS_IP=<ip> trong properties.conf rồi chạy lại."
  fi
}

install_watch(){
  local unit="/etc/systemd/system/winproxy-watch.service"
  cat > "$unit" <<EOF
[Unit]
Description=WinProxy auto-heal/watchdog
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/bin/bash $ROOT/winIncome.sh --watch
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable --now winproxy-watch.service 2>/dev/null \
    && log "đã cài systemd watch (tự heal 24/7)." || warn "cần chạy bằng sudo."
}

login_instance(){
  load_config
  local idx="${1:-1}" key="${2:-}" IFS line h tun app p
  IFS=$'\t' read -r h tun app p <<< "$(get_by_idx "$idx")"
  [[ -n "$app" ]] || die "instance $idx không tồn tại"
  # chạy với -u wineuser (khớp user sở hữu Xvfb/wine, tránh lỗi xdotool khi container chạy entrypoint root)
  if [[ -n "$key" ]]; then
    dk exec -u wineuser "$app" /usr/local/bin/login.sh "$key" 2>&1 || warn "login thất bại (xem log)"
  else
    # login tất cả app có credentials trong container
    dk exec -u wineuser "$app" bash -c 'for k in ${WIN_APPS//,/ }; do /usr/local/bin/login.sh "$k"; done' 2>&1 || warn "login thất bại"
  fi
}

shot_instance(){
  load_config
  local idx="${1:-1}" key="${2:-}" IFS line h tun app p
  IFS=$'\t' read -r h tun app p <<< "$(get_by_idx "$idx")"
  [[ -n "$app" ]] || die "instance $idx không tồn tại"
  local k; [[ -n "$key" ]] && k="$key" || k="${WIN_APPS%%,*}"
  k="${k//[^A-Za-z0-9_]/}"
  dk exec -u wineuser "$app" /usr/local/bin/login.sh "$k" shot 2>&1 || warn "chụp ảnh thất bại"
  local f="$INSTANCES/$h/prefix/apps/${k}.png"
  if [[ -f "$f" ]]; then log "ảnh: $f"; else warn "chưa có ảnh $f (app chưa mở cửa sổ? chạy lại sau vài giây)"; fi
  return 0
}

#---------------------- main
case "${1:-}" in
  --install)       install_docker ;;
  --build)         load_config; build ;;
  --validate)      validate ;;
  --checkproxy)    checkproxy ;;
  --start)         start_all ;;
  --status)        status ;;
  --logs)          logs "${2:-1}" ;;
  --health)        health "${2:-}" ;;
  --cleanlogs)     cleanlogs ;;
  --probe)         probe "${2:-1}" ;;
  --leaktest)      leaktest "${2:-1}" ;;
  --fetch)         fetch_installers ;;
  --restart)       restart_all ;;
  --stop)          stop_all ;;
  --delete)        delete_all ;;
  --deleteBackup)  delete_backup ;;
  --heal)          heal_once; log "heal xong." ;;
  --watch)         watch_loop ;;
  --setup)         setup "${2:-}" ;;
  --doctor)        doctor ;;
  --myip)          myip ;;
  --install-watch) install_watch ;;
  --login)         login_instance "${2:-1}" "${3:-}" ;;
  --shot)          shot_instance "${2:-1}" "${3:-}" ;;
  *)               usage ;;
esac

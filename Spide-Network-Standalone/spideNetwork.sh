#!/usr/bin/env bash
# Spide Network standalone — self-contained TUN proxy + Spide peers.
#
# === v1.4.0 — TOI UU CHO CA VPS LAN VM ===
# - HOAN TOAN KHONG kiem tra egress IP qua dich vu ngoai (ipify/curl).
#   Proxy CHI duoc Spide peer dung de ket noi toi Spide platform.
#   Moi thao tac build/pull/quan ly container di bang IP cua chinh may chu.
# - MTU=1400 / MSS=1360 + tcp-timeout 300s: chong treo session / PMTU
#   blackhole (nguyen nhan "log Status OK nhung dashboard bao offline"),
#   vua an toan cho VPS datacenter vua cho VM o nha.
# - TUN log muc warn de thay loi khi co su co.
# - Lenh --heal / --watch: tu khoi phuc node bi treo (qua 5 phut khong
#   co Status: OK thi restart), tu khoi dong TUN chet va noi lai peer.
# - Chong chay trung tien trinh (flock), loc proxy trung, pull TUN chiu loi.
#
# Lenh:
#   --create    Tao node va xuat Device Key
#   --deploy    Sau khi add key tren dashboard: restart peer de xac thuc
#   --update    Dong bo proxies.txt (proxy cu giu Machine ID)
#   --remove    Xoa container (giu spide-data)
#   --heal      Quet 1 luot, restart node bi treo/TUN chet (dung cho cron)
#   --watch     Chay --heal lap lai 60s/lan (canh 24/7, dung trong tmux/screen)
#   --keys      In lai Device Key
#   --status    Trang thai container
#   --logs [n]  Xem log peer (n = index; bo trong xem tat ca)
#   --validate  Kiem tra format proxy + TUN khoi dong (KHONG gui traffic qua proxy)
#   --backup    Dong goi Machine ID + key

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.5.0"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONF="$ROOT/properties.conf"
PROXIES="$ROOT/proxies.txt"
DATA="$ROOT/spide-data"
BUILD_DIR="$DATA/build"
STATE="$DATA/spide-nodes.tsv"
KEYS_FILE="$ROOT/spide-device-keys.txt"
LOCK_FILE="$DATA/.spide.lock"
IMAGE="local/spide-standalone:0.15b"
# Tu dong chon ban Spide theo kien truc CPU (ho tro x86_64 va ARM64/Oracle Ampere).
_SP_ARCH="$(uname -m)"
case "$_SP_ARCH" in
  x86_64|amd64)
    SPIDE_URL="https://pub-bf426a5300a643d2884389c8985f5181.r2.dev/spide_linux_cli.zip"
    SPIDE_SHA256="ae03e67109ba125f8b317dedb3dd31a3df745f75ed647abd57e7deef6328250c"
    SPIDE_BIN=/usr/local/bin/spide ;;
  aarch64|arm64)
    # Ten file mac dinh; neu Spide doi ten, chi can sua dong duoi.
    SPIDE_URL="https://pub-bf426a5300a643d2884389c8985f5181.r2.dev/spide_linux_arm64.zip"
    SPIDE_SHA256=""   # chua ky hash; xac minh bang cach chay thu binary
    SPIDE_BIN=/usr/local/bin/spide ;;
  *)
    SPIDE_URL="https://pub-bf426a5300a643d2884389c8985f5181.r2.dev/spide_linux_cli.zip"
    SPIDE_SHA256=""; SPIDE_BIN=/usr/local/bin/spide ;;
esac
TUN_IMAGE="ghcr.io/tun2proxy/tun2proxy:v0.8.3"
PROJECT_ID="$(printf '%s' "$ROOT" | sha256sum | awk '{print substr($1,1,10)}')"
PROJECT_LABEL="com.spide-standalone.project=$PROJECT_ID"

if [[ -t 1 ]]; then
  G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N=$'\033[0m'
else G=''; Y=''; R=''; N=''; fi
log(){  printf '%s[OK]%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s[!!]%s %s\n' "$Y" "$N" "$*" >&2; }
die(){  printf '%s[XX]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'rc=$?; printf "%s[XX]%s Loi dong %s (exit=%s)\n" "$R" "$N" "${BASH_LINENO[0]:-?}" "$rc" >&2; exit "$rc"' ERR

usage(){ cat <<'EOF'
Spide Network — cac lenh

CHE DO PROXY (dung proxies.txt, moi peer di qua TUN):
  --create    Tao node (proxy moi sinh key moi, proxy cu giu Machine ID)
  --deploy    Sau khi add key dashboard: restart peer de xac thuc
  --update    Dong bo proxies.txt
  --remove    Xoa container (giu spide-data)
  --heal      1 luot tu phuc hoi (dung cron 5 phut)
  --watch     Canh 24/7 (lap lai 60s/lan)
  --keys | --status | --logs [n] | --validate | --backup

CHE DO HOST (chay bang IP GOC, KHONG can proxies.txt):
  --host          Tao/tao lai 1 Spide container di thang ra IP may
  --host-status   Trang thai container host
  --host-keys     Lay Device Key de add vao dashboard
  --host-logs     Xem log realtime
  --host-remove   Xoa container host (giu machine-id)

Vi du thu tren VPS co IP tot (Oracle Free...):
  bash spideNetwork.sh --host
  bash spideNetwork.sh --host-keys

Proxy CHI duoc Spide peer (che do proxy) dung de ket noi Spide platform.
Khong bao gio co kiem tra IP qua dich vu ngoai.
EOF
}

need(){ command -v "$1" >/dev/null 2>&1 || die "Thieu lenh: $1"; }
dk(){
  if docker info >/dev/null 2>&1; then docker "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then sudo docker "$@"
  else die "Khong truy cap duoc Docker daemon"; fi
}

acquire_lock(){
  mkdir -p "$DATA"
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Mot tien trinh spideNetwork dang chay (lock: $LOCK_FILE). Thoat."
}

# Canh bao moi truong Docker de chay on dinh tren nhieu loai VPS.
docker_env_check(){
  need docker
  local driver tz
  driver=$(docker info 2>/dev/null | awk -F': ' '/Storage Driver/{print $2; exit}')
  echo "Docker storage driver: ${driver:-?}"
  case "$driver" in
    overlay2|btrfs|zfs) ;;   # tot
    vfs) warn "Driver 'vfs' rat cham/ton dia. Nen dung overlay2 (kernel >=4.x ho tro).";;
    aufs) warn "Driver 'aufs' cu; khuyen nghi overlay2.";;
    "") warn "Khong doc duoc driver Docker.";;
    *) :;;
  esac
  # Thoi gian he thong (sai gio gay loi SSL/timeout)
  if ! timedatectl -p NTPSynchronized --value show >/dev/null 2>&1; then :; fi
  local off; off=$(chronyc tracking 2>/dev/null | awk '/Last offset/{print $4}')
  [[ -n "$off" ]] && echo "Do lech dong ho: ${off}s"
}

# Chuyen timestamp Docker (RFC3339 co nano giay) ve epoch.
to_epoch(){ date -d "$(printf '%s' "$1" | sed -E 's/^([0-9T:.-]+)\.[0-9]+Z/\1Z/')" +%s 2>/dev/null || echo 0; }

ensure_conf(){
  [[ -f "$CONF" ]] && return 0
  cat > "$CONF" <<'EOF'
# Spide Network — cau hinh (tu tao mac dinh)
DEVICE_PREFIX=auto
DEPLOY_WAIT=20
USE_PROXIES=true
USE_SOCKS5_DNS=false
USE_DNS_OVER_HTTPS=true
SPIDE_MAX_INSTANCES=0
SPIDE_VALIDATE_EGRESS=false
SPIDE_SKIP_DUPLICATE_EGRESS=true
SPIDE_MAX_MEMORY=auto
SPIDE_MEMORY_RESERVATION=auto
SPIDE_MEMORY_SWAP=auto
SPIDE_CPU=auto
TUN_MAX_MEMORY=auto
TUN_MEMORY_SWAP=auto
TUN_CPU=auto
START_DELAY=1
TUN_READY_TIMEOUT=10
# MTU thap tranh treo session/PMTU qua proxy (phu hop ca VPS lan VM).
TUN_MTU=1400
TUN_TCP_MSS=1360
TUN_TCP_TIMEOUT=300
TUN_VERBOSITY=warn
# Tu phuc hoi: restart peer neu qua bao lau khong co Status: OK
HEAL_STALE_SEC=300
WATCH_INTERVAL=60
EOF
  chmod 600 "$CONF"
  log "Da tao $CONF voi cau hinh mac dinh."
}

load_config(){
  ensure_conf
  DEVICE_PREFIX=auto
  DEPLOY_WAIT=20
  USE_PROXIES=true
  USE_SOCKS5_DNS=false
  USE_DNS_OVER_HTTPS=true
  SPIDE_MAX_INSTANCES=0
  # Egress check BA TAT CUNG: khong bao gio dung proxy goi dich vu ngoai.
  SPIDE_VALIDATE_EGRESS=false
  SPIDE_SKIP_DUPLICATE_EGRESS=true
  SPIDE_MAX_MEMORY=auto
  SPIDE_MEMORY_RESERVATION=auto
  SPIDE_MEMORY_SWAP=auto
  SPIDE_CPU=auto
  TUN_MAX_MEMORY=auto
  TUN_MEMORY_SWAP=auto
  TUN_CPU=auto
  START_DELAY=1
  TUN_READY_TIMEOUT=10
  TUN_MTU=1400
  TUN_TCP_MSS=1360
  TUN_TCP_TIMEOUT=300
  TUN_VERBOSITY=warn
  HEAL_STALE_SEC=300
  WATCH_INTERVAL=60
  set +x
  # shellcheck disable=SC1090
  source "$CONF"
  if [[ "$SPIDE_VALIDATE_EGRESS" != false ]]; then
    warn "SPIDE_VALIDATE_EGRESS da bi tat cung (proxy chi dung cho Spide platform)."
    SPIDE_VALIDATE_EGRESS=false
  fi
  if [[ "$DEVICE_PREFIX" == auto || -z "$DEVICE_PREFIX" ]]; then
    DEVICE_PREFIX=$(basename "$ROOT")
  fi
  DEVICE_PREFIX=$(printf '%s' "$DEVICE_PREFIX" | sed 's/[^A-Za-z0-9._-]/-/g;s/^-*//;s/-*$//')
  [[ -n "$DEVICE_PREFIX" ]] || DEVICE_PREFIX=Spide
  [[ "$DEPLOY_WAIT" =~ ^[0-9]+$ ]] || die "DEPLOY_WAIT phai la so giay"
  [[ "$USE_PROXIES" == true ]] || die "Standalone nay can USE_PROXIES=true"
  for v in USE_SOCKS5_DNS USE_DNS_OVER_HTTPS SPIDE_VALIDATE_EGRESS SPIDE_SKIP_DUPLICATE_EGRESS; do
    [[ "${!v}" == true || "${!v}" == false ]] || die "$v phai la true hoac false"
  done
  [[ "$SPIDE_MAX_INSTANCES" =~ ^[0-9]+$ ]] || die "SPIDE_MAX_INSTANCES phai la so >= 0"
  [[ "$START_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "START_DELAY khong hop le"
  [[ "$TUN_READY_TIMEOUT" =~ ^[0-9]+$ ]] || TUN_READY_TIMEOUT=10
  [[ "$TUN_MTU" =~ ^[0-9]+$ ]] && (( TUN_MTU >= 576 && TUN_MTU <= 9000 )) || die "TUN_MTU phai la so 576..9000"
  if [[ -z "$TUN_TCP_MSS" || "$TUN_TCP_MSS" == auto ]]; then
    TUN_TCP_MSS=$(( TUN_MTU - 40 ))
  fi
  [[ "$TUN_TCP_MSS" =~ ^[0-9]+$ ]] && (( TUN_TCP_MSS >= 536 && TUN_TCP_MSS < TUN_MTU )) || die "TUN_TCP_MSS phai la so 536..$((TUN_MTU-1))"
  [[ "$TUN_TCP_TIMEOUT" =~ ^[0-9]+$ ]] && (( TUN_TCP_TIMEOUT >= 60 )) || die "TUN_TCP_TIMEOUT phai la so giay >= 60"
  [[ "$TUN_VERBOSITY" =~ ^(off|error|warn|info|debug|trace)$ ]] || die "TUN_VERBOSITY khong hop le"
  [[ "$HEAL_STALE_SEC" =~ ^[0-9]+$ ]] && (( HEAL_STALE_SEC >= 60 )) || HEAL_STALE_SEC=300
  [[ "$WATCH_INTERVAL" =~ ^[0-9]+$ ]] && (( WATCH_INTERVAL >= 15 )) || WATCH_INTERVAL=60
  log "TUN MTU=$TUN_MTU MSS=$TUN_TCP_MSS tcp-timeout=$TUN_TCP_TIMEOUT verbosity=$TUN_VERBOSITY"
}

auto_resources(){
  local mem tier
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if (( mem <= 2500 )); then tier=1
  elif (( mem <= 5000 )); then tier=2
  elif (( mem <= 9000 )); then tier=3
  else tier=4; fi
  case "$tier" in
    1) A_SP_MEM=96m;  A_SP_RES=32m; A_SP_SWAP=192m; A_SP_CPU=0.20; A_TUN_MEM=64m;  A_TUN_SWAP=128m; A_TUN_CPU=0.20 ;;
    2) A_SP_MEM=128m; A_SP_RES=48m; A_SP_SWAP=256m; A_SP_CPU=0.25; A_TUN_MEM=96m;  A_TUN_SWAP=192m; A_TUN_CPU=0.25 ;;
    3) A_SP_MEM=160m; A_SP_RES=64m; A_SP_SWAP=320m; A_SP_CPU=0.35; A_TUN_MEM=128m; A_TUN_SWAP=256m; A_TUN_CPU=0.35 ;;
    *) A_SP_MEM=192m; A_SP_RES=64m; A_SP_SWAP=384m; A_SP_CPU=0.50; A_TUN_MEM=160m; A_TUN_SWAP=320m; A_TUN_CPU=0.50 ;;
  esac
  [[ "$SPIDE_MAX_MEMORY" == auto ]] && SPIDE_MAX_MEMORY=$A_SP_MEM
  [[ "$SPIDE_MEMORY_RESERVATION" == auto ]] && SPIDE_MEMORY_RESERVATION=$A_SP_RES
  [[ "$SPIDE_MEMORY_SWAP" == auto ]] && SPIDE_MEMORY_SWAP=$A_SP_SWAP
  [[ "$SPIDE_CPU" == auto ]] && SPIDE_CPU=$A_SP_CPU
  [[ "$TUN_MAX_MEMORY" == auto ]] && TUN_MAX_MEMORY=$A_TUN_MEM
  [[ "$TUN_MEMORY_SWAP" == auto ]] && TUN_MEMORY_SWAP=$A_TUN_SWAP
  [[ "$TUN_CPU" == auto ]] && TUN_CPU=$A_TUN_CPU
  for v in SPIDE_MAX_MEMORY SPIDE_MEMORY_RESERVATION SPIDE_MEMORY_SWAP TUN_MAX_MEMORY TUN_MEMORY_SWAP; do
    [[ "${!v}" =~ ^[1-9][0-9]*[mMgG]$ ]] || die "$v khong hop le: ${!v}"
  done
  for v in SPIDE_CPU TUN_CPU; do
    [[ "${!v}" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || die "$v khong hop le: ${!v}"
  done
  log "Resource tier $tier: Spide=$SPIDE_MAX_MEMORY/$SPIDE_MEMORY_SWAP CPU=$SPIDE_CPU; TUN=$TUN_MAX_MEMORY/$TUN_MEMORY_SWAP"
}

prereq(){
  for c in docker flock sha256sum awk sed grep head date; do need "$c"; done
  # Spide ho tro ca x86_64 va arm64; khong chan o day.
  [[ -c /dev/net/tun ]] || die "Khong co /dev/net/tun; hay bat TUN cho VM/VPS"
  mkdir -p "$DATA/nodes"; chmod 700 "$DATA" "$DATA/nodes"
}

read_proxies(){
  [[ -f "$PROXIES" ]] || die "Khong tim thay $PROXIES"
  mapfile -t RAW_PROXIES < <(sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$PROXIES" | grep -vE '^(#|$)')
  ((${#RAW_PROXIES[@]})) || die "proxies.txt dang rong"
  local p
  for p in "${RAW_PROXIES[@]}"; do
    [[ "$p" =~ ^(http|https|socks4|socks5)://.+:[0-9]{1,5}$ ]] || die "Proxy khong hop le (can protocol://user:pass@host:port): $p"
  done
  PROXY_LIST=()
  declare -gA seen_proxy_hash=()
  local h
  for p in "${RAW_PROXIES[@]}"; do
    h=$(hash_proxy "$p")
    if [[ -n "${seen_proxy_hash[$h]:-}" ]]; then
      warn "Bo proxy trung: ${p%%:*}... (da co o dong truoc)"
      continue
    fi
    seen_proxy_hash[$h]=1
    PROXY_LIST+=("$p")
  done
  ((${#PROXY_LIST[@]})) || die "Sau khi loc trung, proxies.txt khong con proxy hop le"
}

tun_dns_mode(){
  local proxy="$1"
  if [[ "$USE_SOCKS5_DNS" == true && "$proxy" == socks5://* ]]; then
    printf 'over-tcp'
  elif [[ "$USE_DNS_OVER_HTTPS" == true ]]; then
    printf 'over-tcp'
  else
    printf 'virtual'
  fi
}

hash_proxy(){ printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'; }
tun_name(){ printf 'spn-%s-tun-%03d-%s' "$PROJECT_ID" "$1" "${2:0:6}"; }
peer_name(){ printf 'spn-%s-peer-%03d-%s' "$PROJECT_ID" "$1" "${2:0:6}"; }
node_dir(){ printf '%s/nodes/%s' "$DATA" "$1"; }

build_spide(){
  dk image inspect "$IMAGE" >/dev/null 2>&1 && return 0
  mkdir -p "$BUILD_DIR"
  # Chenh lech theo kien truc: sha256 chi kiem khi co gia tri (ban x86 da ky).
  local sha_line="true"
  [[ -n "$SPIDE_SHA256" ]] && sha_line="echo \"$SPIDE_SHA256  /tmp/spide.zip\" | sha256sum -c -"
  cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM alpine:3.22
RUN apk add --no-cache ca-certificates wget unzip file libc6-compat \\
 && wget -q -T 45 -t 3 -O /tmp/spide.zip "$SPIDE_URL" \\
 && $sha_line \\
 && unzip -q /tmp/spide.zip -d /tmp/spide \\
 && BIN=\\$(find /tmp/spide -type f -name spide | head -1) \\
 && test -n "\\$BIN" || (echo "Khong tim thay binary spide trong archive (co the URL/sai kien truc)" && exit 1) \\
 && install -m 0755 "\\$BIN" /usr/local/bin/spide \\
 && (file /usr/local/bin/spide | grep -qi ELF || (echo "File tai ve khong phai ELF binary - sai kien truc?" && exit 1)) \\
 && chmod +x /usr/local/bin/spide \\
 && rm -rf /tmp/spide /tmp/spide.zip \\
 && addgroup -g 10001 spide \\
 && adduser -D -H -u 10001 -G spide spide
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/spide"]
EOF
  log "Build image Spide (lan dau, kien truc $(uname -m))..."
  # Build thuong: Docker tu dung arch cua host (chay duoc ca x86_64 va arm64).
  dk build --pull -t "$IMAGE" "$BUILD_DIR" || {
    rm -rf "$BUILD_DIR"
    die "Build image that bai. Kiem tra $SPIDE_URL co ho tro kien truc $(uname -m) khong."
  }
  rm -rf "$BUILD_DIR"
}

ensure_tun_image(){
  if dk image inspect "$TUN_IMAGE" >/dev/null 2>&1; then
    dk pull "$TUN_IMAGE" >/dev/null 2>&1 || warn "Khong pull duoc $TUN_IMAGE; dung ban local da cache."
  else
    dk pull "$TUN_IMAGE" >/dev/null 2>&1 || die "Khong pull duoc $TUN_IMAGE va khong co ban local."
  fi
}

ensure_machine_id(){
  local h="$1" d f id
  d=$(node_dir "$h"); f="$d/machine-id"; mkdir -p "$d"; chmod 700 "$d"
  if [[ -s "$f" ]]; then id=$(tr -d '\r\n[:space:]' < "$f"); else id=$(head -c 64 /dev/urandom | sha256sum | awk '{print substr($1,1,32)}'); fi
  [[ "$id" =~ ^[a-fA-F0-9]{32}$ ]] || die "Machine ID loi: $f"
  printf '%s\n' "${id,,}" > "$f"; chmod 644 "$f"; printf '%s' "$f"
}

remove_project_containers(){
  local n
  while IFS= read -r n; do [[ -n "$n" ]] && dk rm -f "$n" >/dev/null 2>&1 || true; done < <(dk ps -a --filter "label=$PROJECT_LABEL" --format '{{.Names}}')
}

wait_container_running(){
  local name="$1" timeout="${2:-10}" elapsed=0 state
  while (( elapsed < timeout )); do
    state=$(dk inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)
    case "$state" in
      running) return 0 ;;
      exited|dead) return 1 ;;
    esac
    sleep 1; elapsed=$((elapsed+1))
  done
  return 1
}

# Cac co' chung cho lenh docker run TUN (truyen them vi tri sau cung).
tun_run_args(){
  local dns_mode="$1" proxy="$2"
  printf '%s\n' \
    --device /dev/net/tun --cap-add NET_ADMIN --security-opt no-new-privileges:true \
    --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 \
    --ulimit nofile=65536:65536 \
    --log-driver local --log-opt max-size=1m --log-opt max-file=2 \
    "$TUN_IMAGE" --dns "$dns_mode" --proxy "$proxy" \
    --mtu "$TUN_MTU" --tcp-mss "$TUN_TCP_MSS" --tcp-timeout "$TUN_TCP_TIMEOUT" \
    --verbosity "$TUN_VERBOSITY"
}

start_all(){
  prereq; require_tun; acquire_lock; load_config; auto_resources; read_proxies; build_spide; ensure_tun_image
  docker_env_check >&2 || true
  remove_project_containers
  : > "$STATE"; chmod 600 "$STATE"
  local total_raw=${#RAW_PROXIES[@]}
  local count=${#PROXY_LIST[@]} i idx proxy h tun peer midfile mid status key dns_mode created=0
  (( SPIDE_MAX_INSTANCES > 0 && SPIDE_MAX_INSTANCES < count )) && count=$SPIDE_MAX_INSTANCES
  log "Bat dau tao $count node (tu $total_raw proxy sau khi loc trung)..."
  for ((i=0;i<count;i++)); do
    idx=$((i+1)); proxy=${PROXY_LIST[$i]}; h=$(hash_proxy "$proxy")
    tun=$(tun_name "$idx" "$h"); peer=$(peer_name "$idx" "$h"); dns_mode=$(tun_dns_mode "$proxy")
    log "[$idx/$count] Tao TUN gateway $tun (DNS=$dns_mode, MTU=$TUN_MTU)"
    # shellcheck disable=SC2046
    dk run -d --name "$tun" --restart unless-stopped \
      --label "$PROJECT_LABEL" --label "com.spide-standalone.role=tun" --label "com.spide-standalone.proxy-hash=$h" \
      --memory "$TUN_MAX_MEMORY" --memory-swap "$TUN_MEMORY_SWAP" --cpus "$TUN_CPU" --pids-limit 96 \
      $(tun_run_args "$dns_mode" "$proxy") >/dev/null

    if ! wait_container_running "$tun" "$TUN_READY_TIMEOUT"; then
      local tstate
      tstate=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
      warn "Bo qua proxy $idx: TUN khong vay duoc (state=$tstate). Log cuoi:"
      dk logs --tail 8 "$tun" 2>&1 | sed 's/^/    /' >&2 || true
      dk rm -f "$tun" >/dev/null 2>&1 || true
      continue
    fi
    sleep 1
    if ! wait_container_running "$tun" 1; then
      warn "Bo qua proxy $idx: TUN vua chay da chet."
      dk logs --tail 8 "$tun" 2>&1 | sed 's/^/    /' >&2 || true
      dk rm -f "$tun" >/dev/null 2>&1 || true
      continue
    fi

    midfile=$(ensure_machine_id "$h"); mid=$(tr -d '\r\n' < "$midfile")
    log "[$idx/$count] Tao Spide peer $peer"
    dk run -d --name "$peer" --restart unless-stopped \
      --label "$PROJECT_LABEL" --label "com.spide-standalone.role=peer" \
      --label "com.spide-standalone.index=$idx" --label "com.spide-standalone.tun=$tun" \
      --network "container:$tun" --read-only --tmpfs /tmp:size=32m,mode=1777 \
      --security-opt no-new-privileges:true --cap-drop ALL --pids-limit 64 \
      --ulimit nofile=65536:65536 \
      --memory "$SPIDE_MAX_MEMORY" --memory-reservation "$SPIDE_MEMORY_RESERVATION" \
      --memory-swap "$SPIDE_MEMORY_SWAP" --cpus "$SPIDE_CPU" \
      --log-driver local --log-opt max-size=1m --log-opt max-file=2 \
      --mount "type=bind,source=$midfile,target=/etc/machine-id,readonly" "$IMAGE" >/dev/null
    sleep "$START_DELAY"

    local pstate
    pstate=$(dk inspect -f '{{.State.Status}}' "$peer" 2>/dev/null || echo missing)
    if [[ "$pstate" != "running" ]]; then
      warn "Peer $peer vua tao khong chay (state=$pstate). Xem log: bash spideNetwork.sh --logs $idx"
    fi

    key=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Device Key:[[:space:]]*//p' | tail -1 || true)
    status=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$h" "$tun" "$peer" "-" "$mid" "${key:--}" "${status:--}" >> "$STATE"
    created=$((created+1))
  done

  if (( created == 0 )); then
    die "Khong tao duoc node nao. Kiem tra proxies.txt va log TUN, roi chay lai."
  fi
  log "Da tao $created node. Chay --keys de lay Device Key."
  show_keys
}

show_keys(){
  [[ -s "$STATE" ]] || die "Chua co node; chay --create"
  local tmp="$KEYS_FILE.tmp" device_name key status
  {
    printf '# Spide Device Keys — generated %s\n' "$(date '+%F %T %Z')"
    printf '# Paste Device name + Device key vao Spide dashboard.\n\n'
  } > "$tmp"

  printf 'INDEX\tPROXY_ID\tCONTAINER\tMACHINE_ID\tDEVICE_KEY\tSTATUS\n'
  while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
    dk inspect "$peer" >/dev/null 2>&1 || continue
    key=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Device Key:[[:space:]]*//p' | tail -1 || true)
    status=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    device_name=$(printf '%s-%03d' "$DEVICE_PREFIX" "$idx")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$h" "$peer" "$mid" "${key:--}" "${status:--}"
    {
      printf 'Device name: %s\n' "$device_name"
      printf 'Device key: %s\n' "${key:--}"
      printf 'Status: %s\n\n' "${status:--}"
    } >> "$tmp"
  done < "$STATE"

  mv "$tmp" "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
  log "Da xuat file key: $KEYS_FILE"
}

show_status(){
  [[ -s "$STATE" ]] || die "Chua co node; chay --start"
  printf 'INDEX\tTUN_STATE\tPEER_STATE\tNETWORK_MODE\tSTATUS\n'
  while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
    local ts ps nm st
    ts=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
    ps=$(dk inspect -f '{{.State.Status}}' "$peer" 2>/dev/null || echo missing)
    nm=$(dk inspect -f '{{.HostConfig.NetworkMode}}' "$peer" 2>/dev/null || echo -)
    st=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$ts" "$ps" "$nm" "${st:--}"
  done < "$STATE"
}

show_logs(){
  prereq; require_tun; load_config
  [[ -s "$STATE" ]] || die "Chua co node; chay --create"
  local idx="${1:-}" peer
  if [[ -n "$idx" ]]; then
    [[ "$idx" =~ ^[0-9]+$ ]] || die "Index phai la so"
    peer=$(awk -F'\t' -v i="$idx" '$1==i{print $4; exit}' "$STATE")
    [[ -n "$peer" ]] || die "Khong tim thay node index $idx"
    dk logs -f --tail 100 "$peer"
  else
    while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
      printf '\n===== Node %s (peer=%s) =====\n' "$idx" "$peer"
      dk logs --tail 20 "$peer" 2>&1 || true
    done < "$STATE"
  fi
}

validate_only(){
  prereq; acquire_lock; load_config; auto_resources; read_proxies; ensure_tun_image
  local i proxy h tun dns_mode state
  printf 'INDEX\tPROXY_ID\tTUN_STATE\tRESULT\n'
  for i in "${!PROXY_LIST[@]}"; do
    proxy=${PROXY_LIST[$i]}; h=$(hash_proxy "$proxy")
    tun="spn-$PROJECT_ID-check-$((i+1))"; dns_mode=$(tun_dns_mode "$proxy")
    dk rm -f "$tun" >/dev/null 2>&1 || true
    # shellcheck disable=SC2046
    dk run -d --name "$tun" --network bridge --memory "$TUN_MAX_MEMORY" --memory-swap "$TUN_MEMORY_SWAP" \
      --log-driver local --log-opt max-size=1m --log-opt max-file=1 \
      $(tun_run_args "$dns_mode" "$proxy") >/dev/null
    sleep 2
    state=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
    dk rm -f "$tun" >/dev/null 2>&1 || true
    if [[ "$state" == "running" ]]; then
      printf '%s\t%s\t%s\tOK (TUN khoi dong duoc)\n' "$((i+1))" "$h" "$state"
    else
      printf '%s\t%s\t%s\tFAILED (TUN chet ngay; kiem tra proxy/auth)\n' "$((i+1))" "$h" "$state"
    fi
  done
  log "Khong co traffic nao di qua proxy. Chi kiem tra TUN khoi dong."
}

deploy_all(){
  prereq; require_tun; acquire_lock; load_config
  [[ -s "$STATE" ]] || die "Chua co node; chay --create truoc"

  log "Kiem tra TUN gateway..."
  local idx h tun peer ts started_tuns=0
  while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
    if ! dk inspect "$tun" >/dev/null 2>&1; then
      warn "TUN $tun khong ton tai; can chay --update de tao lai node $idx."
      continue
    fi
    ts=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
    if [[ "$ts" != "running" ]]; then
      log "Khoi dong TUN $tun (node $idx)..."
      if dk start "$tun" >/dev/null 2>&1 && wait_container_running "$tun" "$TUN_READY_TIMEOUT"; then
        sleep 1; started_tuns=$((started_tuns+1))
      else
        warn "Khong khoi dong duoc TUN $tun; node $idx co the loi."
      fi
    fi
  done < "$STATE"
  (( started_tuns > 0 )) && log "Da khoi dong $started_tuns TUN."

  local peers=() p ok=0 total=0 status
  mapfile -t peers < <(dk ps -a --filter "label=$PROJECT_LABEL" --filter "label=com.spide-standalone.role=peer" --format '{{.Names}}' | sort -V)
  ((${#peers[@]} > 0)) || die "Khong tim thay peer nao; chay --create."
  log "Restart ${#peers[@]} peer de xac thuc..."
  for p in "${peers[@]}"; do
    dk restart "$p" >/dev/null
    sleep 0.5
  done
  log "Cho ${DEPLOY_WAIT}s de Spide xac thuc..."
  sleep "$DEPLOY_WAIT"

  show_keys
  printf '\n'
  show_status

  for p in "${peers[@]}"; do
    total=$((total+1))
    status=$(dk logs "$p" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    [[ "$status" == OK ]] && ok=$((ok+1))
  done
  if (( ok == total )); then
    log "TRIEN KHAI THANH CONG: $ok/$total node Status=OK"
  else
    warn "Moi co $ok/$total node Status=OK. Kiem tra key dashboard, doi them roi chay --deploy hoac --heal lai."
  fi
}

# Dam bao TUN chay; tra 0 neu TUN dang chay.
__ensure_tun_running(){
  local tun="$1"
  if ! dk inspect "$tun" >/dev/null 2>&1; then return 1; fi
  local state
  state=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
  if [[ "$state" == "running" ]]; then return 0; fi
  dk start "$tun" >/dev/null 2>&1 || return 1
  wait_container_running "$tun" "$TUN_READY_TIMEOUT" && sleep 1
}

# Mot luot tu phuc hoi (chay trong subshell co lock, tranh xung dot voi --update).
__heal_body(){
  local now started started_epoch last_ok le age idx h tun peer pstate restarted=0 started_peers=0 fixed_tuns=0
  now=$(date +%s)
  # 1) Dam bao TUN chay (neu TUN chet/bi restart, peer mac ket namespace cu).
  while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
    local tstate before
    if ! dk inspect "$tun" >/dev/null 2>&1; then
      warn "Heal: TUN $tun khong ton tai (node $idx). Chay --update de tao lai."
      continue
    fi
    tstate=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
    before="$tstate"
    if [[ "$tstate" != "running" ]]; then
      if __ensure_tun_running "$tun"; then
        fixed_tuns=$((fixed_tuns+1))
        log "Heal: da khoi dong lai TUN $tun (node $idx, trang thai cu: $before)."
      else
        warn "Heal: khong khoi dong duoc TUN $tun (node $idx)."
      fi
    fi
  done < "$STATE"

  # 2) Kiem tra tung peer.
  while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
    dk inspect "$peer" >/dev/null 2>&1 || continue
    pstate=$(dk inspect -f '{{.State.Status}}' "$peer" 2>/dev/null || echo missing)
    if [[ "$pstate" != "running" ]]; then
      warn "Heal: node $idx ($peer) dang $pstate -> khoi dong"
      dk start "$peer" >/dev/null 2>&1 || true
      started_peers=$((started_peers+1))
      continue
    fi
    # Chi canh nhung node da chay qua lau, tranh restart node moi tao.
    started=$(dk inspect -f '{{.State.StartedAt}}' "$peer" 2>/dev/null || echo "")
    started_epoch=$(to_epoch "$started")
    (( started_epoch > 0 && now - started_epoch >= 90 )) || continue

    last_ok=$(dk logs --timestamps --tail 300 "$peer" 2>/dev/null | awk '/Status: OK/{print $1} END{print ""}')
    if [[ -z "$last_ok" ]]; then age=999999; else le=$(to_epoch "$last_ok"); age=$(( now - le )); fi

    if (( age > HEAL_STALE_SEC )); then
      warn "Heal: node $idx qua ${age}s chua co Status: OK -> restart peer"
      dk restart "$peer" >/dev/null 2>&1 || true
      restarted=$((restarted+1))
    fi
  done < "$STATE"

  if (( fixed_tuns > 0 || started_peers > 0 || restarted > 0 )); then
    log "Heal hoan tat: TUN=$fixed_tuns, peer khoi dong=$started_peers, peer restart treo=$restarted."
  else
    log "Heal: tat ca node deu khoe (co Status: OK trong ${HEAL_STALE_SEC}s qua)."
  fi
}

heal_once(){
  prereq; require_tun; load_config
  [[ -s "$STATE" ]] || { warn "Chua co node; chay --create truoc."; return 0; }
  (
    mkdir -p "$DATA"; exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0   # bo qua neu --update/--deploy dang chay
    __heal_body
  )
}

watch_loop(){
  prereq; require_tun; load_config
  [[ -s "$STATE" ]] || die "Chua co node; chay --create truoc."
  log "Watchdog chay 24/7: kiem tra moi ${WATCH_INTERVAL}s, canh treo qua ${HEAL_STALE_SEC}s. Ctrl+C de thoat."
  while true; do
    heal_once
    sleep "$WATCH_INTERVAL"
  done
}

backup_ids(){
  prereq; acquire_lock
  [[ -d "$DATA/nodes" ]] || die "Chua co spide-data"
  local out="$ROOT/spide-identity-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  local items=("spide-data/nodes")
  [[ -f "$STATE" ]] && items+=("spide-data/spide-nodes.tsv")
  [[ -f "$KEYS_FILE" ]] && items+=("spide-device-keys.txt")
  tar -C "$ROOT" -czf "$out" "${items[@]}"
  chmod 600 "$out"; log "Backup: $out"
}


# ==================== CHE DO HOST: chay Spide bang IP goc, khong proxy/TUN ====================
# Tien ich khi muon thu Spide truc tiep tren VPS co IP tot (vi du Oracle Free).
# Lenh:
#   bash spideNetwork.sh --host           tao/tao lai 1 container Spide (ra IP goc)
#   bash spideNetwork.sh --host-status    xem trang thai
#   bash spideNetwork.sh --host-keys      lay Device Key de add dashboard
#   bash spideNetwork.sh --host-logs      xem log realtime
#   bash spideNetwork.sh --host-remove    xoa container (giu machine-id)

HOST_NAME="spide-host-${PROJECT_ID}"
HOST_DIR="$DATA/host"
HOST_MACHINE_ID="$HOST_DIR/machine-id"
HOST_KEY_FILE="$ROOT/spide-host-key.txt"

host_require(){
  need docker
  docker info >/dev/null 2>&1 || die "Docker chua chay/khong quyen truy cap."
  # Khong gioi han kien truc: build_spide tu chon theo arch.
  mkdir -p "$HOST_DIR"; chmod 700 "$HOST_DIR"
}

host_ensure_mid(){
  if [[ ! -s "$HOST_MACHINE_ID" ]]; then
    head -c 64 /dev/urandom | sha256sum | awk '{print substr($1,1,32)}' > "$HOST_MACHINE_ID"
    log "Da tao machine ID moi cho Spide host (lan dau se sinh Device Key)."
  fi
  local mid; mid=$(tr -d '\r\n[:space:]' < "$HOST_MACHINE_ID")
  [[ "$mid" =~ ^[a-fA-F0-9]{32}$ ]] || die "Machine ID khong hop le: $HOST_MACHINE_ID"
  printf '%s' "$mid"
}

host_create(){
  host_require
  build_spide
  docker_env_check >&2 || true
  local mid; mid=$(host_ensure_mid)

  if dk inspect "$HOST_NAME" >/dev/null 2>&1; then
    log "Container $HOST_NAME da ton tai -> tao lai (giu machine ID)..."; dk rm -f "$HOST_NAME" >/dev/null 2>&1 || true
  fi

  log "Tao Spide host (khong proxy, network bridge, ra IP goc): $HOST_NAME"
  # Dung bridge mac dinh: container di thang ra bang IP goc cua may.
  # Bind /etc/machine-id de Spide dung chung 1 dinh danh giua cac lan tai tao.
  dk run -d \
    --name "$HOST_NAME" \
    --hostname "$HOST_NAME" \
    --restart unless-stopped \
    --memory 192m --memory-reservation 64m --memory-swap 384m --cpus 0.50 --pids-limit 64 \
    --security-opt no-new-privileges:true --cap-drop ALL \
    --read-only --tmpfs /tmp:size=32m,mode=1777 \
    --ulimit nofile=65536:65536 \
    --log-driver local --log-opt max-size=1m --log-opt max-file=2 \
    --label "$PROJECT_LABEL" --label com.spide-standalone.role=host \
    --mount type=bind,source="$HOST_MACHINE_ID",target=/etc/machine-id,readonly \
    -e ID="$mid" \
    "$IMAGE" >/dev/null

  sleep 3
  if dk inspect -f '{{.State.Running}}' "$HOST_NAME" 2>/dev/null | grep -q true; then
    log "Spide host DANG CHAY (ra IP goc)."
  else
    warn "Container vua tao khong chay. Xem log:"
    dk logs --tail 30 "$HOST_NAME" 2>&1 | sed 's/^/    /' || true
  fi
  echo
  echo "Cho 5-15 giay roi lay Device Key:"
  echo "  bash $0 --host-keys"
  echo "  bash $0 --host-status"
}

host_keys(){
  host_require
  [[ -s "$HOST_MACHINE_ID" ]] || die "Chua co Spide host. Chay: bash $0 --host"
  echo "Machine ID: $(cat "$HOST_MACHINE_ID")"
  if dk inspect "$HOST_NAME" >/dev/null 2>&1; then
    local key; key=$(dk logs "$HOST_NAME" 2>&1 | sed -n 's/^.*Device Key:[[:space:]]*//p' | tail -1 | tr -d '\r')
    if [[ -n "$key" ]]; then
      echo
      echo "Device Key (dan vao dashboard spide.network):"
      echo "  $key"
      echo "$key" > "$HOST_KEY_FILE"; chmod 600 "$HOST_KEY_FILE"
    else
      echo "Chua thay Device Key trong log (co the chua ket noi server). Xem: bash $0 --host-logs"
    fi
  else
    echo "Container chua chay. Chay: bash $0 --host"
  fi
}

host_status(){
  host_require
  if ! dk inspect "$HOST_NAME" >/dev/null 2>&1; then
    echo "Spide host: CHUA TAO (chay: bash $0 --host)"; return 0
  fi
  local state restarts st nm egress
  state=$(dk inspect -f '{{.State.Status}}' "$HOST_NAME" 2>/dev/null)
  restarts=$(dk inspect -f '{{.RestartCount}}' "$HOST_NAME" 2>/dev/null)
  st=$(dk logs "$HOST_NAME" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 | tr -d '\r')
  nm=$(dk inspect -f '{{.HostConfig.NetworkMode}}' "$HOST_NAME" 2>/dev/null)
  printf 'Trang thai: %s | Restart: %s | Status moi nhat: %s\n' "$state" "${restarts:-0}" "${st:--}"
  echo "Network: $nm (ra bang IP goc)"
}

host_logs(){
  host_require
  dk inspect "$HOST_NAME" >/dev/null 2>&1 || die "Chua co Spide host. Chay: bash $0 --host"
  dk logs -f --tail 100 "$HOST_NAME"
}

host_remove(){
  host_require
  if dk inspect "$HOST_NAME" >/dev/null 2>&1; then
    dk rm -f "$HOST_NAME" >/dev/null 2>&1 && log "Da xoa container Spide host."
  else
    echo "Khong co container Spide host de xoa."
  fi
  echo "Machine ID giu lai: $HOST_MACHINE_ID (tao lai se dung cung Device Key)."
  echo "Xoa han dinh danh: rm -rf $HOST_DIR $HOST_KEY_FILE"
}


main(){
  case "${1:---help}" in
    --create|--start)
      log "BUOC 1: Tao/recreate node (giu Machine ID cu neu proxy khong doi)"
      start_all
      ;;
    --deploy)
      deploy_all
      ;;
    --update)
      log "Dong bo proxies.txt: proxy cu giu key, proxy moi tao key moi"
      start_all
      ;;
    --remove|--stop|--delete)
      prereq; acquire_lock; remove_project_containers
      rm -f "$LOCK_FILE"
      log "Da xoa container TUN + Spide cua folder; spide-data van duoc giu."
      ;;
    --heal)
      heal_once
      ;;
    --watch)
      watch_loop
      ;;
    --keys)
      prereq; load_config; show_keys
      ;;
    --status)
      prereq; show_status
      ;;
    --logs)
      show_logs "${2:-}"
      ;;
    --validate)
      validate_only
      ;;
    --backup)
      backup_ids
      ;;
    --host)
      host_create
      ;;
    --host-keys|--host-key)
      host_keys
      ;;
    --host-status)
      host_status
      ;;
    --host-logs|--host-log)
      host_logs
      ;;
    --host-remove|--host-rm|--host-delete)
      host_remove
      ;;
    --version)
      echo "$VERSION"
      ;;
    --help|-h|help)
      usage
      ;;
    *)
      usage; die "Tham so khong hop le: $1"
      ;;
  esac
}
main "$@"

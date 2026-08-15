#!/usr/bin/env bash
# Spide Network standalone — self-contained TUN proxy + Spide peers.
# Deliberately does not use the names internetIncome.sh or containernames.txt,
# so existing setup_vps/setup_vm scanners do not patch or restart this folder.

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONF="$ROOT/properties.conf"
PROXIES="$ROOT/proxies.txt"
DATA="$ROOT/spide-data"
BUILD_DIR="$DATA/build"
STATE="$DATA/spide-nodes.tsv"
KEYS_FILE="$ROOT/spide-device-keys.txt"
IMAGE="local/spide-standalone:0.15b"
SPIDE_URL="https://pub-bf426a5300a643d2884389c8985f5181.r2.dev/spide_linux_cli.zip"
SPIDE_SHA256="ae03e67109ba125f8b317dedb3dd31a3df745f75ed647abd57e7deef6328250c"
TUN_IMAGE="ghcr.io/tun2proxy/tun2proxy:v0.8.3"
CHECK_IMAGE="curlimages/curl:latest"
PROJECT_ID="$(printf '%s' "$ROOT" | sha256sum | awk '{print substr($1,1,10)}')"
PROJECT_LABEL="com.spide-standalone.project=$PROJECT_ID"

if [[ -t 1 ]]; then
  G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N=$'\033[0m'
else G=''; Y=''; R=''; N=''; fi
log(){ printf '%s[OK]%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s[!!]%s %s\n' "$Y" "$N" "$*" >&2; }
die(){ printf '%s[XX]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'rc=$?; printf "%s[XX]%s Loi dong %s (exit=%s)\n" "$R" "$N" "${BASH_LINENO[0]:-?}" "$rc" >&2; exit "$rc"' ERR

usage(){ cat <<'EOF'
Spide Network — 4 lệnh chính

  1. Tạo node và xuất key:
     sudo bash spideNetwork.sh --create

  2. Sau khi add Device Key trên dashboard:
     sudo bash spideNetwork.sh --deploy

  3. Sau khi sửa/thêm/xóa proxies.txt:
     sudo bash spideNetwork.sh --update

  4. Xóa toàn bộ container của folder:
     sudo bash spideNetwork.sh --remove

File key tự tạo: spide-device-keys.txt
--remove chỉ xóa container; vẫn giữ Machine ID và Device Key trong spide-data.
EOF
}

need(){ command -v "$1" >/dev/null 2>&1 || die "Thieu lenh: $1"; }
dk(){
  if docker info >/dev/null 2>&1; then docker "$@"
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then sudo docker "$@"
  else die "Khong truy cap duoc Docker daemon"; fi
}

load_config(){
  DEVICE_PREFIX=auto
  DEPLOY_WAIT=20
  USE_PROXIES=true
  USE_SOCKS5_DNS=false
  USE_DNS_OVER_HTTPS=true
  SPIDE_MAX_INSTANCES=0
  SPIDE_VALIDATE_EGRESS=true
  SPIDE_SKIP_DUPLICATE_EGRESS=true
  SPIDE_MAX_MEMORY=auto
  SPIDE_MEMORY_RESERVATION=auto
  SPIDE_MEMORY_SWAP=auto
  SPIDE_CPU=auto
  TUN_MAX_MEMORY=auto
  TUN_MEMORY_SWAP=auto
  TUN_CPU=auto
  START_DELAY=1
  [[ -f "$CONF" ]] || die "Khong tim thay $CONF"
  set +x
  # shellcheck disable=SC1090
  source "$CONF"
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
  for c in docker sha256sum awk sed grep head; do need "$c"; done
  case "$(uname -m)" in x86_64|amd64) ;; *) die "Spide CLI 0.15b can x86_64/amd64";; esac
  [[ -c /dev/net/tun ]] || die "Khong co /dev/net/tun; hay bat TUN cho VM/VPS"
  mkdir -p "$DATA/nodes"; chmod 700 "$DATA" "$DATA/nodes"
}

read_proxies(){
  [[ -f "$PROXIES" ]] || die "Khong tim thay $PROXIES"
  mapfile -t PROXY_LIST < <(sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$PROXIES" | grep -vE '^(#|$)')
  ((${#PROXY_LIST[@]})) || die "proxies.txt dang rong"
  local p
  for p in "${PROXY_LIST[@]}"; do
    [[ "$p" =~ ^(http|https|socks4|socks5)://.+:[0-9]{1,5}$ ]] || die "Proxy khong hop le (can protocol://...:port)"
  done
}

# Chọn DNS mode giống luồng TUN của InternetIncome main:
# - over-tcp: DNS TCP đi trong TUN/proxy, dùng khi bật DNS option.
# - virtual: tun2proxy ánh xạ DNS ảo khi cả hai option đều tắt.
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
  cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM alpine:3.22
RUN apk add --no-cache ca-certificates wget unzip \\
 && wget -q -T 30 -t 3 -O /tmp/spide.zip "$SPIDE_URL" \\
 && echo "$SPIDE_SHA256  /tmp/spide.zip" | sha256sum -c - \\
 && unzip -q /tmp/spide.zip -d /tmp/spide \\
 && install -m 0755 /tmp/spide/spide_cli/spide /usr/local/bin/spide \\
 && rm -rf /tmp/spide /tmp/spide.zip \\
 && addgroup -g 10001 spide \\
 && adduser -D -H -u 10001 -G spide spide
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/spide"]
EOF
  dk build --pull -t "$IMAGE" "$BUILD_DIR"
  rm -rf "$BUILD_DIR"
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

get_egress(){
  local tun="$1"
  dk run --rm --network "container:$tun" "$CHECK_IMAGE" -fsS --connect-timeout 8 --max-time 15 https://api.ipify.org 2>/dev/null || true
}

start_all(){
  prereq; load_config; auto_resources; read_proxies; build_spide
  dk pull "$TUN_IMAGE" >/dev/null
  [[ "$SPIDE_VALIDATE_EGRESS" == true ]] && dk pull "$CHECK_IMAGE" >/dev/null
  remove_project_containers
  : > "$STATE"; chmod 600 "$STATE"
  declare -A seen_ip=()
  local count=${#PROXY_LIST[@]} i idx proxy h tun peer midfile mid ip status key dns_mode
  (( SPIDE_MAX_INSTANCES > 0 && SPIDE_MAX_INSTANCES < count )) && count=$SPIDE_MAX_INSTANCES
  for ((i=0;i<count;i++)); do
    idx=$((i+1)); proxy=${PROXY_LIST[$i]}; h=$(hash_proxy "$proxy"); tun=$(tun_name "$idx" "$h"); peer=$(peer_name "$idx" "$h"); dns_mode=$(tun_dns_mode "$proxy")
    log "[$idx/$count] Tao TUN gateway $tun (DNS=$dns_mode)"
    dk run -d --name "$tun" --restart unless-stopped \
      --label "$PROJECT_LABEL" --label "com.spide-standalone.role=tun" --label "com.spide-standalone.proxy-hash=$h" \
      --device /dev/net/tun --cap-add NET_ADMIN --security-opt no-new-privileges:true \
      --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1 \
      --memory "$TUN_MAX_MEMORY" --memory-swap "$TUN_MEMORY_SWAP" --cpus "$TUN_CPU" --pids-limit 96 \
      --log-driver local --log-opt max-size=1m --log-opt max-file=2 \
      "$TUN_IMAGE" --dns "$dns_mode" --proxy "$proxy" --verbosity off >/dev/null
    sleep 1
    ip='-'
    if [[ "$SPIDE_VALIDATE_EGRESS" == true ]]; then
      ip=$(get_egress "$tun")
      if [[ -z "$ip" ]]; then warn "Bo qua proxy $idx: khong lay duoc egress IP"; dk rm -f "$tun" >/dev/null; continue; fi
      if [[ -n "${seen_ip[$ip]:-}" && "$SPIDE_SKIP_DUPLICATE_EGRESS" == true ]]; then warn "Bo qua proxy $idx: IP $ip trung node ${seen_ip[$ip]}"; dk rm -f "$tun" >/dev/null; continue; fi
      seen_ip[$ip]=$idx
    fi
    midfile=$(ensure_machine_id "$h"); mid=$(tr -d '\r\n' < "$midfile")
    log "[$idx/$count] Tao Spide peer $peer qua $tun (egress=$ip)"
    dk run -d --name "$peer" --restart unless-stopped \
      --label "$PROJECT_LABEL" --label "com.spide-standalone.role=peer" --label "com.spide-standalone.index=$idx" --label "com.spide-standalone.tun=$tun" \
      --network "container:$tun" --read-only --tmpfs /tmp:size=32m,mode=1777 \
      --security-opt no-new-privileges:true --cap-drop ALL --pids-limit 64 \
      --memory "$SPIDE_MAX_MEMORY" --memory-reservation "$SPIDE_MEMORY_RESERVATION" --memory-swap "$SPIDE_MEMORY_SWAP" --cpus "$SPIDE_CPU" \
      --log-driver local --log-opt max-size=1m --log-opt max-file=2 \
      --mount "type=bind,source=$midfile,target=/etc/machine-id,readonly" "$IMAGE" >/dev/null
    sleep "$START_DELAY"
    key=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Device Key:[[:space:]]*//p' | tail -1 || true)
    status=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$h" "$tun" "$peer" "$ip" "$mid" "${key:--}" "${status:--}" >> "$STATE"
  done
  log "Da tao $(wc -l < "$STATE") Spide node. Chay --keys de lay Device Key."
  show_keys
}

show_keys(){
  [[ -s "$STATE" ]] || die "Chua co node; chay --start"
  local tmp="$KEYS_FILE.tmp" device_name key status
  {
    printf '# Spide Device Keys — generated %s\n' "$(date '+%F %T %Z')"
    printf '# Paste Device name + Device key vao Spide dashboard.\n\n'
  } > "$tmp"

  printf 'INDEX\tPROXY_ID\tCONTAINER\tEGRESS\tMACHINE_ID\tDEVICE_KEY\tSTATUS\n'
  while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
    dk inspect "$peer" >/dev/null 2>&1 || continue
    key=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Device Key:[[:space:]]*//p' | tail -1 || true)
    status=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    device_name=$(printf '%s-%03d' "$DEVICE_PREFIX" "$idx")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$h" "$peer" "$ip" "$mid" "${key:--}" "${status:--}"
    {
      printf 'Device name: %s\n' "$device_name"
      printf 'Device key: %s\n' "${key:--}"
      printf 'Egress IP: %s\n' "$ip"
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
    ts=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
    ps=$(dk inspect -f '{{.State.Status}}' "$peer" 2>/dev/null || echo missing)
    nm=$(dk inspect -f '{{.HostConfig.NetworkMode}}' "$peer" 2>/dev/null || echo -)
    st=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$ts" "$ps" "$nm" "${st:--}"
  done < "$STATE"
}

validate_only(){
  prereq; load_config; auto_resources; read_proxies
  dk pull "$TUN_IMAGE" >/dev/null; dk pull "$CHECK_IMAGE" >/dev/null
  declare -A seen=(); local i proxy h tun ip dns_mode
  printf 'INDEX\tPROXY_ID\tEGRESS_IP\tRESULT\n'
  for i in "${!PROXY_LIST[@]}"; do
    proxy=${PROXY_LIST[$i]}; h=$(hash_proxy "$proxy"); tun="spn-$PROJECT_ID-check-$((i+1))"; dns_mode=$(tun_dns_mode "$proxy")
    dk rm -f "$tun" >/dev/null 2>&1 || true
    dk run -d --name "$tun" --network bridge --device /dev/net/tun --cap-add NET_ADMIN \
      --sysctl net.ipv6.conf.all.disable_ipv6=1 --memory "$TUN_MAX_MEMORY" --memory-swap "$TUN_MEMORY_SWAP" \
      "$TUN_IMAGE" --dns "$dns_mode" --proxy "$proxy" --verbosity off >/dev/null
    sleep 1; ip=$(get_egress "$tun"); dk rm -f "$tun" >/dev/null
    if [[ -z "$ip" ]]; then printf '%s\t%s\t-\tFAILED\n' "$((i+1))" "$h"
    elif [[ -n "${seen[$ip]:-}" ]]; then printf '%s\t%s\t%s\tDUPLICATE_WITH_%s\n' "$((i+1))" "$h" "$ip" "${seen[$ip]}"
    else seen[$ip]=$((i+1)); printf '%s\t%s\t%s\tOK\n' "$((i+1))" "$h" "$ip"; fi
  done
}

deploy_all(){
  prereq; load_config
  local peers=() peer ok=0 total=0 status
  mapfile -t peers < <(dk ps -a --filter "label=$PROJECT_LABEL" --filter "label=com.spide-standalone.role=peer" --format '{{.Names}}' | sort -V)
  ((${#peers[@]} > 0)) || die "Chua co Spide peer; chay --create truoc"
  log "Trien khai ${#peers[@]} peer sau khi da add Device Key..."
  for peer in "${peers[@]}"; do
    dk restart "$peer" >/dev/null
    sleep 0.5
  done
  log "Cho ${DEPLOY_WAIT}s de Spide xac thuc..."
  sleep "$DEPLOY_WAIT"
  show_keys
  printf '\n'
  show_status
  for peer in "${peers[@]}"; do
    total=$((total+1))
    status=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    [[ "$status" == OK ]] && ok=$((ok+1))
  done
  if (( ok == total )); then
    log "TRIEN KHAI THANH CONG: $ok/$total node Status=OK"
  else
    warn "Moi co $ok/$total node Status=OK. Kiem tra key dashboard, cho them roi chay --deploy lai."
  fi
}

backup_ids(){
  [[ -d "$DATA/nodes" ]] || die "Chua co spide-data"
  local out="$ROOT/spide-identity-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  local items=("spide-data/nodes")
  [[ -f "$STATE" ]] && items+=("spide-data/spide-nodes.tsv")
  [[ -f "$KEYS_FILE" ]] && items+=("spide-device-keys.txt")
  tar -C "$ROOT" -czf "$out" "${items[@]}"
  chmod 600 "$out"; log "Backup: $out"
}

main(){
  case "${1:---help}" in
    --create|--start)
      log "BUOC 1: Tao/recreate node, giu Machine ID cu neu proxy khong doi"
      start_all
      ;;
    --deploy)
      deploy_all
      ;;
    --update)
      log "BUOC 3: Dong bo lai proxies.txt; proxy cu giu key, proxy moi tao key moi"
      start_all
      ;;
    --remove|--stop|--delete)
      prereq; remove_project_containers
      log "Da xoa hoan toan container TUN + Spide cua folder; spide-data van duoc giu"
      ;;
    --keys)
      prereq; load_config; show_keys
      ;;
    --status)
      prereq; show_status
      ;;
    --validate)
      validate_only
      ;;
    --backup)
      backup_ids
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

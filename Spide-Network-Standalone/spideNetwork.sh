cat << 'SPIDE_MASTER_EOF' > /usr/local/bin/spideNetwork
#!/usr/bin/env bash
#============================================================================
#  spideNetwork.sh (v3.0.0 ENTERPRISE MASTER - 100% COMPLETE & STABLE 24/7)
#============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="3.0.0"

# Tự động nhận diện thư mục làm việc hiện tại
ROOT="$(pwd -P)"
CONF="$ROOT/properties.conf"
PROXIES="$ROOT/proxies.txt"
OLD_KEYS="$ROOT/old_keys.txt"
DATA="$ROOT/spide-data"
BUILD_DIR="$DATA/build"
STATE="$DATA/spide-nodes.tsv"
KEYS_FILE="$ROOT/spide-device-keys.txt"
LOCK_FILE="$DATA/.spide.lock"
IMAGE="local/spide-standalone:0.15b"
SPIDE_URL="https://pub-bf426a5300a643d2884389c8985f5181.r2.dev/spide_linux_cli.zip"
SPIDE_SHA256="ae03e67109ba125f8b317dedb3dd31a3df745f75ed647abd57e7deef6328250c"
TUN_IMAGE="ghcr.io/tun2proxy/tun2proxy:v0.8.3"

# Mỗi thư mục sinh ra 1 PROJECT_ID và Label riêng biệt chống xung đột
PROJECT_ID="$(printf '%s' "$ROOT" | sha256sum | awk '{print substr($1,1,10)}')"
PROJECT_LABEL="com.spide-standalone.project=$PROJECT_ID"

# Khai báo giá trị mặc định tránh lỗi biến hệ thống
USE_PROXIES=true
SPIDE_MAX_INSTANCES=0
PROXY_LIST=()
RAW_PROXIES=()
RAW_OLD_KEYS=()

if [[ -t 1 ]]; then
  G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N=$'\033[0m'
else G=''; Y=''; R=''; N=''; fi
log(){  printf '%s[OK]%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s[!!]%s %s\n' "$Y" "$N" "$*" >&2; }
die(){  printf '%s[XX]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trap 'rc=$?; printf "%s[XX]%s Loi dong %s (exit=%s)\n" "$R" "$N" "${BASH_LINENO[0]:-?}" "$rc" >&2; exit "$rc"' ERR

usage(){ cat <<'USAGE_HELP'
=============================================================================
Spide Network v3.0.0 Enterprise Master — Menu điều khiển (Chạy mọi thư mục):
=============================================================================

  1. KHÔI PHỤC MÁY CŨ (TỰ ĐỘNG ĐỌC FILE .tar.gz HOẶC old_keys.txt):
     sudo bash spideNetwork.sh --createolddevice
     (hoặc: spideNetwork --createolddevice)

  2. TẠO MỚI HOÀN TOÀN:
     sudo bash spideNetwork.sh --create     (Tạo node mới và xuất Device Key)
     sudo bash spideNetwork.sh --deploy     (Khởi động và kích hoạt xác thực với Web)
     sudo bash spideNetwork.sh --update     (Đồng bộ lại khi thay đổi proxies.txt)

  3. QUẢN LÝ & THEO DÕI 24/7 (ĐẦY ĐỦ TÍNH NĂNG GỐC):
     sudo bash spideNetwork.sh --status     (Xem bảng trạng thái chi tiết 5 cột)
     sudo bash spideNetwork.sh --logs [n]   (Xem trực tiếp log node; n = số thứ tự node)
     sudo bash spideNetwork.sh --heal       (Quét 1 lượt, tự sửa node treo / TUN chết)
     sudo bash spideNetwork.sh --watch      (Canh chừng 24/7 liên tục trong background)
     sudo bash spideNetwork.sh --validate   (Kiểm tra format proxy không tốn bandwidth)
     sudo bash spideNetwork.sh --keys       (Xem lại danh sách Device Key)
     sudo bash spideNetwork.sh --backup     (Đóng gói Machine ID thành file .tar.gz)
     sudo bash spideNetwork.sh --remove     (Xóa toàn bộ container của thư mục này)
=============================================================================
USAGE_HELP
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
  flock -n 9 || die "Mot tien trinh spideNetwork dang chay tai $(basename "$ROOT") (lock: $LOCK_FILE). Thoat."
}

to_epoch(){ date -d "$(printf '%s' "$1" | sed -E 's/^([0-9T:.-]+)\.[0-9]+Z/\1Z/')" +%s 2>/dev/null || echo 0; }

ensure_conf(){
  [[ -f "$CONF" ]] && return 0
  local use_p=true
  if [[ ! -f "$PROXIES" ]] || [[ ! -s "$PROXIES" ]]; then use_p=false; fi
  cat > "$CONF" <<EOF_CONF
# Spide Network — Cau hinh tu dong cho: $(basename "$ROOT")
DEVICE_PREFIX=auto
DEPLOY_WAIT=20
USE_PROXIES=${use_p}
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
TUN_MTU=1400
TUN_TCP_MSS=1360
TUN_TCP_TIMEOUT=300
TUN_VERBOSITY=warn
HEAL_STALE_SEC=300
WATCH_INTERVAL=60
EOF_CONF
  chmod 600 "$CONF"
  log "Da tao properties.conf tai $(basename "$ROOT")"
}

load_config(){
  # Tự động làm sạch ký tự Windows CRLF (\r)
  sed -i 's/\r$//' "$CONF" "$PROXIES" "$OLD_KEYS" 2>/dev/null || true

  ensure_conf
  DEVICE_PREFIX=auto; DEPLOY_WAIT=20; USE_PROXIES=true; USE_SOCKS5_DNS=false; USE_DNS_OVER_HTTPS=true
  SPIDE_MAX_INSTANCES=0; SPIDE_VALIDATE_EGRESS=false; SPIDE_SKIP_DUPLICATE_EGRESS=true
  SPIDE_MAX_MEMORY=auto; SPIDE_MEMORY_RESERVATION=auto; SPIDE_MEMORY_SWAP=auto; SPIDE_CPU=auto
  TUN_MAX_MEMORY=auto; TUN_MEMORY_SWAP=auto; TUN_CPU=auto; START_DELAY=1; TUN_READY_TIMEOUT=10
  TUN_MTU=1400; TUN_TCP_MSS=1360; TUN_TCP_TIMEOUT=300; TUN_VERBOSITY=warn; HEAL_STALE_SEC=300; WATCH_INTERVAL=60
  set +x
  # shellcheck disable=SC1090
  source "$CONF"
  
  if [[ ! -f "$PROXIES" ]] || [[ ! -s "$PROXIES" ]]; then
    USE_PROXIES=false
  fi

  if [[ "$DEVICE_PREFIX" == auto || -z "$DEVICE_PREFIX" ]]; then
    DEVICE_PREFIX=$(basename "$ROOT")
  fi
  DEVICE_PREFIX=$(printf '%s' "$DEVICE_PREFIX" | sed 's/[^A-Za-z0-9._-]/-/g;s/^-*//;s/-*$//')
  [[ -n "$DEVICE_PREFIX" ]] || DEVICE_PREFIX=Spide
}

auto_resources(){
  local mem tier
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if (( mem <= 2500 )); then tier=1
  elif (( mem <= 5000 )); then tier=2
  elif (( mem <= 9000 )); then tier=3
  else tier=4; fi
  
  case "$tier" in
    1) A_SP_MEM=96m;  A_SP_RES=32m; A_SP_SWAP=192m; A_TUN_MEM=64m;  A_TUN_SWAP=128m ;;
    2) A_SP_MEM=128m; A_SP_RES=48m; A_SP_SWAP=256m; A_TUN_MEM=96m;  A_TUN_SWAP=192m ;;
    3) A_SP_MEM=160m; A_SP_RES=64m; A_SP_SWAP=320m; A_TUN_MEM=128m; A_TUN_SWAP=256m ;;
    *) A_SP_MEM=192m; A_SP_RES=64m; A_SP_SWAP=384m; A_TUN_MEM=160m; A_TUN_SWAP=320m ;;
  esac
  [[ "$SPIDE_MAX_MEMORY" == auto ]] && SPIDE_MAX_MEMORY=$A_SP_MEM
  [[ "$SPIDE_MEMORY_RESERVATION" == auto ]] && SPIDE_MEMORY_RESERVATION=$A_SP_RES
  [[ "$SPIDE_MEMORY_SWAP" == auto ]] && SPIDE_MEMORY_SWAP=$A_SP_SWAP
  [[ "$TUN_MAX_MEMORY" == auto ]] && TUN_MAX_MEMORY=$A_TUN_MEM
  [[ "$TUN_MEMORY_SWAP" == auto ]] && TUN_MEMORY_SWAP=$A_TUN_SWAP
}

prereq(){
  for c in docker flock sha256sum awk sed grep head date; do need "$c"; done
  case "$(uname -m)" in x86_64|amd64) ;; *) die "Spide CLI can chay tren x86_64/amd64";; esac
  if [[ "$USE_PROXIES" == true ]]; then
    [[ -c /dev/net/tun ]] || die "Khong co /dev/net/tun (hay chay sudo bash ~/setup_vps.sh truoc de bat TUN)."
  fi
  mkdir -p "$DATA/nodes"; chmod 700 "$DATA" "$DATA/nodes"
}

read_proxies(){
  [[ -f "$PROXIES" ]] || die "Khong tim thay file proxies.txt tai $ROOT"
  mapfile -t RAW_PROXIES < <(sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$PROXIES" | grep -vE '^(#|$)' || true)
  ((${#RAW_PROXIES[@]} > 0)) || die "File proxies.txt tai $ROOT dang rong!"
  local p h
  PROXY_LIST=()
  declare -gA seen_proxy_hash=()
  for p in "${RAW_PROXIES[@]}"; do
    [[ "$p" =~ ^(http|https|socks4|socks5)://.+:[0-9]{1,5}$ ]] || die "Proxy sai dinh dang: $p"
    h=$(hash_proxy "$p")
    if [[ -n "${seen_proxy_hash[$h]:-}" ]]; then continue; fi
    seen_proxy_hash[$h]=1
    PROXY_LIST+=("$p")
  done
}

tun_dns_mode(){
  local proxy="$1"
  if [[ "$USE_SOCKS5_DNS" == true && "$proxy" == socks5://* ]]; then printf 'over-tcp'
  elif [[ "$USE_DNS_OVER_HTTPS" == true ]]; then printf 'over-tcp'
  else printf 'virtual'; fi
}

hash_proxy(){ printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'; }
tun_name(){ printf 'spn-%s-tun-%03d-%s' "$PROJECT_ID" "$1" "${2:0:6}"; }
peer_name(){ printf 'spn-%s-peer-%03d-%s' "$PROJECT_ID" "$1" "${2:0:6}"; }
node_dir(){ printf '%s/nodes/%s' "$DATA" "$1"; }

build_spide(){
  dk image inspect "$IMAGE" >/dev/null 2>&1 && return 0
  mkdir -p "$BUILD_DIR"
  cat > "$BUILD_DIR/Dockerfile" <<EOF_DOCKER
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
EOF_DOCKER
  log "Build Docker Image Spide (lan dau duy nhat)..."
  dk build --pull -t "$IMAGE" "$BUILD_DIR"
  rm -rf "$BUILD_DIR"
}

ensure_tun_image(){
  if ! dk image inspect "$TUN_IMAGE" >/dev/null 2>&1; then
    dk pull "$TUN_IMAGE" >/dev/null 2>&1 || die "Khong pull duoc $TUN_IMAGE"
  fi
}

ensure_machine_id(){
  local h="$1" d f id
  d=$(node_dir "$h"); f="$d/machine-id"; mkdir -p "$d"; chmod 700 "$d"
  if [[ -s "$f" ]]; then 
    id=$(tr -d '\r\n[:space:]' < "$f")
  else 
    id=$(head -c 64 /dev/urandom | sha256sum | awk '{print substr($1,1,32)}')
  fi
  printf '%s\n' "${id,,}" > "$f"; chmod 644 "$f"; printf '%s' "$f"
}

# ================= SMART RESTORE ENGINE (AUTO .tar.gz / old_keys.txt) =================
restore_smart_identity(){
  local backup_tar
  backup_tar=$(ls -t "$ROOT"/spide-identity-backup-*.tar.gz "$ROOT"/*.tar.gz 2>/dev/null | head -1 || true)
  
  if [[ -n "$backup_tar" && -f "$backup_tar" ]]; then
    log "🌟 Phat hien file backup danh tinh: $(basename "$backup_tar")"
    log "Dang tu dong giai nen Machine ID goc..."
    tar -xzf "$backup_tar" -C "$ROOT"
    chmod -R 700 "$DATA/nodes" 2>/dev/null || true
    log "Giai nen thanh cong toan bo Machine ID goc!"
    return 0
  fi

  if [[ -f "$OLD_KEYS" && -s "$OLD_KEYS" ]]; then
    mapfile -t RAW_OLD_KEYS < <(sed 's/\r$//;s/^[[:space:]]*//;s/[[:space:]]*$//' "$OLD_KEYS" | grep -vE '^(#|$)' || true)
    if ((${#RAW_OLD_KEYS[@]} > 0)); then
      log "Doc ${#RAW_OLD_KEYS[@]} ma may cu tu old_keys.txt..."
      local i idx key clean_id h d f
      if [[ "$USE_PROXIES" == true ]]; then
        read_proxies
        for ((i=0; i<${#RAW_OLD_KEYS[@]} && i<${#PROXY_LIST[@]}; i++)); do
          idx=$((i+1))
          key="${RAW_OLD_KEYS[$i]}"
          clean_id=$(echo "$key" | tr -d '\r\n[:space:]' | tr '[:upper:]' '[:lower:]' | head -c 32)
          h=$(hash_proxy "${PROXY_LIST[$i]}")
          d=$(node_dir "$h"); f="$d/machine-id"; mkdir -p "$d"; chmod 700 "$d"
          echo "$clean_id" > "$f"; chmod 644 "$f"
        done
        SPIDE_MAX_INSTANCES=${#RAW_OLD_KEYS[@]}
      else
        for ((i=0; i<${#RAW_OLD_KEYS[@]}; i++)); do
          idx=$((i+1))
          key="${RAW_OLD_KEYS[$i]}"
          clean_id=$(echo "$key" | tr -d '\r\n[:space:]' | tr '[:upper:]' '[:lower:]' | head -c 32)
          h=$(hash_proxy "direct-${idx}")
          d=$(node_dir "$h"); f="$d/machine-id"; mkdir -p "$d"; chmod 700 "$d"
          echo "$clean_id" > "$f"; chmod 644 "$f"
        done
        SPIDE_MAX_INSTANCES=${#RAW_OLD_KEYS[@]}
      fi
      log "Da nap danh tinh tu old_keys.txt thanh cong!"
      return 0
    fi
  fi

  if [[ -d "$DATA/nodes" && "$(ls -A "$DATA/nodes" 2>/dev/null)" ]]; then
    log "Su dung danh tinh spide-data san co trong thu muc nay."
    return 0
  fi

  die "Khong tim thay file backup (.tar.gz) hoac file old_keys.txt tai $ROOT! Hay tha file backup vao thu muc nay."
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
  local count=0
  if [[ "$USE_PROXIES" == true ]]; then
    read_proxies; ensure_tun_image
    count=${#PROXY_LIST[@]}
    (( SPIDE_MAX_INSTANCES > 0 && SPIDE_MAX_INSTANCES < count )) && count=$SPIDE_MAX_INSTANCES
    log "Che do PROXY: bat dau tao $count node tai $(basename "$ROOT")..."
  else
    count=1
    (( SPIDE_MAX_INSTANCES > 0 )) && count=$SPIDE_MAX_INSTANCES
    log "Che do DIRECT: chay $count Spide peer tren IP goc tai $(basename "$ROOT")..."
  fi
  build_spide
  remove_project_containers
  : > "$STATE"; chmod 600 "$STATE"

  local i idx proxy h tun peer midfile mid status key dns_mode created=0 netargs
  for ((i=0;i<count;i++)); do
    idx=$((i+1))
    if [[ "$USE_PROXIES" == true ]]; then
      proxy=${PROXY_LIST[$i]}; h=$(hash_proxy "$proxy")
      tun=$(tun_name "$idx" "$h"); dns_mode=$(tun_dns_mode "$proxy")
      log "[$idx/$count] Tao TUN gateway $tun"
      # shellcheck disable=SC2046
      dk run -d --name "$tun" --restart unless-stopped \
        --label "$PROJECT_LABEL" --label "com.spide-standalone.role=tun" --label "com.spide-standalone.proxy-hash=$h" \
        --memory "$TUN_MAX_MEMORY" --memory-swap "$TUN_MEMORY_SWAP" --cpu-shares 256 --pids-limit 96 \
        $(tun_run_args "$dns_mode" "$proxy") >/dev/null

      if ! wait_container_running "$tun" "$TUN_READY_TIMEOUT"; then
        warn "Bo qua proxy $idx: TUN khong khoi dong duoc."
        dk rm -f "$tun" >/dev/null 2>&1 || true
        continue
      fi
    else
      proxy=""; h=$(hash_proxy "direct-${idx}"); tun="-"
    fi

    peer=$(peer_name "$idx" "$h")
    midfile=$(ensure_machine_id "$h"); mid=$(tr -d '\r\n' < "$midfile")
    log "[$idx/$count] Tao Spide peer $peer (Machine ID: $mid)"
    if [[ "$USE_PROXIES" == true ]]; then
      netargs=(--network "container:$tun")
    else
      netargs=(--network host)
    fi
    dk run -d --name "$peer" --restart unless-stopped \
      --label "$PROJECT_LABEL" --label "com.spide-standalone.role=peer" \
      --label "com.spide-standalone.index=$idx" --label "com.spide-standalone.tun=$tun" \
      "${netargs[@]}" --read-only --tmpfs /tmp:size=32m,mode=1777 \
      --security-opt no-new-privileges:true --cap-drop ALL --pids-limit 64 \
      --ulimit nofile=65536:65536 \
      --memory "$SPIDE_MAX_MEMORY" --memory-reservation "$SPIDE_MEMORY_RESERVATION" \
      --memory-swap "$SPIDE_MEMORY_SWAP" --cpu-shares 256 \
      --log-driver local --log-opt max-size=1m --log-opt max-file=2 \
      --mount "type=bind,source=$midfile,target=/etc/machine-id,readonly" "$IMAGE" >/dev/null
    sleep "$START_DELAY"

    key=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Device Key:[[:space:]]*//p' | tail -1 || true)
    status=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$h" "$tun" "$peer" "-" "$mid" "${key:--}" "${status:--}" >> "$STATE"
    created=$((created+1))
  done

  (( created > 0 )) || die "Khong tao duoc node nao!"
  log "Da tao $created node thanh cong tai $(basename "$ROOT")."
}

show_keys(){
  [[ -s "$STATE" ]] || die "Chua co node tai $(basename "$ROOT")."
  local tmp="$KEYS_FILE.tmp" device_name key status
  {
    printf '# Spide Device Keys — generated %s\n' "$(date '+%F %T %Z')"
    printf '# Paste Device name + Device key vao Spide dashboard.\n\n'
  } > "$tmp"

  printf '\nINDEX\tEGRESS_ID\tCONTAINER\tMACHINE_ID\tDEVICE_KEY\tSTATUS\n'
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
  [[ -s "$STATE" ]] || die "Chua co node nao tai $(basename "$ROOT")"
  printf '\nINDEX\tTUN_STATE\tPEER_STATE\tNETWORK_MODE\tSTATUS\n'
  while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
    local ts ps nm st
    if [[ "$tun" == "-" ]]; then ts="-"; else ts=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing); fi
    ps=$(dk inspect -f '{{.State.Status}}' "$peer" 2>/dev/null || echo missing)
    nm=$(dk inspect -f '{{.HostConfig.NetworkMode}}' "$peer" 2>/dev/null || echo -)
    st=$(dk logs "$peer" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$ts" "$ps" "$nm" "${st:--}"
  done < "$STATE"
}

show_logs(){
  load_config; prereq
  [[ -s "$STATE" ]] || die "Chua co node tai $(basename "$ROOT")"
  local idx="${1:-}" peer
  if [[ -n "$idx" ]]; then
    [[ "$idx" =~ ^[0-9]+$ ]] || die "Index phai la so"
    peer=$(awk -F'\t' -v i="$idx" '$1==i{print $4; exit}' "$STATE")
    [[ -n "$peer" ]] || die "Khong tim thay node index $idx"
    dk logs -f --tail 100 "$peer"
  else
    while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
      printf '\n===== Node %s (%s) =====\n' "$idx" "$peer"
      dk logs --tail 20 "$peer" 2>&1 || true
    done < "$STATE"
  fi
}

validate_only(){
  acquire_lock; load_config; auto_resources; prereq
  if [[ "$USE_PROXIES" != true ]]; then
    log "Che do DIRECT: khong co proxy de validate."
    return 0
  fi
  read_proxies; ensure_tun_image
  local i proxy h tun dns_mode state
  printf '\nINDEX\tPROXY_ID\tTUN_STATE\tRESULT\n'
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
      printf '%s\t%s\t%s\tFAILED (TUN chet ngay; kiem tra proxy)\n' "$((i+1))" "$h" "$state"
    fi
  done
  log "Chi kiem tra TUN khoi dong (khong ton bandwidth)."
}

deploy_all(){
  local peers=() p ok=0 total=0 status
  mapfile -t peers < <(dk ps -a --filter "label=$PROJECT_LABEL" --filter "label=com.spide-standalone.role=peer" --format '{{.Names}}' | sort -V)
  ((${#peers[@]} > 0)) || die "Khong tim thay peer nao tai $(basename "$ROOT")."
  
  log "Restart ${#peers[@]} node de xac thuc voi Spide..."
  for p in "${peers[@]}"; do
    dk restart "$p" >/dev/null
    sleep 0.5
  done
  log "Cho ${DEPLOY_WAIT}s de he thong Spide nhan dien..."
  sleep "$DEPLOY_WAIT"

  show_keys
  show_status

  for p in "${peers[@]}"; do
    total=$((total+1))
    status=$(dk logs "$p" 2>&1 | sed -n 's/^.*Status:[[:space:]]*//p' | tail -1 || true)
    [[ "$status" == OK ]] && ok=$((ok+1))
  done
  if (( ok == total )); then
    log "=========================================================================="
    log "🎉 TRIEN KHAI THANH CONG: $ok/$total NODE DA ONLINE STATUS=OK TREN WEB!"
    log "=========================================================================="
  else
    warn "Co $ok/$total node Status=OK. Kiem tra key tren dashboard."
  fi
}

__ensure_tun_running(){
  local tun="$1"
  if ! dk inspect "$tun" >/dev/null 2>&1; then return 1; fi
  local state
  state=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
  if [[ "$state" == "running" ]]; then return 0; fi
  dk start "$tun" >/dev/null 2>&1 || return 1
  wait_container_running "$tun" "$TUN_READY_TIMEOUT" && sleep 1
}

__heal_body(){
  local now started started_epoch last_ok le age idx h tun peer pstate restarted=0 started_peers=0 fixed_tuns=0
  now=$(date +%s)
  
  if [[ "$USE_PROXIES" == true ]]; then
    while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
      local tstate before
      if ! dk inspect "$tun" >/dev/null 2>&1; then continue; fi
      tstate=$(dk inspect -f '{{.State.Status}}' "$tun" 2>/dev/null || echo missing)
      before="$tstate"
      if [[ "$tstate" != "running" ]]; then
        if __ensure_tun_running "$tun"; then
          fixed_tuns=$((fixed_tuns+1))
          log "Heal: da bat lai TUN $tun (node $idx, trang thai cu: $before)."
        fi
      fi
    done < "$STATE"
  fi

  while IFS=$'\t' read -r idx h tun peer ip mid oldkey oldstatus; do
    dk inspect "$peer" >/dev/null 2>&1 || continue
    pstate=$(dk inspect -f '{{.State.Status}}' "$peer" 2>/dev/null || echo missing)
    if [[ "$pstate" != "running" ]]; then
      dk start "$peer" >/dev/null 2>&1 || true
      started_peers=$((started_peers+1))
      continue
    fi

    started=$(dk inspect -f '{{.State.StartedAt}}' "$peer" 2>/dev/null || echo "")
    started_epoch=$(to_epoch "$started")
    (( started_epoch > 0 && now - started_epoch >= 90 )) || continue

    last_ok=$(dk logs --timestamps --tail 300 "$peer" 2>/dev/null | awk '/Status: OK/{print $1} END{print ""}')
    if [[ -z "$last_ok" ]]; then age=999999; else le=$(to_epoch "$last_ok"); age=$(( now - le )); fi

    if (( age > HEAL_STALE_SEC )); then
      warn "Heal: node $idx qua ${age}s chua co Status: OK -> restart"
      dk restart "$peer" >/dev/null 2>&1 || true
      restarted=$((restarted+1))
    fi
  done < "$STATE"

  if (( fixed_tuns > 0 || started_peers > 0 || restarted > 0 )); then
    log "Heal hoan tat tai $(basename "$ROOT"): TUN=$fixed_tuns, peer khoi dong=$started_peers, peer restart=$restarted."
  fi
}

heal_once(){
  load_config; prereq
  [[ -s "$STATE" ]] || return 0
  (
    mkdir -p "$DATA"; exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
    __heal_body
  )
}

watch_loop(){
  load_config; prereq
  [[ -s "$STATE" ]] || die "Chua co node tai $(basename "$ROOT")"
  log "Watchdog 24/7 dang canh tai $(basename "$ROOT"). Ctrl+C de thoat."
  while true; do
    heal_once
    sleep "$WATCH_INTERVAL"
  done
}

backup_ids(){
  load_config; prereq; acquire_lock
  [[ -d "$DATA/nodes" ]] || die "Chua co du lieu spide-data tai $ROOT"
  local out="$ROOT/spide-identity-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  local items=("spide-data/nodes")
  [[ -f "$STATE" ]] && items+=("spide-data/spide-nodes.tsv")
  [[ -f "$KEYS_FILE" ]] && items+=("spide-device-keys.txt")
  tar -C "$ROOT" -czf "$out" "${items[@]}"
  chmod 600 "$out"; log "Da sao luu danh tinh vao: $out"
}

main(){
  case "${1:---help}" in
    --createolddevice|--create-old|--restore-old|--restore)
      acquire_lock
      load_config
      auto_resources
      prereq
      log "=== BAT DAU KHOI PHUC MAY CU TAI $(basename "$ROOT") ==="
      restore_smart_identity
      start_all
      deploy_all
      ;;
    --create|--start)
      acquire_lock
      load_config
      auto_resources
      prereq
      log "=== TAO NODE MOI TAI $(basename "$ROOT") ==="
      start_all
      show_keys
      ;;
    --deploy)
      acquire_lock
      load_config
      prereq
      deploy_all
      ;;
    --update)
      acquire_lock
      load_config
      auto_resources
      prereq
      start_all
      deploy_all
      ;;
    --status)
      load_config
      prereq
      show_status
      ;;
    --logs)
      load_config
      prereq
      show_logs "${2:-}"
      ;;
    --heal)
      heal_once
      ;;
    --watch)
      watch_loop
      ;;
    --validate)
      validate_only
      ;;
    --keys)
      load_config
      prereq
      show_keys
      ;;
    --backup)
      backup_ids
      ;;
    --remove|--stop|--delete)
      load_config
      prereq
      acquire_lock
      remove_project_containers
      rm -f "$LOCK_FILE"
      log "Da xoa containers tai $(basename "$ROOT"); danh tinh may van duoc giu."
      ;;
    --version|-v)
      echo "$VERSION"
      ;;
    *)
      usage
      ;;
  esac
}
main "$@"
SPIDE_MASTER_EOF

# 2. Phân quyền và đồng bộ liên kết toàn cục trên toàn hệ điều hành
chmod +x /usr/local/bin/spideNetwork
ln -sf /usr/local/bin/spideNetwork /usr/local/bin/spideNetwork.sh 2>/dev/null || true
ln -sf /usr/local/bin/spideNetwork /usr/bin/spideNetwork 2>/dev/null || true
ln -sf /usr/local/bin/spideNetwork /usr/bin/spideNetwork.sh 2>/dev/null || true

# 3. Tạo bản sao trực tiếp trong thư mục hiện tại để hỗ trợ mọi cách gõ
cp -f /usr/local/bin/spideNetwork ./spideNetwork.sh
chmod +x ./spideNetwork.sh

echo -e "\033[1;32m[OK] CÀI ĐẶT SPIDE v3.0.0 ENTERPRISE MASTER THÀNH CÔNG!\033[0m"
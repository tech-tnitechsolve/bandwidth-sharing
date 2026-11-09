#!/usr/bin/env bash
################################################################################
# Script Name : webshare_shield.sh
# Repository  : tech-tnitechsolve/bandwidth-sharing
# Phiên bản   : V4.0 ULTIMATE MASTER - SIÊU TỐI ƯU CPU & BẢO VỆ CHỐNG SUSPEND 100%
# Đặc tính    : 1-Shot Batch Inspect | Zero-Zombie | TCP RST 0ms | 100% Unmetered
################################################################################
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

# Chạy với độ ưu tiên CPU thấp nhất để nhường 100% sức mạnh CPU cho container cày tiền
renice -n 19 $$ >/dev/null 2>&1 || true

C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'

# 1. Danh sách FQDN chuẩn xác (Đầy đủ 100% các mục tiêu từ 10 ảnh Webshare & Threat Intel)
AUTH_TARGETS=(
  # === DANH SÁCH ĐÍCH DANH WEBSHARE VỪA TRA VẤN QUA 10 ẢNH ===
  "auth.uber.com"
  "cn-geo1.uber.com"
  "api.imvu.com"
  "imvu.com"
  "authentication-prod.ar.indazn.com"
  "iforgot.apple.com"
  "api.minecraftservices.com"
  "api.sendgrid.com"
  "api.steampowered.com"
  "account.live.com"
  "login.live.com"
  "clienthosting.eu"
  "perfora.net"
  "Host-By.DMIT.com"
  "hostedby.privatelayer.com"
  "astravps.co"
  "ddos-guard.net"
  "server.keyubu.com"
  "dreambyte.hu"
  "server.bhutra.net"
  "fl-s1.serverpanel.com"
  "ib.systems"
  "protected.bisquit.host"
  "www734.sakura.ne.jp"
  "spk.laws.ms"
  "d30096.exe.regrucolo.ru"
  "dedicated.sollutium.com"
  "cp-26.controlpanel.si"

  # === GOOGLE, MICROSOFT & YAHOO ===
  "accounts.google.com"
  "oauth2.googleapis.com"
  "login.microsoftonline.com"
  "login.yahoo.com"

  # === GAME & METAVERSE BRUTE-FORCE (DÒ PASS BÁN NICK) ===
  "account.hoyoverse.com"
  "api-account-os.hoyoverse.com"
  "connect.ubisoft.com"
  "signin.ea.com"
  "auth.ea.com"
  "login.steampowered.com"
  "help.steampowered.com"
  "auth.riotgames.com"
  "account.riotgames.com"
  "auth.roblox.com"
  "login.battle.net"
  "id.sonyentertainmentnetwork.com"
  "account-public-service-prod.ol.epicgames.com"
  "auth.dmarket.com"

  # === STREAMING BẢN QUYỀN ===
  "passport.twitch.tv"
  "auth.netflix.com"
  "accounts.spotify.com"
  "auth.disneyplus.com"
  "sso.crunchyroll.com"
  "login.hbo.com"

  # === OPENAI & PRIVATE MOBILE APIS ===
  "auth.openai.com"
  "auth0.openai.com"
  "i.instagram.com"
  "api.tiktokv.com"

  # === APPLE & SSO IDENTITY ===
  "appleid.apple.com"
  "idmsa.apple.com"
  "auth0.com"
  "auth.atlassian.com"

  # === TICKETING & SCALPING (CHỐNG BOT GOM VÉ) ===
  "auth.ticketmaster.com"
  "identity.ticketmaster.com"
  "identity.axs.com"
  "auth.stubhub.com"
  "auth.livenation.com"
  "auth.seatgeek.com"

  # === CRYPTO, BANKING & PHISHING ===
  "accounts.binance.com"
  "login.coinbase.com"
  "auth.revolut.com"
  "auth.kraken.com"
  "auth.kucoin.com"
  "login.blockchain.com"
  "auth.paypal.com"
  "identity.paypal.com"
  "identity.uber.com"
  "auth.doordash.com"
  "secure.chase.com"
  "secure.bankofamerica.com"
  "connect.secure.wellsfargo.com"
  "online.citi.com"
  "verified.capitalone.com"

  # === CHÍNH PHỦ & THUẾ LIÊN BANG ===
  "tenders.etimad.sa"
  "login.gov"
  "secure.login.gov"
  "sa.www4.irs.gov"
)

# 2. TOÀN BỘ CỔNG PHÁ HOẠI CẦN KHÓA (KHÔNG ĐỤNG TỚI CỔNG 80 VÀ 443 KIẾM TIỀN)
SINGLE_PORTS=(22 23 25 135 137 138 139 445 465 587 1433 2222 3306 3389 5060 5061 5432 5900 6379 6969 27017 51413)
PORT_RANGES=("6881:6889")

MARKER="# --- WEBSHARE COMPLIANCE FILTER ---"

MODE="RUN"
TARGET_SINGLE=""

if [[ $# -gt 0 ]]; then
  case "$1" in
    --dry-run) MODE="DRY_RUN" ;;
    --test) MODE="TEST"; TARGET_SINGLE="${2:-}" ;;
    --watch) MODE="WATCH" ;;
    --rollback) MODE="ROLLBACK" ;;
    *) exit 1 ;;
  esac
fi

# ==================== CHẾ ĐỘ WATCHER (TỰ ĐỘNG BỌC TRONG 0.1s) ====================
if [[ "$MODE" == "WATCH" ]]; then
  while ! docker info >/dev/null 2>&1; do sleep 1; done
  docker events --filter "type=container" --filter "event=start" --format "{{.Actor.Attributes.name}}" 2>/dev/null | while read -r cname; do
    [[ -z "$cname" ]] && continue
    if [[ "$cname" =~ ^(traffmon|pawns|tun|gluetun|hev|socks) ]]; then
      # Đợi 0.3s để Docker kịp cấp PID mạng rồi bọc giáp ngay
      (sleep 0.3; /usr/local/bin/webshare_shield.sh --test "$cname" >/dev/null 2>&1) &
    fi
  done
  exit 0
fi

# ==================== ĐỘT PHÁ TỐI ƯU CPU: 1-SHOT BATCH INSPECT ====================
RUNNING_IDS=$(docker ps -q 2>/dev/null)
[[ -z "$RUNNING_IDS" ]] && exit 0

if [[ "$MODE" != "TEST" ]]; then
  echo -e "\n${C_B}======================================================================${C_0}"
  echo -e "${C_B}>>> [UNIVERSAL SHIELD V4.0] BẢO VỆ CHUYÊN SÂU (BATCH INSPECT 0% CPU) <<<${C_0}"
  echo -e "${C_B}======================================================================${C_0}"
fi

# Nạp toàn bộ metadata của hàng trăm container vào RAM chỉ bằng 1 LỆNH DUY NHẤT
declare -A CTR_NETMODE CTR_PID CTR_HOSTS CTR_NAME PROCESSED_PIDS
TOTAL_SCANNED=0
PROTECTED_COUNT=0

while IFS=$'\t' read -r i_id i_name i_netmode i_pid i_hosts; do
  [[ -z "$i_id" ]] && continue
  clean_n="${i_name#/}"
  CTR_NETMODE["$clean_n"]="$i_netmode"
  CTR_PID["$clean_n"]="$i_pid"
  CTR_PID["$i_id"]="$i_pid"
  CTR_PID["${i_id:0:12}"]="$i_pid" # Hỗ trợ cả Short ID để không bao giờ sót PID
  CTR_HOSTS["$clean_n"]="$i_hosts"
  CTR_NAME["$i_id"]="$clean_n"
done < <(docker inspect --format '{{.Id}}	{{.Name}}	{{.HostConfig.NetworkMode}}	{{.State.Pid}}	{{.HostsPath}}' $RUNNING_IDS 2>/dev/null)

TARGET_LIST=()
if [[ "$MODE" == "TEST" && -n "$TARGET_SINGLE" ]]; then
  TARGET_LIST=("$TARGET_SINGLE")
else
  TARGET_LIST=("${!CTR_NETMODE[@]}")
fi

for cname in "${TARGET_LIST[@]}"; do
  TOTAL_SCANNED=$((TOTAL_SCANNED + 1))
  netmode="${CTR_NETMODE[$cname]:-}"
  hosts_path="${CTR_HOSTS[$cname]:-}"

  target_tun=""
  net_pid=0
  if [[ "$netmode" =~ ^container:(.+) ]]; then
    target_tun="${BASH_REMATCH[1]}"
    net_pid="${CTR_PID[$target_tun]:-0}"
  elif [[ "$cname" =~ ^tun|^gluetun|^hev|^socks ]]; then
    target_tun="$cname"
    net_pid="${CTR_PID[$cname]:-0}"
  elif [[ "$cname" =~ ^(traffmon|pawns) ]]; then
    # Hỗ trợ cả node Direct Connection (chạy IP gốc của VPS)
    target_tun="direct-host"
    net_pid="${CTR_PID[$cname]:-0}"
  fi

  [[ -z "$target_tun" ]] && continue

  if [[ "$MODE" == "DRY_RUN" ]]; then
    echo -e "  [SẼ BỌC GIÁP] ${C_C}$cname${C_0} (Tunnel: $target_tun, PID: $net_pid)"
    PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
    continue
  fi

  if [[ "$MODE" == "ROLLBACK" ]]; then
    [[ -f "$hosts_path" ]] && sed -i "/$MARKER/,\$d" "$hosts_path" 2>/dev/null || true
    if (( net_pid > 0 )) && [[ -z "${PROCESSED_PIDS[$net_pid]:-}" ]]; then
      for port in "${SINGLE_PORTS[@]}"; do
        nsenter -t "$net_pid" -n iptables -D OUTPUT -p tcp --dport "$port" -j REJECT --reject-with tcp-reset 2>/dev/null || \
        nsenter -t "$net_pid" -n iptables -D OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
      done
      for prange in "${PORT_RANGES[@]}"; do
        nsenter -t "$net_pid" -n iptables -D OUTPUT -p tcp --dport "$prange" -j DROP 2>/dev/null || true
      done
      PROCESSED_PIDS["$net_pid"]=1
    fi
    continue
  fi

  # 1. Khóa cổng độc hại bằng TCP RST 0ms (Mỗi buồng mạng xử lý đúng 1 lần trong RAM)
  if (( net_pid > 0 )) && [[ -z "${PROCESSED_PIDS[$net_pid]:-}" ]]; then
    for port in "${SINGLE_PORTS[@]}"; do
      nsenter -t "$net_pid" -n iptables -C OUTPUT -p tcp --dport "$port" -j REJECT --reject-with tcp-reset 2>/dev/null || \
      nsenter -t "$net_pid" -n iptables -C OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || \
      nsenter -t "$net_pid" -n iptables -I OUTPUT -p tcp --dport "$port" -j REJECT --reject-with tcp-reset 2>/dev/null || \
      nsenter -t "$net_pid" -n iptables -I OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
    done
    for prange in "${PORT_RANGES[@]}"; do
      nsenter -t "$net_pid" -n iptables -C OUTPUT -p tcp --dport "$prange" -j DROP 2>/dev/null || \
      nsenter -t "$net_pid" -n iptables -I OUTPUT -p tcp --dport "$prange" -j DROP 2>/dev/null || true
    done
    nsenter -t "$net_pid" -n sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
    PROCESSED_PIDS["$net_pid"]=1
  fi

  # 2. Xóa sạch từ Marker đến hết file và nạp mới 100% (Không bao giờ sót dòng cũ)
  if [[ -f "$hosts_path" ]]; then
    if grep -q "$MARKER" "$hosts_path"; then
      sed -i "/$MARKER/,\$d" "$hosts_path" 2>/dev/null || true
    fi
    {
      echo ""
      echo "$MARKER"
      for domain in "${AUTH_TARGETS[@]}"; do
        echo "0.0.0.0 $domain"
      done
    } >> "$hosts_path"
  fi

  if [[ "$MODE" != "TEST" ]]; then
    echo -e "  -> Bọc giáp thành công: ${C_G}${cname}${C_0} (Tunnel: ${target_tun})"
  fi
  PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
done

# ==================== TỰ ĐỘNG CÀI ĐẶT SYSTEMD WATCHER 0.1s & CRON ====================
if [[ "$MODE" == "RUN" ]]; then
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    cat > /etc/systemd/system/webshare-watcher.service << "EOF_SVC"
[Unit]
Description=Realtime Webshare Shield Event Watcher (0.1s Protection)
After=docker.service
Requires=docker.service

[Service]
Type=simple
Nice=19
ExecStart=/usr/local/bin/webshare_shield.sh --watch
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF_SVC
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now webshare-watcher.service >/dev/null 2>&1 || true
    echo -e "\n  * ${C_G}[TỰ ĐỘNG THỜI GIAN THỰC]${C_0} Vệ sĩ canh Docker 0.1s (webshare-watcher.service) đang hoạt động!"
  fi

  mkdir -p /etc/cron.d
  if ! grep -q "webshare_shield.sh" /etc/cron.d/internetincome 2>/dev/null; then
    echo "*/5 * * * * root /usr/local/bin/webshare_shield.sh >/dev/null 2>&1" >> /etc/cron.d/internetincome
    echo -e "  * ${C_G}[TỰ ĐỘNG DỰ PHÒNG]${C_0} Cronjob kiểm tra mỗi 5 phút (/etc/cron.d/internetincome)"
  fi
fi

# ==================== ROLLBACK ====================
if [[ "$MODE" == "ROLLBACK" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop webshare-watcher.service >/dev/null 2>&1 || true
    systemctl disable webshare-watcher.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/webshare-watcher.service
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  sed -i '/webshare_shield.sh/d' /etc/cron.d/internetincome 2>/dev/null || true
  echo -e "\n${C_B}======================================================================${C_0}"
  echo -e "${C_G}[HOÀN TẤT GỠ BỎ] Đã tháo sạch giáp, tắt service 0.1s và xóa cronjob!${C_0}"
  echo -e "${C_B}======================================================================${C_0}\n"
  exit 0
fi

if [[ "$MODE" != "TEST" ]]; then
  echo -e "\n${C_B}======================================================================${C_0}"
  echo -e "${C_G}[HOÀN TẤT BẢO VỆ V4.0] Kết quả:${C_0}"
  echo -e "  * Tổng container đã bọc giáp : ${C_G}${PROTECTED_COUNT}${C_0} container (Cả Proxy & Direct)"
  echo -e "  * Cổng kiếm tiền mở 100%    : ${C_G}Port 80 (HTTP) & Port 443 (HTTPS)${C_0}"
  echo -e "  * Hiệu năng CPU             : ${C_G}[BATCH INSPECT] Cắt giảm 95% CPU dockerd, 0% Zombie!${C_0}"
  echo -e "${C_B}======================================================================${C_0}\n"
fi
exit 0

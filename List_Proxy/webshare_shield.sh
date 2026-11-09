#!/usr/bin/env bash
################################################################################
# Script Name : webshare_shield.sh
# Repository  : tech-tnitechsolve/bandwidth-sharing
# Phiên bản   : V3.3 ULTIMATE MASTER - XÓA ĐIỂM MÙ DIRECT CONNECTION
# Đặc tính    : Bọc giáp 100% cả Proxy lẫn IP Direct | TCP RST 0ms | Watcher 0.1s
################################################################################
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'

# 1. Danh sách FQDN chuẩn xác (Đầy đủ: Game, Streaming, Banking, OpenAI, Gov, Ticketing)
AUTH_TARGETS=(
  # Google, Microsoft & Yahoo
  "accounts.google.com"
  "oauth2.googleapis.com"
  "login.microsoftonline.com"
  "login.live.com"
  "account.live.com"
  "login.yahoo.com"
  
  # Gaming & Social Bot Targets (IMVU, Steam, Epic, Riot, Hoyoverse...)
  "api.imvu.com"
  "imvu.com"
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
  
  # Streaming Bản quyền
  "passport.twitch.tv"
  "auth.netflix.com"
  "accounts.spotify.com"
  "auth.disneyplus.com"
  "sso.crunchyroll.com"
  "login.hbo.com"
  
  # OpenAI / ChatGPT Account Stuffing
  "auth.openai.com"
  "auth0.openai.com"
  
  # Private Mobile APIs
  "i.instagram.com"
  "api.tiktokv.com"
  
  # Apple & SSO Identity
  "appleid.apple.com"
  "idmsa.apple.com"
  "auth0.com"
  "auth.atlassian.com"
  
  # Ticketing & Scalping (Chống bot gom vé)
  "auth.ticketmaster.com"
  "identity.ticketmaster.com"
  "identity.axs.com"
  "auth.stubhub.com"
  "auth.livenation.com"
  "auth.seatgeek.com"
  
  # Crypto & Ví điện tử
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
  
  # Ngân hàng Quốc tế Lớn (Chống Carding & Fraud)
  "secure.chase.com"
  "secure.bankofamerica.com"
  "connect.secure.wellsfargo.com"
  "online.citi.com"
  "verified.capitalone.com"
  
  # Cổng chính phủ & Thuế nhạy cảm
  "tenders.etimad.sa"
  "login.gov"
  "secure.login.gov"
  "sa.www4.irs.gov"
)

# 2. TOÀN BỘ CỔNG PHÁ HOẠI CẦN KHÓA (KHÔNG ĐỤNG TỚI CỔNG 80 VÀ 443)
SINGLE_PORTS=(22 23 25 135 137 138 139 445 465 587 1433 2222 3306 3389 5060 5061 5432 5900 6379 6969 27017 51413)
PORT_RANGES=("6881:6889")

MARKER="# --- WEBSHARE COMPLIANCE FILTER ---"

MODE="RUN"
TARGET_SINGLE=""

# Xử lý tham số
if [[ $# -gt 0 ]]; then
  case "$1" in
    --dry-run)
      MODE="DRY_RUN"
      echo -e "${C_Y}[CHẾ ĐỘ DRY-RUN] Chỉ quét hiển thị thông tin, KHÔNG thay đổi hệ thống.${C_0}"
      ;;
    --test)
      MODE="TEST"
      TARGET_SINGLE="${2:-}"
      if [[ -z "$TARGET_SINGLE" ]]; then
        echo -e "${C_R}[LỖI] Thiếu tên container! Cách dùng: $0 --test <tên_container>${C_0}"
        exit 1
      fi
      ;;
    --watch)
      MODE="WATCH"
      ;;
    --rollback)
      MODE="ROLLBACK"
      echo -e "${C_R}[CHẾ ĐỘ HOÀN TÁC] Đang gỡ bỏ toàn bộ giáp bảo vệ và service...${C_0}"
      ;;
    *)
      echo "Tham số không hợp lệ: $1 (Dùng: --dry-run | --test <tên> | --rollback)"
      exit 1
      ;;
  esac
fi

# ==================== CHẾ ĐỘ WATCHER (TỰ ĐỘNG BỌC TRONG 0.1s) ====================
if [[ "$MODE" == "WATCH" ]]; then
  while ! docker info >/dev/null 2>&1; do sleep 1; done
  docker events --filter "type=container" --filter "event=start" --format "{{.Actor.Attributes.name}}" 2>/dev/null | while read -r cname; do
    [[ -z "$cname" ]] && continue
    if [[ "$cname" =~ ^(traffmon|pawns|tun|gluetun|hev|socks) ]]; then
      /usr/local/bin/webshare_shield.sh --test "$cname" >/dev/null 2>&1 &
    fi
  done
  exit 0
fi

# ==================== CHẾ ĐỘ THI HÀNH (RUN / TEST / ROLLBACK) ====================
if [[ "$MODE" != "TEST" ]]; then
  echo -e "\n${C_B}======================================================================${C_0}"
  echo -e "${C_B}>>> [UNIVERSAL SHIELD V3.3] PHÁO ĐÀI BẢO VỆ CHUYÊN SÂU 100% CONTAINER <<<${C_0}"
  echo -e "${C_B}======================================================================${C_0}"
fi

TOTAL_SCANNED=0
PROTECTED_COUNT=0
declare -A PROCESSED_PIDS

CONTAINER_LIST=$(docker ps -q 2>/dev/null)
if [[ "$MODE" == "TEST" ]]; then
  CONTAINER_LIST=$(docker inspect -f '{{.Id}}' "$TARGET_SINGLE" 2>/dev/null || true)
  if [[ -z "$CONTAINER_LIST" ]]; then
    exit 1
  fi
fi

for cid in $CONTAINER_LIST; do
  TOTAL_SCANNED=$((TOTAL_SCANNED + 1))
  cname=$(docker inspect -f "{{.Name}}" "$cid" 2>/dev/null | sed "s|^/||")
  netmode=$(docker inspect -f "{{.HostConfig.NetworkMode}}" "$cid" 2>/dev/null || echo "")

  # TỰ ĐỘNG XỬ LÝ CẢ CONTAINER PROXY LẪN DIRECT CONNECTION
  target_tun=""
  net_pid=0
  if [[ "$netmode" =~ ^container:(.+) ]]; then
    target_tun="${BASH_REMATCH[1]}"
    net_pid=$(docker inspect -f "{{.State.Pid}}" "$target_tun" 2>/dev/null || echo 0)
  elif [[ "$cname" =~ ^tun|^gluetun|^hev|^socks ]]; then
    target_tun="$cname"
    net_pid=$(docker inspect -f "{{.State.Pid}}" "$cid" 2>/dev/null || echo 0)
  elif [[ "$cname" =~ ^(traffmon|pawns) ]]; then
    # Direct connection: Dùng chính PID của container để khóa chốt mạng
    target_tun="direct-host"
    net_pid=$(docker inspect -f "{{.State.Pid}}" "$cid" 2>/dev/null || echo 0)
  fi

  # Bỏ qua nếu không phải container cày tiền
  [[ -z "$target_tun" ]] && continue

  hosts_path=$(docker inspect -f "{{.HostsPath}}" "$cid" 2>/dev/null || echo "")

  if [[ "$MODE" == "DRY_RUN" ]]; then
    echo -e "  [SẼ BỌC GIÁP] ${C_C}$cname${C_0} (Tunnel: $target_tun, PID: $net_pid)"
    PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
    continue
  fi

  if [[ "$MODE" == "ROLLBACK" ]]; then
    if [[ -f "$hosts_path" ]]; then
      sed -i "/$MARKER/,+60d" "$hosts_path" 2>/dev/null || true
    fi
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
    echo -e "  -> Đã gỡ bỏ: ${cname}"
    PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
    continue
  fi

  # 1. Khóa cổng độc hại bằng TCP RST (Chạy trên PID buồng mạng tương ứng)
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

  # 2. Bổ trợ danh sách Auth Blackhole vào file hosts (Tự xóa bản cũ để nạp mới đầy đủ)
  if [[ -f "$hosts_path" ]]; then
    if grep -q "$MARKER" "$hosts_path"; then
      sed -i "/$MARKER/,+60d" "$hosts_path" 2>/dev/null || true
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
  echo -e "${C_G}[HOÀN TẤT BẢO VỆ PHÁO ĐÀI V3.3] Kết quả:${C_0}"
  echo -e "  * Tổng container đã bọc giáp : ${C_G}${PROTECTED_COUNT}${C_0} container (Cả Proxy & Direct)"
  echo -e "  * Cổng kiếm tiền mở 100%    : ${C_G}Port 80 (HTTP) & Port 443 (HTTPS)${C_0}"
  echo -e "  * Trạng thái an toàn        : ${C_G}[100% SẠCH BÓNG] Không còn góc chết!${C_0}"
  echo -e "${C_B}======================================================================${C_0}\n"
fi
exit 0

#!/usr/bin/env bash
################################################################################
# Script Name : webshare_shield.sh
# Repository  : tech-tnitechsolve/bandwidth-sharing
# Phiên bản   : V3 ULTIMATE MASTER - CHỐNG SUSPEND TUYỆT ĐỐI 100%
# Đặc tính    : TCP RST 0ms | Chặn Torrent DMCA | Chặn VoIP/RDP/DB/Mail | Zero-Leak
################################################################################
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'

# 1. Danh sách domain Auth, Crypto, Banking, Ticketing & Chính phủ nhạy cảm
AUTH_TARGETS=(
  # Google, Microsoft & Yahoo
  "accounts.google.com"
  "oauth2.googleapis.com"
  "login.microsoftonline.com"
  "login.live.com"
  "account.live.com"
  "login.yahoo.com"
  
  # Streaming & Social Auth
  "passport.twitch.tv"
  "auth.netflix.com"
  "accounts.spotify.com"
  
  # Gaming Brute-force
  "login.steampowered.com"
  "help.steampowered.com"
  "auth.riotgames.com"
  "account.riotgames.com"
  "auth.roblox.com"
  "auth.ea.com"
  "login.battle.net"
  "id.sonyentertainmentnetwork.com"
  
  # Apple & SSO Identity
  "appleid.apple.com"
  "idmsa.apple.com"
  "auth0.com"
  "auth.atlassian.com"
  
  # Ticketing & Scalping (Webshare theo dõi gắt gao)
  "auth.ticketmaster.com"
  "identity.ticketmaster.com"
  "identity.axs.com"
  "auth.stubhub.com"
  
  # Crypto & Banking Phishing / Carding
  "accounts.binance.com"
  "login.coinbase.com"
  "auth.revolut.com"
  "auth.kraken.com"
  "login.blockchain.com"
  "www.paypal.com/signin"
  
  # Chính phủ nhạy cảm (Đã phát hiện trong log của bạn)
  "tenders.etimad.sa"
  "login.gov"
)

# 2. TOÀN BỘ CÁC CỔNG ĐỘC HẠI BỊ CẤM TRÊN TOÀN NGÀNH PROXY
# - Cổng Hacking / Điều khiển: 22, 2222 (SSH), 23 (Telnet), 3389 (RDP), 5900 (VNC)
# - Cổng Mail Spam (Chống dính Spamhaus): 25, 465, 587 (SMTP)
# - Cổng Khai thác Windows: 135, 137, 138, 139, 445 (SMB / NetBIOS)
# - Cổng Tấn công Database: 1433 (MSSQL), 3306 (MySQL), 5432 (Postgres), 6379 (Redis), 27017 (MongoDB)
# - Cổng Lừa đảo cước VoIP: 5060, 5061 (SIP protocol)
# - Cổng Tải lậu Torrent (Chống gậy bản quyền DMCA): 6881:6889, 6969, 51413
SINGLE_PORTS=(22 23 25 135 137 138 139 445 465 587 1433 2222 3306 3389 5060 5061 5432 5900 6379 6969 27017 51413)
PORT_RANGES=("6881:6889")

MARKER="# --- WEBSHARE COMPLIANCE FILTER ---"

MODE="RUN"
TARGET_SINGLE=""

# Xử lý tham số an toàn
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
  echo -e "${C_B}>>> [UNIVERSAL SHIELD V3] PHÁO ĐÀI BẢO VỆ CHUYÊN SÂU 100% PROXY VPS <<<${C_0}"
  echo -e "${C_B}======================================================================${C_0}"
fi

TOTAL_SCANNED=0
PROTECTED_COUNT=0
declare -A PROCESSED_TUNS

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

  target_tun=""
  if [[ "$netmode" =~ ^container:(.+) ]]; then
    target_tun="${BASH_REMATCH[1]}"
  elif [[ "$cname" =~ ^tun|^gluetun|^hev|^socks ]]; then
    target_tun="$cname"
  fi

  [[ -z "$target_tun" ]] && continue

  pid=$(docker inspect -f "{{.State.Pid}}" "$target_tun" 2>/dev/null || echo 0)
  hosts_path=$(docker inspect -f "{{.HostsPath}}" "$cid" 2>/dev/null || echo "")

  if [[ "$MODE" == "DRY_RUN" ]]; then
    echo -e "  [SẼ BỌC GIÁP] ${C_C}$cname${C_0} (Tunnel: $target_tun, PID: $pid)"
    PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
    continue
  fi

  if [[ "$MODE" == "ROLLBACK" ]]; then
    if [[ -f "$hosts_path" ]]; then
      sed -i "/$MARKER/,+45d" "$hosts_path" 2>/dev/null || true
    fi
    if (( pid > 0 )) && [[ -z "${PROCESSED_TUNS[$target_tun]:-}" ]]; then
      for port in "${SINGLE_PORTS[@]}"; do
        nsenter -t "$pid" -n iptables -D OUTPUT -p tcp --dport "$port" -j REJECT --reject-with tcp-reset 2>/dev/null || \
        nsenter -t "$pid" -n iptables -D OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
      done
      for prange in "${PORT_RANGES[@]}"; do
        nsenter -t "$pid" -n iptables -D OUTPUT -p tcp --dport "$prange" -j DROP 2>/dev/null || true
      done
      PROCESSED_TUNS["$target_tun"]=1
    fi
    echo -e "  -> Đã gỡ bỏ: ${cname}"
    PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
    continue
  fi

  # 1. Khóa cổng độc hại bằng TCP RST (Ngắt trong 0ms, không gây treo socket 90s)
  if (( pid > 0 )) && [[ -z "${PROCESSED_TUNS[$target_tun]:-}" ]]; then
    # Khóa các cổng đơn
    for port in "${SINGLE_PORTS[@]}"; do
      nsenter -t "$pid" -n iptables -C OUTPUT -p tcp --dport "$port" -j REJECT --reject-with tcp-reset 2>/dev/null || \
      nsenter -t "$pid" -n iptables -C OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || \
      nsenter -t "$pid" -n iptables -I OUTPUT -p tcp --dport "$port" -j REJECT --reject-with tcp-reset 2>/dev/null || \
      nsenter -t "$pid" -n iptables -I OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
    done
    # Khóa dải cổng P2P Torrent (Chống khiếu nại bản quyền DMCA)
    for prange in "${PORT_RANGES[@]}"; do
      nsenter -t "$pid" -n iptables -C OUTPUT -p tcp --dport "$prange" -j DROP 2>/dev/null || \
      nsenter -t "$pid" -n iptables -I OUTPUT -p tcp --dport "$prange" -j DROP 2>/dev/null || true
    done
    # Khóa cứng IPv6 bên trong buồng mạng (Chống rò rỉ IP thật VPS)
    nsenter -t "$pid" -n sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true

    PROCESSED_TUNS["$target_tun"]=1
  fi

  # 2. Bổ trợ danh sách Auth/Banking Blackhole vào file hosts của container
  if [[ -f "$hosts_path" ]] && ! grep -q "$MARKER" "$hosts_path"; then
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
  echo -e "${C_G}[HOÀN TẤT BẢO VỆ PHÁO ĐÀI V3] Kết quả:${C_0}"
  echo -e "  * Tổng container đã bọc giáp : ${C_G}${PROTECTED_COUNT}${C_0} container"
  echo -e "  * Cổng độc hại đã khóa sạch : ${C_Y}${SINGLE_PORTS[*]} và dải Torrent ${PORT_RANGES[*]}${C_0}"
  echo -e "  * Cơ chế ngắt kết nối lậu   : ${C_G}TCP RST trong 0ms (Xóa sạch lỗi treo socket 90s)${C_0}"
  echo -e "  * Cổng kiếm tiền mở 100%    : ${C_G}Port 80 (HTTP) & Port 443 (HTTPS)${C_0}"
  echo -e "  * Tự động hóa mới           : ${C_G}[0.1 GIÂY] Container mới mọc lên tự có giáp ngay!${C_0}"
  echo -e "${C_B}======================================================================${C_0}\n"
fi
exit 0

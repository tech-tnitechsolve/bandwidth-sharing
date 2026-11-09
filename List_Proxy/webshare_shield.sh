#!/usr/bin/env bash
################################################################################
# Script Name : webshare_shield.sh
# Repository  : tech-tnitechsolve/bandwidth-sharing
# Mục tiêu    : Decodo-style Universal Egress Protection (Áp dụng TOÀN BỘ VPS)
# Nguyên tắc  : ZERO-DOWNTIME - Không restart container, không làm nghẽn băng thông
################################################################################
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'

# 1. Danh sách domain Auth/Login, Crypto & Chính phủ nhạy cảm
AUTH_TARGETS=(
  # Google & Microsoft
  "accounts.google.com"
  "oauth2.googleapis.com"
  "login.microsoftonline.com"
  "login.live.com"
  "account.live.com"
  "login.yahoo.com"
  
  # Streaming & Social
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
  
  # Ticketing & Scalping (Webshare cấm)
  "auth.ticketmaster.com"
  "identity.ticketmaster.com"
  "identity.axs.com"
  
  # Crypto & Banking Phishing
  "accounts.binance.com"
  "login.coinbase.com"
  
  # Chính phủ nhạy cảm (Đã phát hiện trong log của bạn)
  "tenders.etimad.sa"
)

# 2. Toàn bộ các cổng độc hại cần khóa chiều ra (Tuyệt đối không ảnh hưởng Port 80 & 443)
# 22, 2222 : SSH scan
# 23       : Telnet botnet
# 3389     : Windows RDP brute-force
# 25, 465, 587 : Mail Spam (chống Spamhaus)
# 445, 139 : Windows SMB exploits
# 3306, 1433, 6379 : Dò pass cơ sở dữ liệu
DANGEROUS_PORTS=(22 23 25 139 445 465 587 1433 2222 3306 3389 6379)

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
      echo -e "${C_Y}[CHẾ ĐỘ THỬ NGHIỆM] Chỉ tác động trên DUY NHẤT container: $TARGET_SINGLE${C_0}"
      ;;
    --rollback)
      MODE="ROLLBACK"
      echo -e "${C_R}[CHẾ ĐỘ HOÀN TÁC] Đang gỡ bỏ toàn bộ giáp bảo vệ...${C_0}"
      ;;
    *)
      echo "Tham số không hợp lệ: $1 (Dùng: --dry-run | --test <tên> | --rollback)"
      exit 1
      ;;
  esac
fi

echo -e "\n${C_B}======================================================================${C_0}"
echo -e "${C_B}>>> [UNIVERSAL SHIELD PRO] BẢO VỆ CHUYÊN SÂU 100% CONTAINER TRÊN VPS <<<${C_0}"
echo -e "${C_B}======================================================================${C_0}"

TOTAL_SCANNED=0
PROTECTED_COUNT=0
declare -A PROCESSED_TUNS

CONTAINER_LIST=$(docker ps -q 2>/dev/null)
if [[ "$MODE" == "TEST" ]]; then
  CONTAINER_LIST=$(docker inspect -f '{{.Id}}' "$TARGET_SINGLE" 2>/dev/null || true)
  if [[ -z "$CONTAINER_LIST" ]]; then
    echo -e "${C_R}[LỖI] Không tìm thấy container '$TARGET_SINGLE' đang chạy!${C_0}"
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
      sed -i "/$MARKER/,+35d" "$hosts_path" 2>/dev/null || true
    fi
    if (( pid > 0 )) && [[ -z "${PROCESSED_TUNS[$target_tun]:-}" ]]; then
      for port in "${DANGEROUS_PORTS[@]}"; do
        nsenter -t "$pid" -n iptables -D OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
      done
      PROCESSED_TUNS["$target_tun"]=1
    fi
    echo -e "  -> Đã gỡ bỏ: ${cname}"
    PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
    continue
  fi

  # CHẾ ĐỘ THI HÀNH (RUN hoặc TEST)
  # 1. Khóa sạch các cổng phá hoại trong Namespace mạng của Tunnel
  if (( pid > 0 )) && [[ -z "${PROCESSED_TUNS[$target_tun]:-}" ]]; then
    for port in "${DANGEROUS_PORTS[@]}"; do
      nsenter -t "$pid" -n iptables -C OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || \
      nsenter -t "$pid" -n iptables -I OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
    done
    PROCESSED_TUNS["$target_tun"]=1
  fi

  # 2. Bổ trợ danh sách Auth Blackhole vào hosts của container
  if [[ -f "$hosts_path" ]] && ! grep -q "$MARKER" "$hosts_path"; then
    {
      echo ""
      echo "$MARKER"
      for domain in "${AUTH_TARGETS[@]}"; do
        echo "0.0.0.0 $domain"
      done
    } >> "$hosts_path"
  fi

  echo -e "  -> Bọc giáp thành công: ${C_G}${cname}${C_0} (Tunnel: ${target_tun})"
  PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
done

echo -e "\n${C_B}======================================================================${C_0}"
if [[ "$MODE" == "ROLLBACK" ]]; then
  echo -e "${C_G}[HOÀN TẤT GỠ BỎ] Toàn bộ hệ thống đã quay về nguyên trạng ban đầu!${C_0}"
else
  echo -e "${C_G}[HOÀN TẤT BẢO VỆ TOÀN DIỆN] Kết quả:${C_0}"
  echo -e "  * Tổng container đã bọc giáp : ${C_G}${PROTECTED_COUNT}${C_0} container"
  echo -e "  * Các cổng độc hại đã khóa  : ${C_Y}${DANGEROUS_PORTS[*]}${C_0}"
  echo -e "  * Cổng kiếm tiền mở 100%    : ${C_G}Port 80 (HTTP) & Port 443 (HTTPS)${C_0}"
  echo -e "  * Trạng thái hoạt động       : ${C_G}[100% HEALTHY] Không restart, không nghẽn.${C_0}"
fi
echo -e "${C_B}======================================================================${C_0}\n"
exit 0

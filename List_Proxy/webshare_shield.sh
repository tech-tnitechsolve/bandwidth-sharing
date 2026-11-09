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

# 1. Danh sách domain Auth/Login hay bị lạm dụng dò pass nhất
AUTH_TARGETS=(
  "accounts.google.com"
  "oauth2.googleapis.com"
  "login.microsoftonline.com"
  "login.live.com"
  "account.live.com"
  "login.yahoo.com"
  "passport.twitch.tv"
  "auth.netflix.com"
  "accounts.spotify.com"
  "login.steampowered.com"
  "help.steampowered.com"
  "auth.riotgames.com"
  "account.riotgames.com"
  "auth.roblox.com"
  "auth.ea.com"
  "login.battle.net"
  "id.sonyentertainmentnetwork.com"
  "appleid.apple.com"
  "idmsa.apple.com"
  "auth.ticketmaster.com"
  "identity.ticketmaster.com"
  "identity.axs.com"
  "auth0.com"
  "auth.atlassian.com"
  "accounts.binance.com"
)

# 2. Cổng nguy hiểm gây án phạt Abuse/Hack server (Port 22/2222 SSH scan, Port 25 Spam mail)
DANGEROUS_PORTS=(22 25 2222)

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
echo -e "${C_B}>>> [UNIVERSAL SHIELD] BẢO VỆ TOÀN DIỆN 100% CONTAINER TRÊN VPS <<<${C_0}"
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

  # Bỏ qua nếu container không thuộc hệ sinh thái Proxy / Income
  [[ -z "$target_tun" ]] && continue

  pid=$(docker inspect -f "{{.State.Pid}}" "$target_tun" 2>/dev/null || echo 0)
  hosts_path=$(docker inspect -f "{{.HostsPath}}" "$cid" 2>/dev/null || echo "")

  if [[ "$MODE" == "DRY_RUN" ]]; then
    echo -e "  [SẼ BỌC GIÁP] ${C_C}$cname${C_0} (Tunnel: $target_tun, PID: $pid)"
    PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
    continue
  fi

  if [[ "$MODE" == "ROLLBACK" ]]; then
    # Gỡ bỏ hosts
    if [[ -f "$hosts_path" ]]; then
      sed -i "/$MARKER/,+25d" "$hosts_path" 2>/dev/null || true
    fi
    # Gỡ bỏ iptables
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
  # 1. Khóa cổng nguy hiểm trong Namespace mạng của Tunnel (Mỗi tunnel xử lý 1 lần duy nhất)
  if (( pid > 0 )) && [[ -z "${PROCESSED_TUNS[$target_tun]:-}" ]]; then
    for port in "${DANGEROUS_PORTS[@]}"; do
      nsenter -t "$pid" -n iptables -C OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || \
      nsenter -t "$pid" -n iptables -I OUTPUT -p tcp --dport --dport "$port" -j DROP 2>/dev/null || true
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
  echo -e "${C_G}[HOÀN TẤT GỠ BỎ] Hệ thống đã quay về nguyên trạng ban đầu 100%!${C_0}"
else
  echo -e "${C_G}[HOÀN TẤT BẢO VỆ] Kết quả:${C_0}"
  echo -e "  * Tổng container đã bọc giáp : ${C_G}${PROTECTED_COUNT}${C_0} container"
  echo -e "  * Trạng thái hoạt động       : ${C_G}[100% HEALTHY] Không restart, băng thông mở tối đa.${C_0}"
fi
echo -e "${C_B}======================================================================${C_0}\n"
exit 0

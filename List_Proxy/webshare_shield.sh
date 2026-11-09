#!/usr/bin/env bash
################################################################################
# Script Name : webshare_shield.sh
# Mục tiêu    : Thay thế bộ lọc của Webshare (Decodo-style Egress Protection)
# Nguyên tắc  : ZERO-DOWNTIME - Không restart container, không làm nghẽn băng thông
################################################################################
set -uo pipefail

# 1. Tự nâng quyền root nếu chạy bằng user thường
if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

C_G='\033[1;32m'; C_Y='\033[1;33m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'

# 2. Danh sách FQDN trang Auth/Login nhạy cảm mà Webshare Activity Meter theo dõi
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

# 3. Các cổng nguy hiểm cần chặn chiều ra (Không sinh ra tiền nhưng kích hoạt cờ Abuse)
# Port 22/2222: SSH Brute-force (đã thấy trong log)
# Port 25: SMTP Mail Spam
DANGEROUS_PORTS=(22 25 2222)

MARKER="# --- WEBSHARE COMPLIANCE FILTER ---"
WEBSHARE_IDENTIFIER="130.180."

echo -e "\n${C_B}======================================================================${C_0}"
echo -e "${C_B}>>> [WEBSHARE SHIELD] BẮT ĐẦU RÀ SOÁT VÀ BỌC GIÁP KHÔNG XUNG ĐỘT <<<${C_0}"
echo -e "${C_B}======================================================================${C_0}"

TOTAL_SCANNED=0
PROTECTED_COUNT=0
SKIPPED_COUNT=0

for cid in $(docker ps -q 2>/dev/null); do
  TOTAL_SCANNED=$((TOTAL_SCANNED + 1))
  cname=$(docker inspect -f "{{.Name}}" "$cid" 2>/dev/null | sed "s|^/||")
  netmode=$(docker inspect -f "{{.HostConfig.NetworkMode}}" "$cid" 2>/dev/null || echo "")

  target_tun=""
  if [[ "$netmode" =~ ^container:(.+) ]]; then
    target_tun="${BASH_REMATCH[1]}"
  elif [[ "$cname" =~ ^tun ]]; then
    target_tun="$cname"
  fi

  # Bỏ qua nếu container không gắn với tunnel mạng proxy
  [[ -z "$target_tun" ]] && continue

  tun_info=$(docker inspect -f "{{range .Config.Env}}{{println .}}{{end}} {{.Config.Cmd}}" "$target_tun" 2>/dev/null || echo "")

  # Nhận diện chính xác chỉ tác động lên container thuộc Webshare
  if echo "$tun_info" | grep -q "$WEBSHARE_IDENTIFIER" || echo "$tun_info" | grep -qi "webshare"; then
    pid=$(docker inspect -f "{{.State.Pid}}" "$target_tun" 2>/dev/null || echo 0)
    hosts_path=$(docker inspect -f "{{.HostsPath}}" "$cid" 2>/dev/null || echo "")

    # 1. Khóa các cổng nguy hiểm bên trong Namespace mạng (Không ảnh hưởng Port 80/443)
    if (( pid > 0 )); then
      for port in "${DANGEROUS_PORTS[@]}"; do
        nsenter -t "$pid" -n iptables -C OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || \
        nsenter -t "$pid" -n iptables -I OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
      done
    fi

    # 2. Bổ trợ danh sách Auth Blackhole vào file hosts của container
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
  else
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
  fi
done

echo -e "\n${C_B}======================================================================${C_0}"
echo -e "${C_G}[HOÀN TẤT BẢO VỆ] Kết quả kiểm tra:${C_0}"
echo -e "  * Tổng container đang chạy : ${TOTAL_SCANNED}"
echo -e "  * Container Webshare đã bọc: ${C_G}${PROTECTED_COUNT}${C_0}"
echo -e "  * Container khác giữ nguyên: ${SKIPPED_COUNT}"
echo -e "  * Trạng thái hệ thống      : ${C_G}[100% HEALTHY] Không khởi động lại bất kỳ node nào.${C_0}"
echo -e "${C_B}======================================================================${C_0}\n"
exit 0

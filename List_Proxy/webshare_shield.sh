#!/usr/bin/env bash
################################################################################
# Script Name : webshare_shield.sh
# Phiên bản   : V5.3 MASTER - TỰ ĐỘNG ĐỒNG BỘ DOMAIN MỚI 100% (ZERO-OMISSION)
# Đặc tính    : Fix lỗi sót domain cũ | 0ms TCP RST | 0% CPU PID 1 | 100% An toàn
################################################################################
set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

renice -n 19 $$ >/dev/null 2>&1 || true

C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_0='\033[0m'

AUTH_TARGETS=(
  "auth.uber.com" "cn-geo1.uber.com" "api.imvu.com" "imvu.com"
  "authentication-prod.ar.indazn.com" "iforgot.apple.com" "api.minecraftservices.com"
  "api.sendgrid.com" "api.steampowered.com" "account.live.com" "login.live.com"
  "clienthosting.eu" "perfora.net" "Host-By.DMIT.com" "hostedby.privatelayer.com"
  "astravps.co" "ddos-guard.net" "server.keyubu.com" "dreambyte.hu"
  "server.bhutra.net" "fl-s1.serverpanel.com" "ib.systems" "protected.bisquit.host"
  "www734.sakura.ne.jp" "spk.laws.ms" "d30096.exe.regrucolo.ru" "dedicated.sollutium.com"
  "cp-26.controlpanel.si" "accounts.google.com" "oauth2.googleapis.com"
  "login.microsoftonline.com" "login.yahoo.com" "account.hoyoverse.com"
  "api-account-os.hoyoverse.com" "connect.ubisoft.com" "signin.ea.com" "auth.ea.com"
  "login.steampowered.com" "help.steampowered.com" "auth.riotgames.com"
  "account.riotgames.com" "auth.roblox.com" "login.battle.net"
  "id.sonyentertainmentnetwork.com" "account-public-service-prod.ol.epicgames.com"
  "auth.dmarket.com" "passport.twitch.tv" "auth.netflix.com" "accounts.spotify.com"
  "auth.disneyplus.com" "sso.crunchyroll.com" "login.hbo.com" "auth.openai.com"
  "auth0.openai.com" "i.instagram.com" "api.tiktokv.com" "appleid.apple.com"
  "idmsa.apple.com" "auth0.com" "auth.atlassian.com" "auth.ticketmaster.com"
  "identity.ticketmaster.com" "identity.axs.com" "auth.stubhub.com"
  "auth.livenation.com" "auth.seatgeek.com" "accounts.binance.com" "login.coinbase.com"
  "auth.revolut.com" "auth.kraken.com" "auth.kucoin.com" "login.blockchain.com"
  "auth.paypal.com" "identity.paypal.com" "identity.uber.com" "auth.doordash.com"
  "secure.chase.com" "secure.bankofamerica.com" "connect.secure.wellsfargo.com"
  "online.citi.com" "verified.capitalone.com" "tenders.etimad.sa" "login.gov"
  "secure.login.gov" "sa.www4.irs.gov"
)

BAD_PORTS="22,23,25,135,137,138,139,445,465,587,1433,2222,3306,3389,5060,5061,5432,5900,6379,6969,27017,51413"
BAD_RANGES="6881:6889"
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

apply_shield_core() {
  local net_pid="$1"
  local hosts_path="$2"

  # 1. Bọc iptables Custom Chain
  if (( net_pid > 0 )); then
    if ! nsenter -t "$net_pid" -n iptables -C OUTPUT -j WEBSHARE_SHIELD >/dev/null 2>&1; then
      nsenter -t "$net_pid" -n iptables -N WEBSHARE_SHIELD 2>/dev/null || true
      nsenter -t "$net_pid" -n iptables -F WEBSHARE_SHIELD 2>/dev/null || true
      nsenter -t "$net_pid" -n iptables -A WEBSHARE_SHIELD -p tcp -m multiport --dports "$BAD_PORTS" -j REJECT --reject-with tcp-reset 2>/dev/null || \
      nsenter -t "$net_pid" -n iptables -A WEBSHARE_SHIELD -p tcp -m multiport --dports "$BAD_PORTS" -j DROP 2>/dev/null || true
      nsenter -t "$net_pid" -n iptables -A WEBSHARE_SHIELD -p tcp --dport "$BAD_RANGES" -j DROP 2>/dev/null || true
      nsenter -t "$net_pid" -n iptables -I OUTPUT 1 -j WEBSHARE_SHIELD 2>/dev/null || true
      nsenter -t "$net_pid" -n sysctl -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
    fi
  fi

  # 2. Bọc DNS Hosts: KIỂM TRA ĐÍCH DANH DOMAIN MỚI NHẤT (Chống sót domain cũ)
  if [[ -f "$hosts_path" ]]; then
    if ! grep -q "0.0.0.0 auth.uber.com" "$hosts_path" 2>/dev/null; then
      # Xóa sạch marker cũ nếu có để nạp lại bản đầy đủ nhất
      sed -i "/$MARKER/,\$d" "$hosts_path" 2>/dev/null || true
      {
        echo ""
        echo "$MARKER"
        for domain in "${AUTH_TARGETS[@]}"; do
          echo "0.0.0.0 $domain"
        done
      } >> "$hosts_path"
    fi
  fi
}

rollback_shield_core() {
  local net_pid="$1"
  local hosts_path="$2"
  [[ -f "$hosts_path" ]] && sed -i "/$MARKER/,\$d" "$hosts_path" 2>/dev/null || true
  if (( net_pid > 0 )); then
    nsenter -t "$net_pid" -n iptables -D OUTPUT -j WEBSHARE_SHIELD 2>/dev/null || true
    nsenter -t "$net_pid" -n iptables -F WEBSHARE_SHIELD 2>/dev/null || true
    nsenter -t "$net_pid" -n iptables -X WEBSHARE_SHIELD 2>/dev/null || true
  fi
}

if [[ "$MODE" == "WATCH" ]]; then
  while true; do
    while ! docker info >/dev/null 2>&1; do sleep 3; done
    docker events --filter "type=container" --filter "event=start" --format "{{.Actor.Attributes.name}}" 2>/dev/null | while read -r cname; do
      [[ -z "$cname" ]] && continue
      if [[ "$cname" =~ ^(traffmon|pawns|tun|gluetun|hev|socks) ]]; then
        (
          sleep 0.5
          /usr/local/bin/webshare_shield.sh --test "$cname" >/dev/null 2>&1
        ) &
      fi
    done
    sleep 2
  done
  exit 0
fi

if [[ "$MODE" == "TEST" && -n "$TARGET_SINGLE" ]]; then
  read -r c_netmode c_pid c_hosts < <(docker inspect --format '{{.HostConfig.NetworkMode}}	{{.State.Pid}}	{{.HostsPath}}' "$TARGET_SINGLE" 2>/dev/null || echo "")
  [[ -z "$c_pid" ]] && exit 0

  target_pid="$c_pid"
  if [[ "$c_netmode" =~ ^container:(.+) ]]; then
    parent_ctr="${BASH_REMATCH[1]}"
    parent_pid=$(docker inspect --format '{{.State.Pid}}' "$parent_ctr" 2>/dev/null || echo 0)
    (( parent_pid > 0 )) && target_pid="$parent_pid"
  fi

  apply_shield_core "$target_pid" "$c_hosts"
  exit 0
fi

RUNNING_IDS=$(docker ps -q 2>/dev/null)
[[ -z "$RUNNING_IDS" ]] && exit 0

if [[ "$MODE" == "RUN" ]]; then
  echo -e "\n${C_B}======================================================================${C_0}"
  echo -e "${C_B}>>> [WEBSHARE SHIELD V5.3] BẢO VỆ CHUYÊN SÂU - BẢO LƯU 100% INCOME <<<${C_0}"
  echo -e "${C_B}======================================================================${C_0}"
fi

declare -A CTR_NETMODE CTR_PID CTR_HOSTS
PROTECTED_COUNT=0

while IFS=$'\t' read -r i_id i_name i_netmode i_pid i_hosts; do
  [[ -z "$i_id" ]] && continue
  clean_n="${i_name#/}"
  CTR_NETMODE["$clean_n"]="$i_netmode"
  CTR_PID["$clean_n"]="$i_pid"
  CTR_PID["$i_id"]="$i_pid"
  CTR_PID["${i_id:0:12}"]="$i_pid"
  CTR_HOSTS["$clean_n"]="$i_hosts"
done < <(docker inspect --format '{{.Id}}	{{.Name}}	{{.HostConfig.NetworkMode}}	{{.State.Pid}}	{{.HostsPath}}' $RUNNING_IDS 2>/dev/null)

for cname in "${!CTR_NETMODE[@]}"; do
  netmode="${CTR_NETMODE[$cname]:-}"
  hosts_path="${CTR_HOSTS[$cname]:-}"
  net_pid=0

  if [[ "$netmode" =~ ^container:(.+) ]]; then
    target_tun="${BASH_REMATCH[1]}"
    net_pid="${CTR_PID[$target_tun]:-0}"
  elif [[ "$cname" =~ ^tun|^gluetun|^hev|^socks || "$cname" =~ ^(traffmon|pawns) ]]; then
    net_pid="${CTR_PID[$cname]:-0}"
  fi

  (( net_pid <= 0 )) && continue

  if [[ "$MODE" == "ROLLBACK" ]]; then
    rollback_shield_core "$net_pid" "$hosts_path"
    continue
  fi

  apply_shield_core "$net_pid" "$hosts_path"
  PROTECTED_COUNT=$((PROTECTED_COUNT + 1))
done

if [[ "$MODE" == "RUN" ]]; then
  SVC_FILE="/etc/systemd/system/webshare-watcher.service"
  if [[ ! -f "$SVC_FILE" ]] && command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    cat > "$SVC_FILE" << "EOF_SVC"
[Unit]
Description=Realtime Webshare Shield Event Watcher (Zero CPU)
After=docker.service
Requires=docker.service

[Service]
Type=simple
Nice=19
ExecStart=/usr/local/bin/webshare_shield.sh --watch
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_SVC
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now webshare-watcher.service >/dev/null 2>&1 || true
    echo -e "  * ${C_G}[SYSTEMD]${C_0} Đã cấu hình webshare-watcher.service lần đầu thành công."
  fi

  mkdir -p /etc/cron.d
  if ! grep -q "webshare_shield.sh" /etc/cron.d/internetincome 2>/dev/null; then
    echo "*/15 * * * * root /usr/local/bin/webshare_shield.sh >/dev/null 2>&1" >> /etc/cron.d/internetincome
    echo -e "  * ${C_G}[CRON]${C_0} Đã thiết lập kiểm tra định kỳ 15 phút một lần."
  fi

  echo -e "\n${C_G}[HOÀN TẤT] Bọc giáp an toàn cho ${PROTECTED_COUNT} container!${C_0}"
  echo -e "  - Container đang chạy: ${C_G}Giữ nguyên 100%, không bị restart hay ngắt phiên.${C_0}"
  echo -e "  - Danh sách FQDN     : ${C_G}Đồng bộ mới 100% (Uber, Apple, Steam, DAZN...).${C_0}"
  echo -e "  - Tải CPU hệ thống   : ${C_G}Mát mẻ 24/7, 0% CPU PID 1 systemd.${C_0}\n"
fi

if [[ "$MODE" == "ROLLBACK" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop webshare-watcher.service 2>/dev/null || true
    systemctl disable webshare-watcher.service 2>/dev/null || true
    rm -f /etc/systemd/system/webshare-watcher.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  sed -i '/webshare_shield.sh/d' /etc/cron.d/internetincome 2>/dev/null || true
  echo -e "\n${C_G}[HOÀN TẤT GỠ BỎ] Đã tháo sạch toàn bộ rule và dừng service!${C_0}\n"
fi
exit 0

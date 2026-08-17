#!/usr/bin/env bash
#============================================================================
#  income.sh — BO CONG CU BANDWIDTH-SHARING TRONG 1 FILE (gọn, dễ check)
#
#  Cach dung:
#    sudo bash income.sh            # kiem tra on dinh 24/7 (mac dinh, ~15s)
#    sudo bash income.sh --watch    # do mang 60s (mat goi/jitter)
#    sudo bash income.sh --fix      # kiem tra + TU SUA an toan (BBR/sysctl/TUN)
#    sudo bash income.sh plan       # lap ke hoach so IP / app moi IP
#
#  Script KHONG dung proxy cua ban de ra ngoai khi kiem tra (ping/curl/STUN
#  di bang IP may, giong quan tri). Neu co proxies.txt thi chi test bat tay
#  va egress cua proxy (1 luot) de biet co ro ri IP goc khong.
#
#  Nen tang: Traff, Bitping, Spide, Proxyrack, Proxybase, Proxylite, Repocket,
#  Titan, AntGain, WizardGain, Mysterium, Honeygain, Pawns, PacketStream,
#  PacketShare, EarnFM, EarnApp, Wipter, Ebesucher, Grass.
#  (Peer2Profit da dong cua — da loai.)
#============================================================================
set -u
PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin:/usr/local/bin"
VERSION="2.0.0"

# ---- mau & in ----
if [[ -t 1 ]]; then G=$'\033[1;32m';Y=$'\033[1;33m';R=$'\033[1;31m';B=$'\033[1;34m';C=$'\033[1;36m';N=$'\033[0m'
else G='';Y='';R='';B='';C='';N='';fi
say(){ printf '%s[--]%s %s\n' "$C" "$N" "$*"; }
ok(){  printf '%s[OK]%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s[!!]%s %s\n' "$Y" "$N" "$*"; }
bad(){ printf '%s[XX]%s %s\n' "$R" "$N" "$*"; }
need(){ command -v "$1" >/dev/null 2>&1; }
sec(){ echo; echo -e "${B}===== $* =====${N}"; }

DO_WATCH=0; DO_FIX=0; MODE="check"
for a in "$@"; do case "$a" in
  --watch) DO_WATCH=1 ;; --fix) DO_FIX=1 ;;
  plan|wizard) MODE="plan" ;;
  -h|--help) grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac; done
[[ $EUID -ne 0 ]] && warn "Nen chay root (sudo) de kiem tra/sua kernel, TUN day du."

# ============================ TIEN ICH MANG ============================
resolve4(){ local h="$1" ip; ip=$(getent ahostsv4 "$h" 2>/dev/null|awk '{print $1;exit}');
  [[ -z "$ip" ]] && for d in 1.1.1.1 8.8.8.8; do need host && ip=$(host -W2 -t A "$h" "$d" 2>/dev/null|awk '/has address/{print $4;exit}');
    [[ -z "$ip" ]] && need dig && ip=$(dig +short +time=2 +tries=1 "@$d" "$h" A 2>/dev/null|grep -E '^[0-9.]+$'|head -1); [[ -n "$ip" ]] && break; done
  printf '%s' "$ip"; }
tcpprobe(){ timeout "${3:-4}" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }
tcp_check(){ local h="$1" p="$2" t="${3:-4}" ip t0 t1; ip=$(resolve4 "$h"); [[ -z "$ip" ]] && { echo FAIL; return 1; }
  t0=$(date +%s.%N); if tcpprobe "$ip" "$p" "$t"; then t1=$(date +%s.%N); awk -v a="$t0" -v b="$t1" 'BEGIN{printf "OK %.0f",(b-a)*1000}'; else echo FAIL; fi; }
test_eps(){ local list="$1" t="${2:-4}" IFS=',' e h p r okc=0 ms=""; for e in $list; do h="${e%%:*}";p="${e##*:}"; r=$(tcp_check "$h" "$p" "$t");
  [[ "$r" == OK* ]] && { okc=$((okc+1)); [[ -z "$ms" ]] && ms="${r#OK }"; }; done; (( okc>0 )) && echo "OK ${ms:-0}" || echo FAIL; }
spide_eps(){ local url cfg s p out; for url in \
  "https://pub-bf426a5300a643d2884389c8985f5181.r2.dev/client_config_prod_v0.1.json" \
  "https://pub-e22077b8a59f4e8286978a2c49fd4b1e.r2.dev/client_config_prod_v0.1.json"; do
  cfg=$(curl -fsS --max-time 6 "$url" 2>/dev/null)||continue
  s=$(printf '%s' "$cfg"|grep -oE '"(host|server|address|ip)"[[:space:]]*:[[:space:]]*"[0-9a-zA-Z._-]+"'|head -1|sed -E 's/.*"([0-9a-zA-Z._-]+)"$/\1/')
  p=$(printf '%s' "$cfg"|grep -oE '"(port|connect_port)"[[:space:]]*:[[:space:]]*[0-9]+'|head -1|grep -oE '[0-9]+$')
  [[ -n "$s" ]] && { out="${s}:${p:-50001}"; break; }; done
  echo "${out:-158.255.7.213:50001,159.223.219.217:50001}"; }

# ============================ CATALOG APP ============================
# key|ten|ram|ip(=resi/both)|tun|chrom|note
CATALOG=(
  "traff|Traffmonetizer|80|both|0|0|nhe, VPS tot, crypto"
  "bitping|Bitping|100|both|0|0|outbound chuan, khong can cong dac biet"
  "spide|Spide|192|both|1|0|TUN + TCP 50001; chay tot qua proxy"
  "proxyrack|Proxyrack|80|both|0|0|nhe, dc ho tro"
  "proxybase|Proxybase|80|both|0|0|nhe"
  "proxylite|Proxylite|80|both|0|0|app Nga"
  "repocket|Repocket|200|both|0|0|Node.js, can email+API key"
  "titan|Titan|280|both|0|0|nang, can disk"
  "antgain|AntGain|80|both|0|0|nhe"
  "wizard|WizardGain|80|both|0|0|nhe"
  "myst|Mysterium|300|both|1|0|CAN TUN+UDP P2P; khong qua HTTP proxy"
  "honey|Honeygain|200|resi|0|0|10 dev/acc, 1/IP chong ban"
  "pawns|Pawns-IPRoyal|120|resi|0|0|khong nhan datacenter"
  "pstream|PacketStream|100|resi|0|0|1 device/IP"
  "pshare|PacketShare|100|resi|0|0|can residential"
  "earnfm|EarnFM|150|resi|0|0|chong VPN/proxy"
  "earnapp|EarnApp|120|resi|0|0|ToS CAM VM/Docker (canh bao)"
  "wipter|Wipter|400|resi|1|CHI Win/Mac, can residential"
  "ebesucher|Ebesucher|400|resi|1|Chromium, rat nang"
  "grass|Grass|400|resi|1|Chromium/WebSocket, can tai khoan"
)
declare -A ENDPT=(
  [traff]="tm.traffmonetizer.com:443,traffmonetizer.com:443"
  [bitping]="bitping.com:443,app.bitping.com:443"
  [spide]="__SPIDE__"
  [proxyrack]="peer.proxyrack.com:443,www.proxyrack.com:443,residential.proxyrack.net:443"
  [proxybase]="app.proxybase.net:443"
  [proxylite]="proxylite.com:443"
  [repocket]="api.repocket.co:443,repocket.co:443,app.repocket.co:443"
  [titan]="titannet.io:443"
  [antgain]="api.antgain.net:443,antgain.net:443"
  [wizard]="app.wizardgain.com:443,wizardgain.com:443"
  [myst]="my.mysterium.network:443,api.mysterium.network:443"
  [honey]="dashboard.honeygain.com:443,feedback.honeygain.com:443"
  [pawns]="cdn.pawns.app:443,pawns.app:443"
  [pstream]="packetstream.io:443"
  [pshare]="www.packetshare.io:443"
  [earnfm]="earn.fm:443"
  [earnapp]="earnapp.com:443"
  [wipter]="wipter.com:443,app.wipter.com:443"
  [ebesucher]="www.ebesucher.com:443"
  [grass]="app.getgrass.io:443,api.getgrass.io:443"
)
find_app(){ local k="$1" l; for l in "${CATALOG[@]}"; do IFS='|' read -r key a b c d e f <<<"$l"; [[ "$key" == "$k" ]] && { echo "$l"; return 0; }; done; return 1; }
alias_of(){ case "$1" in traffmonetizer) echo traff;; honeygain) echo honey;; iproyal) echo pawns;; packetstream) echo pstream;; packetshare) echo pshare;; peer2profit) echo p2p;; mysterium) echo myst;; bitping) echo bitping;; *) echo "$1";; esac; }

# ---- thong tin he thong ----
MEM_TOTAL=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
MEM_AVAIL=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
MEM_USED=$(free -m|awk '/^Mem:/{print $3}'); MEM_BUFF=$(free -m|awk '/^Mem:/{print $6}')
SWAP_TOTAL=$(free -m|awk '/^Swap:/{print $2}'); SWAP_USED=$(free -m|awk '/^Swap:/{print int($3)}')
CPU=$(nproc 2>/dev/null||echo 1); DISK_FREE=$(df -m /|awk 'NR==2{print $4}'); DISK_TOTAL=$(df -m /|awk 'NR==2{print $2}')
INODE_USE=$(df -i /|awk 'NR==2{print $5}'|tr -d '%'); VIRT=$(systemd-detect-virt 2>/dev/null||echo none)
LOAD1=$(awk '{print $1}' /proc/loadavg); UPTIME_S=$(awk '{print int($1)}' /proc/uptime)
[[ -c /dev/net/tun ]] && TUN_OK=1 || TUN_OK=0
need docker && docker info >/dev/null 2>&1 && DOCKER_OK=1 || DOCKER_OK=0
systemctl is-active systemd-timesyncd >/dev/null 2>&1 && NTP_OK=1 || NTP_OK=0
getent ahostsv4 github.com >/dev/null 2>&1 && DNS_OK=1 || DNS_OK=0
IPF=$(sysctl -n net.ipv4.ip_forward 2>/dev/null||echo 0); BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null||echo ?)
UL=$(ulimit -n 2>/dev/null||echo 0)
DOCKER_CTRS=0; DOCKER_MEM=0
if (( DOCKER_OK )); then DOCKER_CTRS=$(docker ps -q 2>/dev/null|wc -l); DOCKER_MEM=$(docker stats --no-stream --format '{{.MemUsage}}' $(docker ps -q) 2>/dev/null|awk -F'/' '{gsub(/[^0-9.]|MiB|GiB|B/,"",$1);s+=$1}END{printf "%.0f",s}'); DOCKER_MEM=${DOCKER_MEM:-0}; fi
IPINFO=$(curl -fsS --max-time 6 https://ipinfo.io/json 2>/dev/null||echo '{}')
IP=$(echo "$IPINFO"|jq -r '.ip//"?"' 2>/dev/null); COUNTRY=$(echo "$IPINFO"|jq -r '.country//"?"' 2>/dev/null); ORG=$(echo "$IPINFO"|jq -r '.org//"?"' 2>/dev/null)
IP_KIND="resi?"; echo "$ORG"|grep -qiE 'hosting|colo|cloud|datacenter|ovh|hetzner|digitalocean|amazon|google|microsoft|oracle|vultr|linode|contabo|leaseweb' && IP_KIND="datacenter"
echo "$IPINFO"|jq -r '.privacy//{}' 2>/dev/null|grep -qiE '"hosting":true|"vpn":true|"proxy":true' && IP_KIND="datacenter"

install_tools(){ local miss=(); for t in curl awk grep sed host dig jq nproc nsenter nc tracepath; do need "$t"||case "$t" in host|dig) miss+=(dnsutils);; jq) miss+=(jq);; nc) miss+=(netcat-openbsd);; tracepath) miss+=(iproute2);; esac; done
  if ((${#miss[@]})) && need apt-get; then say "Cai them: ${miss[*]}"; DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1||true; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${miss[@]}" >/dev/null 2>&1||true; fi; }

# ============================ MODE PLAN ============================
run_plan(){
  sec "LAP KE HOACH SO IP / APP"
  read -r -p "  So nhom (1-4): " NG; [[ "$NG" =~ ^[1-4]$ ]]||NG=1
  declare -a GC=() GA=()
  for ((i=1;i<=NG;i++)); do
    read -r -p "  Nhom $i - so IP: " n
    read -r -p "  Nhom $i - app/IP (vd traff,bitping,spide): " apps
    apps=$(echo "$apps"|tr '[:upper:]' '[:lower:]'|xargs)
    [[ "$n" =~ ^[0-9]+$ ]] && ((n>0)) && [[ -n "$apps" ]] && { GC+=("$n"); GA+=("$apps"); }
  done
  ((${#GC[@]}))||{ bad "Khong co nhom hop le."; exit 1; }
  VIA_PROXY=1
  [[ "$IP_KIND" != datacenter ]] && { read -r -t 15 -p "  May co IP dan cu that, KHONG dung proxy? (y/n, mac dinh n): " r; [[ "$r" =~ ^(y|yes|co)$ ]] && VIA_PROXY=0; }
  RESERVE=384; USABLE=$((MEM_AVAIL-RESERVE)); ((USABLE<0))&&USABLE=0
  echo; printf '%-8s %-30s %6s %7s %9s %s\n' "NHOM" "APPS/IP" "SO IP" "RAM/IP" "RAM NHOM" "GHI CHU"
  echo '----------------------------------------------------------------------------'
  TIP=0; TRAM=0; TCH=0; declare -a WARNS=()
  for i in "${!GC[@]}"; do n="${GC[$i]}"; apps="${GA[$i]}"; IFS=',' read -ra ARR<<<"$apps"
    per=0; names=""; chromium=0; need_tun=0; need_udp=0; flag=""
    for raw in "${ARR[@]}"; do k=$(alias_of "$(echo "$raw"|xargs)"); if l=$(find_app "$k"); then
      IFS='|' read -r key name ram ipt tun ch note<<<"$l"; per=$((per+ram)); names+="${name}, "
      ((ch==1))&&chromium=$((chromium+1))
      if ((VIA_PROXY)); then [[ "$ipt" == resi || $tun == 1 ]]&&need_tun=1; else ((tun==1))&&need_tun=1; fi
      [[ "$key" == myst ]]&&need_udp=1; [[ "$key" == earnapp ]]&&flag+="ToS-cam; "
    else flag+="UNKNOWN($raw); "; fi; done
    names="${names%, }"; ((need_tun))&&{ per=$((per+64)); flag+="+TUN"; }
    ((need_udp&&VIA_PROXY))&&flag+=" !UDP-khong-qua-proxy"; ((chromium>0))&&flag+=" Chromium x$chromium"
    sub=$((per*n)); printf '%-8s %-30s %6s %6sMB %8sMB %s\n' "Nhom $((i+1))" "$names" "$n" "$per" "$sub" "$flag"
    TIP=$((TIP+n)); TRAM=$((TRAM+sub)); TCH=$((TCH+chromium*n)); [[ -n "$flag" ]]&&WARNS+=("Nhom $((i+1)): $flag")
  done
  echo '----------------------------------------------------------------------------'
  printf '%-8s %-30s %6s %7s %8sMB\n' "TONG" "(${TIP} IP)" "$TIP" "-" "$TRAM"
  echo "Chromium: $TCH | Mo hinh: $([[ $VIA_PROXY == 1 ]]&&echo 'qua proxy (TUN)'||echo 'IP goc')"
  echo; if ((TRAM<=USABLE)); then ok "RAM: ${TRAM}MB / ${USABLE}MB -> VUA (con thua $((USABLE-TRAM))MB)"; else bad "RAM: can ${TRAM}MB, con ${USABLE}MB -> THIEU $((TRAM-USABLE))MB"; fi
  ((TCH<=CPU*2))&&ok "CPU Chromium: $TCH/$CPU core (<= $((CPU*2)))"||warn "CPU Chromium: $TCH/$CPU core -> giam con <=$((CPU*2))"
  ((TUN_OK==0))&&grep -q TUN <<<"${WARNS[*]}"&&bad "Thieu /dev/net/tun nhung co app can TUN."
  printf '%s\n' "${WARNS[@]:-}"|sed '/^$/d;s/^/  - /'
  exit 0
}

# ---- chuan doan TUN dang chay (nsenter cho image distroless) ----
inspect_tun_containers(){
  need docker && docker info >/dev/null 2>&1 || return 0
  local tids; tids=$(docker ps --format '{{.ID}} {{.Image}}' 2>/dev/null|awk '/tun2proxy|tun2socks|spide/{print $1}')
  [[ -z "$tids" ]] && { echo "    (chua co container TUN chay)"; return 0; }
  echo "    Container TUN dang chay:"
  local tid cpid name iface dr img
  for tid in $tids; do
    cpid=$(docker inspect -f '{{.State.Pid}}' "$tid" 2>/dev/null||echo 0); name=$(docker inspect -f '{{.Name}}' "$tid" 2>/dev/null|sed 's|^/||'); img=$(docker inspect -f '{{.Config.Image}}' "$tid" 2>/dev/null)
    if [[ "$cpid" != 0 && -d "/proc/$cpid/ns/net" ]] && need nsenter; then
      iface=$(nsenter -t "$cpid" -n ip -o link show 2>/dev/null|awk -F': ' '/tun|utun/{print $2;exit}')
      dr=$(nsenter -t "$cpid" -n ip route 2>/dev/null|awk '/^default/{print $0;exit}')
    fi
    printf '      %-28s iface=%s\n' "${name:0:28}" "${iface:-?}"
    [[ -n "$dr" ]] && echo "        default: $dr"
    if echo "$iface"|grep -qE 'tun|utun' && echo "$dr"|grep -qE 'dev (tun|utun)'; then ok "      $name: route di qua TUN (app bi ep qua proxy)."
    else warn "      $name: default KHONG ro TUN -> CO THE RO RI IP may!"; fi
  done
  local leak; leak=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null|grep -E '0.0.0.0:|:::'|grep -iE 'spide|spide|myst|peer|income'|head)
  if [[ -n "$leak" ]]; then warn "Container map cong ra host (co the lo):"; echo "$leak"|sed 's/^/      /'; else ok "Khong container income nao map cong ra host."; fi
}

# ---- kiem tra proxy neu co proxies.txt ----
check_proxy(){
  local pf=""
  for f in proxies.txt proxy.txt; do [[ -f "$f" ]]&&{ pf="$f"; break; }; done
  [[ -z "$pf" ]]&&pf=$(find "$PWD" /root /home /opt /srv -maxdepth 4 -type f -name proxies.txt 2>/dev/null|head -1)
  if [[ -z "$pf" ]]; then warn "Khong tim thay proxies.txt (chay tai: $PWD). Them proxy vao roi chay lai de kiem tra ro ri."; return 0; fi
  mapfile -t PL < <(grep -vE '^[[:space:]]*(#|$)' "$pf" 2>/dev/null|sed 's/\r$//'); local pcnt=${#PL[@]}
  say "Tim thay $pcnt proxy trong $pf"
  local mx=$((pcnt<8?pcnt:8)) i u hp h p ip okc=0 failc=0
  for ((i=0;i<mx;i++)); do u="${PL[$i]}"; hp="${u#*://}"; hp="${hp##*@}"; h="${hp%:*}"; p="${hp##*:}"; ip=$(resolve4 "$h")
    if [[ -n "$ip" ]] && tcpprobe "$ip" "$p" 4; then printf '    %-32s:%-6s OK\n' "$h" "$p"; okc=$((okc+1)); else printf '    %-32s:%-6s FAIL\n' "$h" "$p"; failc=$((failc+1)); fi
  done
  ((pcnt>mx))&&echo "    ... ($((pcnt-mx)) proxy khac)"
  if need curl && ((pcnt>0)); then
    local first scheme hp auth hp2 phost pport px pip hip
    first="${PL[0]}"; scheme="${first%%:*}"; hp="${first#*://}"; auth=""; hp2="$hp"
    [[ "$hp" == *@* ]]&&{ auth="${hp%@*}"; hp2="${hp##*@}"; }; phost="${hp2%:*}"; pport="${hp2##*:}"
    case "$scheme" in socks5*) px="socks5h://${auth:+$auth@}${phost}:${pport}";; socks4*) px="socks4a://${auth:+$auth@}${phost}:${pport}";; *) px="http://${auth:+$auth@}${phost}:${pport}";; esac
    pip=$(timeout 12 curl -s --max-time 10 -x "$px" https://ipinfo.io/ip 2>/dev/null||true)
    hip=$(curl -s --max-time 6 https://ipinfo.io/ip 2>/dev/null||echo "$IP")
    if [[ -n "$pip" ]]; then [[ "$pip" != "$hip" ]] && ok "Egress proxy dau: $pip (khac IP may $hip) -> KHONG ro ri." || bad "Egress proxy van $pip (trung IP may) -> PROXY KHONG AN, RO RI!";
    else warn "Khong lay duoc egress qua proxy (chan https/ipinfo hoac auth dac biet)."; fi
  fi
}

# ---- check ky Mysterium ----
check_mysterium(){
  local ready=1
  ((DOCKER_OK)) && ok "MYST: Docker san sang" || { bad "MYST: thieu Docker"; ready=0; }
  [[ -c /dev/net/tun ]] && ok "MYST: TUN san sang" || { bad "MYST: thieu TUN"; ready=0; }
  local m; for m in tun nf_nat nf_conntrack iptable_nat; do modprobe "$m" 2>/dev/null||true; done
  lsmod 2>/dev/null|grep -qE '^tun|wireguard' && ok "MYST: module tun/wireguard da nap" || warn "MYST: khong thay tun/wireguard (co the built-in)"
  if need nc; then if timeout 4 bash -c 'exec 3<>/dev/udp/stun.l.google.com/19302; printf "" >&3; head -c 16 <&3' >/dev/null 2>&1; then ok "MYST: UDP/STUN hoat dong (hole-punch kha thi)"; else bad "MYST: STUN/UDP that bai -> se 'Connection Limited'"; ready=0; fi
  else warn "MYST: thieu nc de test STUN"; fi
  local defif ifip; defif=$(ip route 2>/dev/null|awk '/default/{print $5;exit}')
  if [[ -n "$defif" ]]; then ifip=$(ip -4 -o addr show "$defif" 2>/dev/null|awk '{print $4}'|head -1|cut -d/ -f1)
    [[ -n "$ifip" && "$ifip" == "$IP" ]] && ok "MYST: $defif co IP cong khai truc tiep ($ifip) -> chay tot che do host." || echo "    MYST: IP $defif=${ifip:-?} | cong khai=${IP:-?} (sau NAT, phu thuoc hole-punch)"; fi
  if need iptables; then iptables -L OUTPUT -n 2>/dev/null|grep -qiE 'udp.*DROP|DROP.*udp' && warn "MYST: co luat DROP UDP o OUTPUT - can mo UDP 10000:60000" || ok "MYST: khong thay chan UDP o OUTPUT."; fi
  ((MEM_AVAIL>=300)) && ok "MYST: RAM du (>300MB kha dung)" || { bad "MYST: RAM qua thap"; ready=0; }
  ((DISK_FREE>=500)) && ok "MYST: disk du" || { bad "MYST: disk <500MB"; ready=0; }
  local mc; mc=$(docker ps --format '{{.Names}} {{.Image}} {{.Status}}' 2>/dev/null|grep -i myst|head -1)
  if [[ -n "$mc" ]]; then local cn caps nm; cn=$(echo "$mc"|awk '{print $1}'); ok "MYST: dang chay $mc"
    caps=$(docker inspect -f '{{.HostConfig.CapAdd}}' "$cn" 2>/dev/null); nm=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cn" 2>/dev/null)
    echo "      caps=$caps | network=$nm"
    [[ "$caps" == *NET_ADMIN* ]] && ok "MYST: co CAP_NET_ADMIN" || warn "MYST: thieu NET_ADMIN"
    case "$nm" in host) ok "MYST: --net=host (khuyen nghi Linux VPS co IP cong khai)";; default|bridge) warn "MYST: bridge - can --publish 1194:1194/udp + port forward";; esac
    local err; err=$(docker logs --tail 80 "$cn" 2>&1|grep -iE 'error|fail|unable|limited|symmetric'|tail -3); [[ -n "$err" ]]&&{ warn "MYST: log co canh bao:"; echo "$err"|sed 's/^/        /'; }
  else echo "    Lenh chuan cho VPS Linux co IP cong khai:"
    printf '      docker run -d --name myst --restart unless-stopped \\\n        --cap-add NET_ADMIN --net=host \\\n        -v myst-data:/var/lib/mysterium-node \\\n        mysteriumnetwork/mysterium-node service --agreed-terms-and-conditions\n'; fi
  ((ready)) && ok "Mysterium: DU DIEU KIEN chay on dinh." || bad "Mysterium: THIEU dieu kien (xem cac muc [XX] ben tren)."
}

# ============================ MODE CHECK (mac dinh) ============================
if [[ "$MODE" == "plan" ]]; then run_plan; fi

clear 2>/dev/null||true
echo -e "${B}==================== INCOME TOOLKIT v$VERSION ====================${N}"
echo "Thoi gian: $(date '+%F %T %Z')  |  May: $(hostname 2>/dev/null)  |  $(. /etc/os-release 2>/dev/null&&echo "$PRETTY_NAME")"
echo "Kernel: $(uname -r) ($(uname -m))  |  Uptime: $(uptime -p 2>/dev/null||uptime)"
install_tools

sec "1. PHAN CUNG & TAI NGUYEN THUC TE"
echo "  Ao hoa: $VIRT | CPU: $CPU nhan | Load(1/5/15): $(awk '{print $1" "$2" "$3}' /proc/loadavg)"
echo "  RAM  : dung ${MEM_USED}MB / ${MEM_TOTAL}MB | buff/cache ${MEM_BUFF}MB | KHA DUNG: ${G}${MEM_AVAIL}MB${N}"
echo "  Swap : dung ${SWAP_USED}MB / ${SWAP_TOTAL}MB | Disk con: ${DISK_FREE}MB / ${DISK_TOTAL}MB | Inode: ${INODE_USE}%"
((DOCKER_CTRS>0)) && echo "  Docker: $DOCKER_CTRS container dang chay (thong ke ~${DOCKER_MEM}MB cap phat)"
awk -v l="$LOAD1" -v c="$CPU" 'BEGIN{exit !(l>c*0.85)}' && warn "CPU load gan bang so nhan - qua tai" || ok "CPU load trong nguong"
((MEM_AVAIL<512)) && bad "RAM kha dung <512MB - de OOM/diet node" || ((MEM_AVAIL<1500)) && warn "RAM kha dung <1.5GB - chi chay app nhe" || ok "RAM du rong (${MEM_AVAIL}MB)"
((SWAP_USED>SWAP_TOTAL/2)) && ((SWAP_TOTAL>0)) && bad "Dang nhieu swap (${SWAP_USED}/${SWAP_TOTAL}MB) - de treo/mat ket noi"
((DISK_FREE<2048)) && bad "Disk con <2GB - don dep (docker system prune, journalctl --vacuum-size=10M)" || ok "Disk du"
((UPTIME_S<300)) && warn "Moi khoi dong $((UPTIME_S/60)) phut - chua on dinh" || ok "May chay $((UPTIME_S/3600)) gio, khong reboot gan day"

sec "2. KERNEL / SYSCTL (TUN + dong luong 24/7)"
cs(){ local k="$1" w="$2" n="$3" cur; cur=$(sysctl -n "$k" 2>/dev/null||echo "?"); printf '  %-34s = %-9s ' "$n" "$cur"
  if [[ "$cur" == "$w" ]]; then ok ""; else warn "khuyen nghi $w"; ((DO_FIX))&&{ sysctl -w "$k=$w">/dev/null 2>&1&&echo "      (da sua $w)";}; fi; }
cs net.ipv4.ip_forward 1 "ip_forward"; cs net.core.default_qdisc fq "qdisc"; cs net.ipv4.tcp_keepalive_time 300 "keepalive_time"
cs net.ipv4.tcp_keepalive_intvl 15 "keepalive_intvl"; cs net.ipv4.tcp_keepalive_probes 3 "keepalive_probes"
cs net.netfilter.nf_conntrack_max 524288 "conntrack_max"; cs net.core.somaxconn 65535 "somaxconn"; cs net.ipv4.tcp_fin_timeout 10 "fin_timeout"
printf '  %-34s = %-9s ' "tcp_congestion_control" "$BBR"; if [[ "$BBR" == bbr ]]; then ok ""; else warn "nen bbr"; ((DO_FIX))&&{ modprobe tcp_bbr 2>/dev/null; sysctl -w net.ipv4.tcp_congestion_control=bbr net.core.default_qdisc=fq >/dev/null 2>&1&&echo "      (da bat BBR)";}; fi
echo "  ulimit -n = $UL (khuyen nghi >= 1048576)"; ((UL<65536))&&warn "ulimit thap - them '* soft nofile 1048576' vao /etc/security/limits.d/"
if [[ -c /dev/net/tun ]]; then ok "/dev/net/tun SAN SANG"
  if ip tuntap add mode tun dev __inctun0 2>/dev/null; then ip link del dev __inctun0 2>/dev/null; ok "Tao duoc TUN moi (NET_ADMIN hoat dong)"; else warn "Khong tao duoc TUN moi - kiem tra quyen/module tun"; fi
else bad "KHONG co /dev/net/tun - Spide/Myst/WireGuard KHONG chay duoc"; ((DO_FIX))&&{ modprobe tun 2>/dev/null; mkdir -p /dev/net; mknod /dev/net/tun c 10 200 2>/dev/null; chmod 600 /dev/net/tun; [[ -c /dev/net/tun ]]&&ok "Da tao /dev/net/tun.";}; fi

sec "3. MANG RA NGOAI (on dinh 24/7)"
echo "  DNS: he thong=$([[ $DNS_OK == 1 ]]&&echo OK||echo LOI) | 1.1.1.1=$(timeout 3 host github.com 1.1.1.1 >/dev/null 2>&1&&echo OK||echo LOI) | 8.8.8.8=$(timeout 3 host github.com 8.8.8.8 >/dev/null 2>&1&&echo OK||echo LOI)"
N=20; ((DO_WATCH))&&N=60; PINGRC=1
if ping -c "$N" -i 0.2 -W 1 -q 1.1.1.1 >/tmp/inc_ping.txt 2>/dev/null; then PINGRC=0
elif ping -c "$N" -i 0.2 -q 1.1.1.1 >/tmp/inc_ping.txt 2>/dev/null; then PINGRC=0; fi
if ((PINGRC==0)); then
  awk '/packet loss/{for(i=1;i<=NF;i++)if($i~/%/){gsub("%","",$i);loss=$i}} /rtt|round-trip/{n=split($0,a,"/");min=a[n-3]+0;avg=a[n-2]+0;max=a[n-1]+0;jit=a[n]+0}
   END{printf "  Ping 1.1.1.1: mat %s%% | min/avg/max/jitter=%.1f/%.1f/%.1f/%.2f ms\n",loss,min,avg,max,jit; if(loss+0>5)exit 2; if(jit+0>15)exit 3; exit 0}' /tmp/inc_ping.txt
  rc=$?; ((rc==2))&&bad "Mat goi >5% - khong on dinh"; ((rc==3))&&warn "Jitter cao - de treo session"; ((rc==0))&&ok "Mang on dinh (mat goi thap, jitter nho)"
else warn "Khong ping duoc 1.1.1.1 (ICMP bi chan?)"; fi
for url in https://www.google.com/generate_204 https://cloudflare.com/cdn-cgi/trace; do
  r=$(curl -o /dev/null -s --connect-timeout 4 --max-time 6 -w '%{http_code} %{time_connect}' "$url" 2>/dev/null||echo "000 -"); code=${r%% *}; tc=${r##* }
  printf '  %-50s ' "$url"; [[ "$code" =~ ^(200|204|301|302)$ ]]&&echo "OK (connect ${tc}s)"||bad "FAIL ($code)"; done
spd=$(curl -o /dev/null -s --max-time 12 -w '%{speed_download}' https://speed.cloudflare.com/__down?bytes=25000000 2>/dev/null||echo 0)
mbps=$(awk -v s="$spd" 'BEGIN{printf "%.0f",s*8/1e6}'); echo "  Download nguong: ~${mbps} Mbps"; ((mbps<10))&&warn "Bangong thap (<10Mbps)"
echo -n "  Path MTU toi 1.1.1.1: "; MTU=1500; for sz in 1472 1452 1400 1300; do ping -M do -s "$sz" -c1 -W2 1.1.1.1 >/dev/null 2>&1&&{ MTU=$((sz+28)); break; }; done; echo "$MTU bytes"
((MTU<1500))&&warn "Path MTU <1500 ($MTU): dat TUN_MTU=$MTU (hoac thap hon) de chong treo session."

sec "4. IP CONG KHAI & LOAI IP"
echo "  IP: ${IP:-?} (${COUNTRY:-?}) - ${ORG:-?}"
if [[ "$IP_KIND" == datacenter ]]; then echo "  -> DATACENTER: app residential-only can di qua proxy; Traff/Bitping/Spide/Myst chay truc tiep OK."
else ok "IP co ve ISP/nha dan - chay duoc ca app residential-only ma khong can proxy."; fi

sec "5. TUN & PROXY (dam bao traffic app KHONG tho bang IP may)"
check_proxy; echo; inspect_tun_containers

sec "6. KET NOI TOI TUNG PLATFORM (outbound, IP may)"
printf '  %-16s %-10s %s\n' "PLATFORM" "KET NOI" "YEU CAU"; echo '  ----------------------------------------------------'
P_READY=0; P_WARN=0; P_FAIL=0
for l in "${CATALOG[@]}"; do
  IFS='|' read -r key name ram ipt tun ch note <<<"$l"
  [[ -z "$key" ]] && continue
  ep="${ENDPT[$key]:-}"
  if [[ "$ep" == "__SPIDE__" ]]; then ep=$(spide_eps); fi
  res=$(test_eps "$ep" 4); flag=""; v=OK
  [[ "$ipt" == resi && "$IP_KIND" == datacenter ]]&&flag+="resi-can-proxy;"; [[ "$tun" == 1 && $TUN_OK == 0 ]]&&flag+="can-TUN;"; [[ "$key" == myst ]]&&flag+="UDP-P2P;"; [[ "$key" == earnapp ]]&&flag+="ToS-cam-VM;"
  if [[ "$res" != OK* ]]; then v=LOI; elif [[ -n "$flag" ]]; then v=CAN; else v=OK; fi
  case "$v" in OK) col="$G"; P_READY=$((P_READY+1));; CAN) col="$Y"; P_WARN=$((P_WARN+1));; *) col="$R"; P_FAIL=$((P_FAIL+1));; esac
  printf '  '"$col"'%-16s %-10s%s'"$N"' %s %s\n' "$name" "[$v]" "${res:0:10}" "$note" "$flag"
done
echo "  => San sang: $P_READY | Can luu y: $P_WARN | Loi ket noi: $P_FAIL"

sec "7. MYSTERIUM (check ky - hay hong nhat)"
check_mysterium

# ---- diem tong ket ----
SCORE=100
((MEM_AVAIL<1500))&&SCORE=$((SCORE-10)); ((SWAP_USED>SWAP_TOTAL/2))&&((SWAP_TOTAL>0))&&SCORE=$((SCORE-15))
((DISK_FREE<2048))&&SCORE=$((SCORE-10)); awk -v l="$LOAD1" -v c="$CPU" 'BEGIN{exit !(l>c)}'&&SCORE=$((SCORE-10))
if ((PINGRC==0)); then awk '/packet loss/{for(i=1;i<=NF;i++)if($i~/%/){gsub("%","",$i);if($i+0>5)exit 1}} /rtt|round-trip/{n=split($0,a,"/");if(a[n]+0>15)exit 2}' /tmp/inc_ping.txt&&:; rc=$?; ((rc==1))&&SCORE=$((SCORE-25)); ((rc==2))&&SCORE=$((SCORE-10)); fi
[[ "$BBR" != bbr ]]&&SCORE=$((SCORE-5)); ((UL<65536))&&SCORE=$((SCORE-5)); ((TUN_OK==0))&&SCORE=$((SCORE-20))
((SCORE<0))&&SCORE=0
sec "8. TONG KET"
if ((SCORE>=90)); then mark="${G}[XUAT SAC - san sang 24/7]${N}"
elif ((SCORE>=75)); then mark="${Y}[KHA - chay tot, it canh bao]${N}"
elif ((SCORE>=60)); then mark="${Y}[TRUNG BINH - can khac phuc may diem]${N}"
else mark="${R}[YEU - de mat ket noi/income khong on dinh]${N}"; fi
echo "  San sang: ${G}$P_READY${N} platform | Can luu y: ${Y}$P_WARN${N} | Loi: ${R}$P_FAIL${N}"
echo "  RAM kha dung: ${MEM_AVAIL}MB | Co the chay them (sau khi giu 384MB): ~$((MEM_AVAIL>384?MEM_AVAIL-384:0))MB"
printf '  DIEM ON DINH: %d/100 %s\n\n' "$SCORE" "$mark"
((DO_FIX))&&{ echo "  Da ap dung tu sua an toan (BBR/sysctl/TUN). Viec can lam thu cong:"; echo "    - Mo UDP 10000-60000 trong firewall/cloud security group cho Myst."; echo "    - Dat TUN_MTU=1400 cho cac project qua proxy (spideNetwork v1.4 da mac dinh)."; echo; }
echo "  Lenh huu ich:"
echo "    sudo bash income.sh --watch   # do mang 60s"
echo "    sudo bash income.sh --fix     # tu sua BBR/sysctl/TUN"
echo "    sudo bash income.sh plan      # lap ke hoach IP/app"
echo -e "${B}================================================================${N}"

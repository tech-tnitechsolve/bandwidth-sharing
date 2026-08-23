#!/usr/bin/env bash
# bwpath.sh — mot lenh: sudo bash bwpath.sh
# Path theo chau + ma tran CONG RA (DC hay chan). Khong dung docker/iptables.
set -u
export LC_ALL=C LANG=C
VER="4.6.7"

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
DIR="${BWPATH_DIR:-/var/log/bwpath}"
KEEP_DAYS="${BWPATH_KEEP_DAYS:-7}"
INTERVAL="${BWPATH_INTERVAL:-300}"
BW_EVERY="${BWPATH_BW_EVERY:-18}"
TRACE_EVERY="${BWPATH_TRACE_EVERY:-36}"
PING_N="${BWPATH_PING_N:-8}"
BYTES="${BWPATH_BYTES:-2000000}"
PREFIX="${PREFIX:-/opt/bwpath}"

SFILE="$DIR/s.csv"
BFILE="$DIR/b.csv"
PFILE="$DIR/p.csv"
EFILE="$DIR/e.log"
ST="$DIR/.st"

have() { command -v "$1" >/dev/null 2>&1; }
iso() { date -Is 2>/dev/null || date; }
renice -n 15 $$ >/dev/null 2>&1 || true
have ionice && ionice -c 3 -p $$ >/dev/null 2>&1 || true

need_curl() { have curl || { echo "Thieu curl"; return 1; }; }

is_installed() {
  [ -x /usr/local/bin/bwpath ] || [ -x "$PREFIX/bwpath.sh" ] || return 1
  { have systemctl && [ -f /etc/systemd/system/bwpath.service ]; } && return 0
  [ -f /etc/cron.d/bwpath ]
}
svc_active() { have systemctl && systemctl is-active --quiet bwpath.service 2>/dev/null; }

ensure_pkgs() {
  have curl && have ping && return 0
  [ "$(id -u)" -eq 0 ] || return 1
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl iputils-ping traceroute iproute2 ca-certificates dnsutils >/dev/null
  elif have dnf; then dnf install -y -q curl iputils traceroute iproute bind-utils >/dev/null
  fi
}

install_files() {
  mkdir -p "$PREFIX" "$DIR"
  cp -a "$SELF" "$PREFIX/bwpath.sh"
  chmod 755 "$PREFIX/bwpath.sh"
  ln -sfn "$PREFIX/bwpath.sh" /usr/local/bin/bwpath
}

cmd_install() {
  [ "$(id -u)" -eq 0 ] || { echo "sudo $SELF"; return 1; }
  ensure_pkgs || true
  install_files
  if have systemctl; then
    cat > /etc/systemd/system/bwpath.service <<EOF
[Unit]
Description=bwpath
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/local/bin/bwpath daemon
Restart=always
RestartSec=20
Environment=BWPATH_DIR=${DIR}
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now bwpath.service
    echo "OK systemd $VER"
  else
    printf '%s\n' "*/5 * * * * BWPATH_DIR=${DIR} /usr/local/bin/bwpath once >/dev/null 2>&1" \
      "17 * * * * BWPATH_DIR=${DIR} /usr/local/bin/bwpath bw >/dev/null 2>&1" \
      "47 */3 * * * BWPATH_DIR=${DIR} /usr/local/bin/bwpath ports >/dev/null 2>&1" > /etc/cron.d/bwpath
    echo "OK cron $VER"
  fi
}

reset_series() {
  mkdir -p "$DIR"
  rm -f "$SFILE" "$BFILE" "$PFILE" "$EFILE" "$SFILE.tmp" "$BFILE.tmp" "$PFILE.tmp" \
    "$ST.ph" "$DIR/hw.txt" 2>/dev/null || true
  echo "$HDR_S" > "$SFILE"
  echo "$HDR_B" > "$BFILE"
  echo "$HDR_P" > "$PFILE"
  echo "[bwpath] da reset log $DIR — lan AUTO nay do lai tu dau"
}

ensure_install() {
  ensure_pkgs || true
  [ "$(id -u)" -eq 0 ] || { is_installed || exec sudo -E bash "$SELF"; return 0; }
  if ! is_installed; then echo "[bwpath] cai $VER"; cmd_install; return 0; fi
  local old="?"
  old="$("$PREFIX/bwpath.sh" --version 2>/dev/null | head -1 | tr -d '\r' || true)"
  echo "$old" | grep -Eq '^[0-9]+\.' || old="?"
  install_files
  if [ "$old" != "$VER" ]; then
    echo "[bwpath] cap nhat $old -> $VER"
    if [ -f "$SFILE" ] && [ "$(head -1 "$SFILE")" = "$HDR_S" ]; then
      echo "[bwpath] giu csv (cung cot) — FUP/tre khong mat"
    else
      echo "[bwpath] cot log lech — do lai tu dau"
      reset_series
    fi
    have systemctl && systemctl restart bwpath.service 2>/dev/null || true
  else
    echo "[bwpath] da cai $VER"
    svc_active || systemctl start bwpath.service 2>/dev/null || true
  fi
}

bw_recent() {
  [ -f "$BFILE" ] || return 1
  local last e now
  last="$(tail -1 "$BFILE" | awk -F, '{print $1}')"
  [ -n "$last" ] && [ "$last" != "ts" ] || return 1
  e="$(date -d "$last" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  [ "$e" -gt 0 ] && [ $((now - e)) -lt 3000 ]
}


cmd_hw() {
  mkdir -p "$DIR"
  local arch cpu ncpu mem virt cloud=none region=na shape=na chip=x86 dmi=""
  arch="$(uname -m 2>/dev/null || echo ?)"
  ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo ?)"
  mem="$(awk '/MemTotal/{printf "%.0f",$2/1024}' /proc/meminfo 2>/dev/null || echo ?)"
  cpu="$(awk -F: '/model name/{gsub(/^ /,"");print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  [ -z "$cpu" ] && cpu="$(awk -F: '/Hardware|CPU implementer/{gsub(/^ /,"");print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  virt="$(systemd-detect-virt 2>/dev/null || echo ?)"
  case "$arch" in aarch64|arm64) chip=arm64 ;; esac
  echo "$cpu $arch" | grep -qiE 'ampere|neoverse|Altra' && chip=ampere
  local meta
  meta="$(curl -fsS --max-time 2 -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/ 2>/dev/null || true)"
  if [ -n "$meta" ]; then
    cloud=OCI
    region="$(printf '%s' "$meta" | sed -n 's/.*"canonicalRegionName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    [ -z "$region" ] && region="$(printf '%s' "$meta" | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    shape="$(printf '%s' "$meta" | sed -n 's/.*"shape"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    echo "$shape" | grep -qiE 'A1|Ampere|Standard.A' && chip=ampere
    echo "$shape" | grep -qiE 'E2|E3|E4|E5|E6|VM.Standard.E' && chip=x86
  fi
  [ -r /sys/class/dmi/id/sys_vendor ] && dmi="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)-$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  echo "$dmi" | grep -qi Oracle && [ "$cloud" = none ] && cloud=OCI
  local note=""
  if [ "$chip" = ampere ] || [ "$chip" = arm64 ]; then
    note="OCI Always Free 1OCPU/6GB = Ampere A1 (aarch64), KHONG phai AMD micro 1GB"
  fi
  {
    echo "MAY host=$(hostname) arch=$arch chip=$chip ncpu=$ncpu mem_mb=$mem virt=$virt"
    echo "MAY cpu=${cpu:-?}"
    echo "MAY cloud=$cloud region=${region:-na} shape=${shape:-na}"
    echo "MAY dmi=${dmi:-na}"
    [ -n "$note" ] && echo "MAY note=$note"
    local hip igeo
    hip="$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
    if [ -n "$hip" ]; then
      igeo="$(curl -fsS --max-time 4 "http://ip-api.com/json/${hip}?fields=continent,country,city,isp,as,hosting,proxy,mobile" 2>/dev/null || true)"
      echo "MAY ip=$hip ${igeo:-}"
    fi
  } | tee "$DIR/hw.txt"
}

cmd_auto() {
  echo "======== bwpath $VER AUTO  $(iso) ========"
  if [ "$(id -u)" -ne 0 ] && ! is_installed; then
    have sudo && exec sudo -E bash "$SELF"
    echo "Can sudo"; exit 1
  fi
  [ "$(id -u)" -eq 0 ] && ensure_install
  echo "[bwpath] cau hinh may..."
  cmd_hw || true
  echo "[bwpath] socket theo chau (unicast + peerIP)..."
  cmd_once || true
  echo "[bwpath] cong ra (outbound, khong scan inbound)..."
  cmd_ports || true
  if bw_recent; then echo "[bwpath] bo qua bw (<50p)"
  else echo "[bwpath] Mbps nhe..."; cmd_bw || true; fi
  echo ""; cmd_ket || true
  echo ""; cmd_xung || true
  echo ""; cmd_report || true
  echo ""
  echo "Daemon: $(svc_active && echo DANG CHAY || echo ?). Khong dung Docker. Log $DIR"
}

mkdir -p "$DIR" 2>/dev/null || true

purge_old() {
  local cut; cut="$(date -d "-${KEEP_DAYS} days" +%s 2>/dev/null || echo 0)"
  [ "$cut" -gt 0 ] || return 0
  _trim() {
    local f="$1" hdr="${2:-1}"
    [ -f "$f" ] || return 0
    awk -v cut="$cut" -v hdr="$hdr" '
      function ep(s,c,e){c="date -d \"" s "\" +%s 2>/dev/null"; c|getline e; close(c); return e+0}
      hdr && NR==1 {print; next}
      {e=ep($1); if(e==0||e>=cut) print}
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  }
  _trim "$SFILE" 1; _trim "$BFILE" 1; _trim "$PFILE" 1; _trim "$EFILE" 0
  for f in "$SFILE" "$BFILE" "$PFILE" "$EFILE"; do
    [ -f "$f" ] || continue
    local n; n="$(wc -l < "$f")"
    [ "$n" -gt 2300 ] || continue
    if [ "$f" = "$EFILE" ]; then tail -n 2000 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else { head -1 "$f"; tail -n 2000 "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"; fi
  done
}
event() { printf '%s %s\n' "$(iso)" "$*" >> "$EFILE"; }

HDR_S="ts,epoch,ip,cf,ph,l_gg,r_gg,j_gg,l_vn,r_vn,j_vn,tcp_vn,tcp_sg,tcp_de,tcp_fr,tcp_use,tcp_usw,tcp_au,tcp_br,par,ok,cf_ok"
HDR_B="ts,ul,ul_src,dl_vn,dl_de,dl_use,dl_au,dl_br"
HDR_P="ts,icmp,t80,t443,t22,t25,t465,t587,t53,u53,t853,t8080,t8443,t9443,t1080,t3128,t2053,quic,ip6"

ensure_hdr() {
  mkdir -p "$DIR"
  [ -f "$SFILE" ] || echo "$HDR_S" > "$SFILE"
  [ -f "$BFILE" ] || echo "$HDR_B" > "$BFILE"
  [ -f "$PFILE" ] || echo "$HDR_P" > "$PFILE"
}

ping_triple() {
  local host="$1" f="$2"
  if ping -4 -c "$PING_N" -W 2 -i 0.25 "$host" >"$f" 2>/dev/null || ping -c "$PING_N" -W 2 "$host" >"$f" 2>/dev/null; then
    local loss avg mdev
    loss="$(awk '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /%/){gsub("%","",$i); print $i; exit}}' "$f")"
    avg="$(awk -F'[/ ]' '/rtt min|round-trip/{for(i=1;i<=NF;i++) if($i+0>0){a[++n]=$i} if(n>=3) print a[2]}' "$f")"
    mdev="$(awk -F'[/ ]' '/rtt min|round-trip/{for(i=1;i<=NF;i++) if($i+0>0){a[++n]=$i} if(n>=4) print a[4]}' "$f")"
    echo "${loss:-100} ${avg:-na} ${mdev:-na}"
  else
    echo "100 na na"
  fi
}

curl_probe() {
  local url="$1" hdr="$2" body="$3" w tc code ip cf=0 ms
  w="$(curl -4 -sS -D "$hdr" -o "$body" --max-time 10 -w '%{time_connect} %{http_code} %{remote_ip}' "$url" 2>/dev/null || echo "0 000 na")"
  tc="$(echo "$w" | awk '{print $1}')"; code="$(echo "$w" | awk '{print $2}')"; ip="$(echo "$w" | awk '{print $3}')"
  if grep -qiE '^server:[[:space:]]*cloudflare' "$hdr" 2>/dev/null; then
    case "$code" in 403|429|503) cf=1 ;; esac
    grep -qi 'just a moment\|cf-mitigated' "$body" 2>/dev/null && cf=1
  fi
  if awk -v t="$tc" 'BEGIN{exit !(t+0>0)}'; then ms="$(awk -v t="$tc" 'BEGIN{printf "%.1f", t*1000}')"
  else ms="na"; fi
  echo "$ms $code $cf ${ip:-na}"
}

path_hash() {
  local out="na"
  have traceroute && out="$(traceroute -4 -n -w 1 -q 1 -m 5 8.8.8.8 2>/dev/null | awk 'NR>1{print $2}' | tr '\n' ',')"
  if have sha1sum; then printf '%s' "$out" | sha1sum | awk '{print substr($1,1,10)}'
  else printf '%s' "$out" | wc -c; fi
}

dl_mbps() {
  local url="$1" bytes="${2:-$BYTES}" w spd code
  w="$(curl -4 -o /dev/null -sS --max-time 16 -r "0-$((bytes-1))" -w '%{speed_download} %{http_code}' "$url" 2>/dev/null || echo "0 000")"
  spd="$(echo "$w" | awk '{print $1}')"; code="$(echo "$w" | awk '{print $2}')"
  case "$code" in 200|206) awk -v b="$spd" 'BEGIN{printf "%.2f", b*8/1e6}' ;; *) echo 0 ;; esac
}

tcp_open() {
  local host="$1" port="$2"
  if have timeout; then
    timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1 && echo 1 || echo 0
  else
    ( exec 3<>"/dev/tcp/${host}/${port}" ) >/dev/null 2>&1 && echo 1 || echo 0
  fi
}

cmd_ports() {
  purge_old; ensure_hdr
  local icmp t80 t443 t22 t25 t465 t587 t53 u53 t853 t8080 t8443 t9443 t1080 t3128 t2053 quic ip6
  ping -4 -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && icmp=1 || icmp=0
  t80="$(tcp_open portquiz.net 80)"
  t443="$(tcp_open example.com 443)"
  [ "$t443" = 0 ] && t443="$(tcp_open portquiz.net 443)"
  t22="$(tcp_open github.com 22)"
  t25="$(tcp_open smtp.gmail.com 25)"
  t465="$(tcp_open smtp.gmail.com 465)"
  t587="$(tcp_open smtp.gmail.com 587)"
  t53="$(tcp_open 8.8.8.8 53)"
  u53=na
  if have dig; then dig +time=2 +tries=1 @8.8.8.8 . SOA >/dev/null 2>&1 && u53=1 || u53=0
  elif have nslookup; then nslookup -timeout=2 google.com 8.8.8.8 >/dev/null 2>&1 && u53=1 || u53=0
  fi
  t853="$(tcp_open 1.1.1.1 853)"
  # portquiz.net mo moi cong — phan biet CHAN outbound vs "dich khong listen"
  t8080="$(tcp_open portquiz.net 8080)"
  t8443="$(tcp_open portquiz.net 8443)"
  t9443="$(tcp_open portquiz.net 9443)"
  t1080="$(tcp_open portquiz.net 1080)"
  t3128="$(tcp_open portquiz.net 3128)"
  t2053="$(tcp_open portquiz.net 2053)"
  quic=0; curl -4 -sS --http3-only --max-time 4 -o /dev/null https://cloudflare.com >/dev/null 2>&1 && quic=1 || true
  ip6=0; curl -6 -fsS --max-time 5 https://api64.ipify.org >/dev/null 2>&1 && ip6=1 || true
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(iso)" "$icmp" "$t80" "$t443" "$t22" "$t25" "$t465" "$t587" "$t53" "$u53" \
    "$t853" "$t8080" "$t8443" "$t9443" "$t1080" "$t3128" "$t2053" "$quic" "$ip6" >> "$PFILE"
  echo "PORTS icmp=$icmp 80=$t80 443=$t443 22=$t22 25=$t25 465=$t465 587=$t587 53t=$t53 53u=$u53 853=$t853 8080=$t8080 8443=$t8443 9443=$t9443 1080=$t1080 3128=$t3128 2053=$t2053 quic=$quic ip6=$ip6"
  local blk=""
  [ "$icmp" = 0 ] && blk="$blk ICMP"
  [ "$t80" = 0 ] && blk="$blk :80"
  [ "$t443" = 0 ] && blk="$blk :443"
  [ "$t53" = 0 ] && blk="$blk :53tcp"
  [ "$u53" = 0 ] && blk="$blk :53udp"
  [ "$t25" = 0 ] && blk="$blk :25"
  [ "$t587" = 0 ] && blk="$blk :587"
  [ -n "$blk" ] && echo "KHONG RA DUOC (thuong gap DC):$blk" && event "PORTS_BLOCK$blk"
}

cmd_once() {
  need_curl || return 1
  purge_old; ensure_hdr
  local tmp; tmp="$(mktemp -d /tmp/bwpath.XXXXXX)"
  local epoch ts pub colo ph cf_ok=1
  epoch="$(date +%s)"; ts="$(iso)"
  pub="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || curl -4 -fsS --max-time 6 https://ifconfig.me/ip 2>/dev/null || echo fail)"
  local cft; cft="$(curl -4 -fsS --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  colo="$(printf '%s\n' "$cft" | awk -F= '/^colo=/{print $2}')"
  [ -n "$colo" ] || { colo=na; cf_ok=0; }
  [ -f "$ST.ip" ] && [ "$pub" != "$(cat "$ST.ip")" ] && event "IP $pub"
  echo "$pub" > "$ST.ip"; echo "$colo" > "$ST.colo"
  if [ "${DO_TRACE:-0}" = 1 ] || [ ! -f "$ST.ph" ]; then
    ph="$(path_hash)"
    [ -f "$ST.ph" ] && [ "$ph" != "$(cat "$ST.ph")" ] && event "PATH $ph"
    echo "$ph" > "$ST.ph"
  else ph="$(cat "$ST.ph")"; fi

  local l_gg r_gg j_gg l_vn r_vn j_vn
  read -r l_gg r_gg j_gg <<<"$(ping_triple 8.8.8.8 "$tmp/pg")"
  read -r l_vn r_vn j_vn <<<"$(ping_triple 203.113.131.1 "$tmp/pv")"

  local p vn sg de fr use usw au br sgip=na deip=na useip=na
  p="$(curl_probe https://vnexpress.net/ "$tmp/h" "$tmp/b")"; vn="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe http://speedtest-sgp1.digitalocean.com/ "$tmp/h" "$tmp/b")"; sg="$(echo "$p" | awk '{print $1}')"; sgip="$(echo "$p" | awk '{print $4}')"
  p="$(curl_probe https://speed.hetzner.de/ "$tmp/h" "$tmp/b")"; de="$(echo "$p" | awk '{print $1}')"; deip="$(echo "$p" | awk '{print $4}')"
  [ "$de" = "na" ] && { p="$(curl_probe https://ftp.debian.org/debian/README "$tmp/h" "$tmp/b")"; de="$(echo "$p" | awk '{print $1}')"; deip="$(echo "$p" | awk '{print $4}')"; }
  p="$(curl_probe https://proof.ovh.net/ "$tmp/h" "$tmp/b")"; fr="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://ash-speed.hetzner.com/ "$tmp/h" "$tmp/b")"; use="$(echo "$p" | awk '{print $1}')"; useip="$(echo "$p" | awk '{print $4}')"
  p="$(curl_probe https://hil-speed.hetzner.com/ "$tmp/h" "$tmp/b")"; usw="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://mirror.aarnet.edu.au/ "$tmp/h" "$tmp/b")"; au="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://mirror.uepg.br/ "$tmp/h" "$tmp/b")"; br="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://ftp.jaist.ac.jp/ "$tmp/h" "$tmp/b")"; jp="$(echo "$p" | awk '{print $1}')"; jpip="$(echo "$p" | awk '{print $4}')"
  p="$(curl_probe https://www.bbc.co.uk/ "$tmp/h" "$tmp/b")"; uk="$(echo "$p" | awk '{print $1}')"; ukip="$(echo "$p" | awk '{print $4}')"
  printf '%s\n' "$vn $sg $sgip $jp $jpip $au $de $deip $uk $ukip $fr $use $useip $usw $br" > "$DIR/last_tcp.txt"
  echo "LAN_DO tcp_ms peer"
  echo "  VN=$vn  SG(DO)=$sg peer=$sgip  JP=$jp peer=$jpip  AU=$au"
  echo "  DE=$de peer=$deip  UK(bbc)=$uk peer=$ukip  FR=$fr"
  echo "  USE(ASH)=$use peer=$useip  USW=$usw  BR=$br"
  echo "  8.8.8.8/UL-CF = ANYCAST (khong dung lam toa do)"

  local i okc=0
  for i in 1 2 3 4; do
    ( case $((i%2)) in 0) u=https://example.com/ ;; *) u=https://www.wikipedia.org/ ;; esac
      curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 8 "$u" >"$tmp/c$i" 2>/dev/null || echo 000 >"$tmp/c$i" ) &
  done
  wait
  for i in 1 2 3 4; do case "$(cat "$tmp/c$i" 2>/dev/null)" in 2??|3??) okc=$((okc+1)) ;; esac; done
  local par=$((okc*10/4)) ok=1 dead=0
  for x in "$vn" "$sg" "$fr" "$use"; do [ "$x" = "na" ] && dead=$((dead+1)); done
  [ "$pub" = "fail" ] && ok=0
  [ "$dead" -ge 3 ] && ok=0
  [ "$ok" = 0 ] && event "BAD dead=$dead"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$epoch" "$pub" "$colo" "$ph" "$l_gg" "$r_gg" "$j_gg" "$l_vn" "$r_vn" "$j_vn" \
    "$vn" "$sg" "$de" "$fr" "$use" "$usw" "$au" "$br" "$par" "$ok" "$cf_ok" >> "$SFILE"
  rm -rf "$tmp"
  echo "$ts ok=$ok ip=$pub VN=$vn SG=$sg DE=$de FR=$fr USE=$use USW=$usw AU=$au BR=$br par=$par"
}

cmd_bw() {
  need_curl || return 1
  purge_old; ensure_hdr
  local ul=0 src=none w
  w="$(dd if=/dev/zero bs=300000 count=1 2>/dev/null | curl -4 -sS -o /dev/null --max-time 12 -X POST --data-binary @- -w '%{speed_upload} %{http_code}' https://speed.cloudflare.com/__up 2>/dev/null || echo "0 000")"
  if echo "$w" | awk '{exit !($2+0>=200 && $2+0<400 && $1+0>0)}'; then
    ul="$(echo "$w" | awk '{printf "%.2f", $1*8/1e6}')"; src=cf
  else src=cf_block; ul=0; fi
  local dl_vn dl_de dl_use dl_au dl_br
  dl_vn="$(dl_mbps "http://speedtest.hcm.fpt.vn/speedtest/random4000x4000.jpg" "$BYTES")"
  dl_de="$(dl_mbps "https://speed.hetzner.de/100MB.bin" "$BYTES")"
  awk -v x="$dl_de" 'BEGIN{exit !(x+0<1)}' && dl_de="$(dl_mbps "https://ftp.debian.org/debian/ls-lR.gz" "$BYTES")"
  dl_use="$(dl_mbps "https://ash-speed.hetzner.com/100MB.bin" "$BYTES")"
  dl_au="$(dl_mbps "https://mirror.aarnet.edu.au/" 150000)"
  dl_br="$(dl_mbps "https://mirror.uepg.br/" 150000)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(iso)" "$ul" "$src" "$dl_vn" "$dl_de" "$dl_use" "$dl_au" "$dl_br" >> "$BFILE"
  echo "bw ul=$ul($src ANYCAST-CF) vn=$dl_vn de=$dl_de(Hetzner) use=$dl_use(ASH) au=$dl_au br=$dl_br"
}

cmd_daemon() {
  echo "bwpath $VER daemon"
  local i=0
  while true; do
    cmd_once || event EXC
    i=$((i+1))
    [ $((i % BW_EVERY)) -eq 0 ] && cmd_bw || true
    [ $((i % TRACE_EVERY)) -eq 0 ] && { DO_TRACE=1 cmd_once; cmd_ports; } || true
    sleep "$INTERVAL"
  done
}

cmd_report() {
  purge_old
  echo "======== bwpath $VER REPORT  $(iso) ========"
  [ -f "$DIR/hw.txt" ] && cat "$DIR/hw.txt" || cmd_hw || true
  [ -f "$SFILE" ] || { echo "chua mau"; return 1; }
  echo "s=$(wc -l < "$SFILE") b=$([ -f "$BFILE" ] && wc -l < "$BFILE") p=$([ -f "$PFILE" ] && wc -l < "$PFILE")"
  awk -F, '
    $1=="ts"{next} NF<20{next}
    {n++; if($6+0<80){lg+=$6;nlg++} if($7+0>0){rg+=$7;nrg++; if(mn==""||$7<mn)mn=$7; if($7>mx)mx=$7}
     if($12+0>0){vn+=$12;nvn++} if($13+0>0){sg+=$13;nsg++}
     if($14+0>0){de+=$14;nde++} if($15+0>0){fr+=$15;nfr++}
     if($16+0>0){ue+=$16;nue++} if($17+0>0){uw+=$17;nuw++}
     if($18+0>0){au+=$18;nau++} if($19+0>0){br+=$19;nbr++}
     if($20+0>0){par+=$20;np++} ip[$3]++; ph[$5]++}
    END{
      if(!n){print "no v4"; exit}
      printf "n=%d loss8.8=%.2f(ANYCAST) rtt8.8=%.1f(ANYCAST) span=%.1f\n", n, nlg?lg/nlg:0, nrg?rg/nrg:0, nrg?mx-mn:0
      printf "TCP unicast VN=%.0f SG(DO)=%.0f | DE=%.0f FR=%.0f | USE(ASH)=%.0f USW=%.0f | AU=%.0f BR=%.0f par=%.1f\n",
        nvn?vn/nvn:0,nsg?sg/nsg:0,nde?de/nde:0,nfr?fr/nfr:0,nue?ue/nue:0,nuw?uw/nuw:0,nau?au/nau:0,nbr?br/nbr:0,np?par/np:0
    }
  ' "$SFILE"
  if [ -f "$BFILE" ]; then
    awk -F, '
      $1=="ts"{next}
      {n++
       if($2+0>0){u+=$2;nu++; if(umin==""||$2<umin)umin=$2; if($2>umax)umax=$2}
       if($4+0>0){v+=$4;nv++}
       if($5+0>0){d+=$5;nd++; if(dmin==""||$5<dmin)dmin=$5}
       if($6+0>0){e+=$6;ne++; if(emin==""||$6<emin)emin=$6}}
      END{
        if(!n) exit
        ua=nu?u/nu:0; da=nd?d/nd:0; ea=ne?e/ne:0
        printf "UL avg=%.1f min=%.1f (CF-anycast) n_bw=%d\n", ua, umin+0, n
        printf "DL VN=%.1f DE avg=%.1f min=%.1f US-E(ASH) avg=%.1f min=%.1f\n", nv?v/nv:0, da, dmin+0, ea, emin+0
        if(nu>=2 && ua>0) printf "FUP_UL min/avg=%.0f%% (tinh tu b.csv, khong doan ISP)\n", 100*umin/ua
        if(nd>=2 && da>0) printf "FUP_DE min/avg=%.0f%%\n", 100*dmin/da
        if(nu<2) printf "FUP: chua du mau bw (can >=2 dong b.csv)\n"
      }' "$BFILE"
  fi
  echo ""
  echo "--- CONG RA (1=ok 0=chan/timeout) ---"
  if [ -f "$PFILE" ]; then
    echo "  (dong moi nhat)"
    tail -1 "$PFILE"
    awk -F, '
      $1=="ts"{h=$0; next}
      {n++; for(i=2;i<=NF;i++) if($i=="0") z[i]++}
      END{
        if(!n) exit
        split("x icmp 80 443 22 25 465 587 53t 53u 853 8080 8443 9443 1080 3128 2053 quic ip6", name, " ")
        printf "  %d mau. Hay bi 0: ", n
        for(i=2;i<=19;i++) if(z[i]>0) printf "%s=%d ", name[i], z[i]
        print ""
      }
    ' "$PFILE"
  else echo "  chua p.csv"; fi
  echo "--- events ---"; [ -f "$EFILE" ] && tail -12 "$EFILE" || echo none
}

g_tcp() { awk -v x="$1" 'BEGIN{if(x==""||x=="na"||x+0==0||x+0>800)print "NA"; else if(x<=90)print "GOOD"; else if(x<=220)print "OK"; else print "WEAK"}'; }
g_loss() { awk -v x="$1" 'BEGIN{if(x+0>80)print "NA"; else if(x<=0.5)print "GOOD"; else if(x<=2)print "OK"; else print "WEAK"}'; }
g_mbps() { awk -v x="$1" 'BEGIN{if(x+0<=0)print "NA"; else if(x>=20)print "GOOD"; else if(x>=8)print "OK"; else print "WEAK"}'; }
g_par() { awk -v x="$1" 'BEGIN{if(x>=9)print "GOOD"; else if(x>=7)print "OK"; else print "WEAK"}'; }
g_stab() { awk -v i="$1" -v p="$2" 'BEGIN{if(i<=1&&p<=2)print "GOOD"; else if(i<=2&&p<=5)print "OK"; else print "WEAK"}'; }

cmd_fit() {
  purge_old
  echo "======== FIT $VER ========"
  [ -f "$SFILE" ] || return 1
  eval "$(awk -F, '
    $1=="ts"{next} NF<20{next}
    {n++; if($6+0<80){lg+=$6;nlg++}
     if($12+0>0){vn+=$12;nvn++} if($13+0>0){sg+=$13;nsg++}
     if($14+0>0){de+=$14;nde++} if($15+0>0){fr+=$15;nfr++}
     if($16+0>0){ue+=$16;nue++} if($17+0>0){uw+=$17;nuw++}
     if($18+0>0){au+=$18;nau++} if($19+0>0){br+=$19;nbr++}
     if($20+0>0){par+=$20;np++} ip[$3]++; ph[$5]++}
    END{if(!n){print "HAVE=0"; exit}
      printf "HAVE=1\nN=%d\nLOSS=%.3f\nVN=%.1f\nSG=%.1f\nDE=%.1f\nFR=%.1f\nUSE=%.1f\nUSW=%.1f\nAU=%.1f\nBR=%.1f\nPAR=%.1f\n",
        n,nlg?lg/nlg:999,nvn?vn/nvn:0,nsg?sg/nsg:0,nde?de/nde:0,nfr?fr/nfr:0,nue?ue/nue:0,nuw?uw/nuw:0,nau?au/nau:0,nbr?br/nbr:0,np?par/np:0
      ni=0;for(k in ip)ni++; nh=0;for(k in ph)nh++; printf "N_IP=%d\nN_PATH=%d\n",ni,nh}
  ' "$SFILE")"
  [ "${HAVE:-0}" = 1 ] || return 1
  UL=0
  [ -f "$BFILE" ] && eval "$(awk -F, '$1=="ts"{next}{if($2+0>0){u+=$2;nu++}} END{printf "UL=%.2f\n",nu?u/nu:0}' "$BFILE")"
  echo "n=$N loss=$LOSS VN=$VN SG=$SG DE=$DE FR=$FR USE=$USE USW=$USW AU=$AU BR=$BR par=$PAR ul=$UL"
  G_LOSS="$(g_loss "$LOSS")"; G_VN="$(g_tcp "$VN")"; G_SG="$(g_tcp "$SG")"
  G_DE="$(g_tcp "$DE")"; G_FR="$(g_tcp "$FR")"; G_USE="$(g_tcp "$USE")"; G_USW="$(g_tcp "$USW")"
  G_AU="$(g_tcp "$AU")"; G_BR="$(g_tcp "$BR")"; G_UL="$(g_mbps "$UL")"; G_PAR="$(g_par "$PAR")"
  G_STAB="$(g_stab "$N_IP" "$N_PATH")"
  fit() {
    local name="$1" need="$2" why="$3" worst="GOOD" v d
    local IFS=','
    for d in $need; do
      case "$d" in
        loss) v="$G_LOSS" ;; vn) v="$G_VN" ;; sg) v="$G_SG" ;; de) v="$G_DE" ;; fr) v="$G_FR" ;;
        use) v="$G_USE" ;; usw) v="$G_USW" ;; au) v="$G_AU" ;; br) v="$G_BR" ;; ul) v="$G_UL" ;;
        par) v="$G_PAR" ;; stab) v="$G_STAB" ;; *) v="OK" ;;
      esac
      [ "$v" = "WEAK" ] && worst="WEAK"
      [ "$v" = "OK" ] && [ "$worst" = "GOOD" ] && worst="OK"
      [ "$v" = "NA" ] && [ "$worst" != "WEAK" ] && worst="OK"
    done
    local lab; case "$worst" in GOOD) lab="KHOP tot" ;; OK) lab="KHOP TB" ;; WEAK) lab="LECH" ;; esac
    printf "  %-18s %-10s %s\n" "$name" "$lab" "$why"
  }
  fit "Honeygain-proxy" "ul,par,stab,sg" "A"
  fit "Honeygain-CDN" "ul,de,use" "B"
  fit "Wipter" "ul,par,vn,sg,fr,use" "A+B"
  fit "EarnApp" "ul,par,use,fr,stab" "US/EU"
  fit "PacketStream" "ul,par,stab" "A"
  fit "EarnFM" "ul,sg" "A"
  fit "Pawns" "ul,stab,sg" "sticky"
  fit "Proxyrack" "ul,par,stab" "thread"
  fit "Traffmo" "ul,sg" "A"
  fit "Bitping" "loss,stab" "C"
  fit "Grass" "stab" "C"
  fit "Myst" "loss,stab" "UDP/tunnel — xem p.csv 53u/quic"
}

cmd_risk() {
  echo "======== CHECKLIST $VER ========"
  [ -f "$SFILE" ] || return 1
  awk -F, '
    function tag(ms,n){if(n<1||ms+0<=0)return "NA"; if(ms<=90)return "TOT"; if(ms<=220)return "OK"; if(ms<=350)return "YEU"; return "LOI"}
    $1=="ts"{next} NF<20{next}
    {n++; if($6+0<80){lg+=$6;nlg++} if($7+0>0){if(mn==""||$7<mn)mn=$7; if($7>mx)mx=$7; nrg++}
     if($12+0>0){vn+=$12;nvn++} if($13+0>0){sg+=$13;nsg++}
     if($14+0>0){de+=$14;nde++} if($15+0>0){fr+=$15;nfr++}
     if($16+0>0){ue+=$16;nue++} if($17+0>0){uw+=$17;nuw++}
     if($18+0>0){au+=$18;nau++} if($19+0>0){br+=$19;nbr++} ip[$3]++}
    END{
      st=(n<8)?"TAM":"OK"; loss=nlg?lg/nlg:0; span=nrg?mx-mn:0
      if(loss>2||span>70) st="LOI"; else if(loss>0.5||span>25) if(st!="TAM") st="YEU"
      printf "[ON DINH] %-4s loss=%.2f span=%.0f n=%d\n",st,loss,span,n
      printf "[A]       %-4s VN=%.0f SG=%.0f\n", tag(nvn?vn/nvn:0,nvn), nvn?vn/nvn:0,nsg?sg/nsg:0
      printf "[EU]      %-4s DE=%.0f FR=%.0f\n", tag(nfr?fr/nfr:0,nfr+nde), nde?de/nde:0,nfr?fr/nfr:0
      printf "[BAC MY]  %-4s E=%.0f W=%.0f\n", tag(nue?ue/nue:0,nue), nue?ue/nue:0,nuw?uw/nuw:0
      printf "[UC]      %-4s AU=%.0f\n", tag(nau?au/nau:0,nau), nau?au/nau:0
      printf "[NAM MY]  %-4s BR=%.0f\n", tag(nbr?br/nbr:0,nbr), nbr?br/nbr:0
    }
  ' "$SFILE"
  if [ -f "$PFILE" ]; then
    echo "[CONG] dong cuoi: $(tail -1 "$PFILE")"
    echo "  80+443=web/proxy  53u=DNS  25/587=SMTP (DC hay chan, it anh huong BW-share)"
    echo "  1080/3128/2053=cong proxy/controller  quic=HTTP3  ip6=IPv6"
  fi
}

cmd_map() {
  echo "======== VUNG MAY (gan -> xa, chi so) ========"
  local cc="" city="" cont="" 
  if [ -f "$DIR/hw.txt" ]; then
    cc="$(sed -n 's/.*"country":"\([^"]*\)".*/\1/p' "$DIR/hw.txt" | head -1)"
    city="$(sed -n 's/.*"city":"\([^"]*\)".*/\1/p' "$DIR/hw.txt" | head -1)"
    cont="$(sed -n 's/.*"continent":"\([^"]*\)".*/\1/p' "$DIR/hw.txt" | head -1)"
  fi
  echo "  IP_o: country=${cc:-?} city=${city:-?} continent=${cont:-?}"
  echo "  Thu tu: vung may truoc, roi vong ra (SEA/AU/EU/UK/NA/SA tuy noi dat)."
  [ -f "$SFILE" ] || return 0
  awk -F, -v cc="$cc" -v cont="$cont" '
    $1=="ts"{next} NF<20{next}
    {n++
     if($6+0<80){lg+=$6;nlg++}
     if($7+0>0){rg+=$7;nrg++; if(mn==""||$7<mn)mn=$7; if($7>mx)mx=$7}
     if($12+0>0){vn+=$12;nvn++} if($13+0>0){sg+=$13;nsg++}
     if($14+0>0){de+=$14;nde++} if($15+0>0){fr+=$15;nfr++}
     if($16+0>0){ue+=$16;nue++} if($17+0>0){uw+=$17;nuw++}
     if($18+0>0){au+=$18;nau++} if($19+0>0){br+=$19;nbr++}
     if($20+0>0){par+=$20;np++}}
    END{
      if(!n){print "  chua mau tcp"; exit}
      vn=nvn?vn/nvn:0; sg=nsg?sg/nsg:0; de=nde?de/nde:0; fr=nfr?fr/nfr:0
      ue=nue?ue/nue:0; uw=nuw?uw/nuw:0; au=nau?au/nau:0; br=nbr?br/nbr:0
      loss=nlg?lg/nlg:0; rtt=nrg?rg/nrg:0; span=nrg?mx-mn:0
      sea=(cc=="Vietnam"||cc=="Singapore"||cc=="Thailand"||cc=="Malaysia"||cc=="Indonesia"||cc=="Cambodia"||cc=="Laos"||cc=="Philippines")
      nam=(cc=="Canada"||cc=="United States"||cont=="North America")
      print "  -- GAN MAY --"
      if(sea){
        printf "  VN tcp_ms=%.0f  SG(DO) tcp_ms=%.0f  (SEA)\n", vn, sg
      } else if(nam){
        printf "  USE(ASH) tcp_ms=%.0f  USW tcp_ms=%.0f  (Bac My)\n", ue, uw
      } else {
        printf "  DE tcp_ms=%.0f  FR tcp_ms=%.0f  USE tcp_ms=%.0f\n", de, fr, ue
      }
      print "  -- XA DAN --"
      if(sea){
        printf "  AU=%.0f  DE=%.0f  FR=%.0f  USE=%.0f  USW=%.0f  BR=%.0f\n", au,de,fr,ue,uw,br
      } else if(nam){
        printf "  FR=%.0f  DE=%.0f (xem peer, 8ms+Fastly khong phai DE)  VN=%.0f  SG=%.0f  AU=%.0f  BR=%.0f\n", fr,de,vn,sg,au,br
      } else {
        printf "  VN=%.0f  SG=%.0f  AU=%.0f  USW=%.0f  BR=%.0f\n", vn,sg,au,uw,br
      }
      printf "  -- ON DINH (so, khong diem) --\n"
      printf "  n_tcp=%d  loss8.8=%.2f%%  rtt8.8=%.1fms  span=%.1fms  par=%.1f\n", n, loss, rtt, span, np?par/np:0
    }
  ' "$SFILE"
  if [ -f "$DIR/last_tcp.txt" ]; then
    echo "  -- LAN VUA DO (co JP/UK + peer) --"
    echo "  $(cat "$DIR/last_tcp.txt")"
  fi
}


cmd_tun() {
  echo "======== TUN THUC (docker tren may nay) ========"
  echo "  Khong probe qua docker. Chi liet ke container dang co."
  if ! have docker; then echo "  khong co docker"; return 0; fi
  if ! docker info >/dev/null 2>&1; then echo "  docker daemon khong doc duoc"; return 0; fi
  echo "  -- ps (name status restart ports) --"
  docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null | head -80
  echo "  -- stats 1 lan (CPU% MEM) --"
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.PIDs}}' 2>/dev/null | head -80
  echo "  -- ten tun* --"
  docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -E '^tun' || echo "  (khong ten tun*)"
}


cmd_cap() {
  echo "======== SUC GANH / ON DINH $VER ========"
  echo "  Cong thuc tu so do MAY (UL, RAM, load). Khong do tung TUN."
  local ul=0 mem avail ncpu load1 ntun=0 nall=0 napps=0
  mem="$(awk '/MemTotal/{printf "%.0f",$2/1024}' /proc/meminfo)"
  avail="$(awk '/MemAvailable/{printf "%.0f",$2/1024}' /proc/meminfo)"
  ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  load1="$(awk '{print $1}' /proc/loadavg)"
  [ -f "$BFILE" ] && ul="$(awk -F, '$1!="ts"&&$2+0>0{u+=$2;n++} END{if(n) printf "%.2f",u/n; else print 0}' "$BFILE")"
  if have docker; then
    ntun="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE '^tun' || true)"
    nall="$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')"
    napps=$(( nall - ntun ))
    (( napps < 0 )) && napps=0
  fi
  local ntcp=0 loss=0 span=0
  if [ -f "$SFILE" ]; then
    eval "$(awk -F, '
      $1=="ts"{next} NF<20{next}
      {n++; if($6+0<80){lg+=$6;nlg++} if($7+0>0){if(mn==""||$7<mn)mn=$7; if($7>mx)mx=$7; nrg++}}
      END{printf "ntcp=%d loss=%.3f span=%.1f\n", n, nlg?lg/nlg:0, nrg?mx-mn:0}
    ' "$SFILE")"
  fi
  # UL: 1 app ~0.7Mbps/TUN, 2~1.1, 3~1.5 (cung 1 ong host)
  # RAM: tru OS 300 neu <2G else 800; 1app 70MB, 2=110, 3=150 / TUN
  # CPU: ~8/5/4 TUN moi vCPU
  local reserve=800
  (( mem < 2000 )) && reserve=300
  local ramfree=$(( mem - reserve ))
  (( ramfree < 80 )) && ramfree=80
  tun_ul()  { awk -v u="$ul" -v p="$1" 'BEGIN{if(u+0<=0){print 0; exit} printf "%d", int(u/p)}'; }
  tun_ram() { awk -v r="$ramfree" -v m="$1" 'BEGIN{printf "%d", int(r/m)}'; }
  tun_cpu() { awk -v c="$ncpu" -v k="$1" 'BEGIN{printf "%d", int(c*k)}'; }
  local u1 u2 u3 r1 r2 r3 c1 c2 c3 t1 t2 t3
  u1="$(tun_ul 0.7)"; u2="$(tun_ul 1.1)"; u3="$(tun_ul 1.5)"
  r1="$(tun_ram 70)"; r2="$(tun_ram 110)"; r3="$(tun_ram 150)"
  c1="$(tun_cpu 8)"; c2="$(tun_cpu 5)"; c3="$(tun_cpu 4)"
  min3() { awk -v a="$1" -v b="$2" -v c="$3" 'BEGIN{m=a; if(b<m)m=b; if(c<m)m=c; if(m<0)m=0; print m}'; }
  if awk -v u="$ul" 'BEGIN{exit !(u+0<=0)}'; then
    t1="$(min3 9999 "$r1" "$c1")"
    t2="$(min3 9999 "$r2" "$c2")"
    t3="$(min3 9999 "$r3" "$c3")"
    u1=chua_do; u2=chua_do; u3=chua_do
  else
    t1="$(min3 "$u1" "$r1" "$c1")"
    t2="$(min3 "$u2" "$r2" "$c2")"
    t3="$(min3 "$u3" "$r3" "$c3")"
  fi
  echo "  DO (so may): UL_tb=${ul}Mbps  RAM=${mem}MB avail=${avail}MB  ncpu=${ncpu}  load1=${load1}"
  echo "  DO (so may): n_tcp=${ntcp:-0}  loss8.8=${loss:-?}  span_ms=${span:-?}  (n_tcp<8 = chua du mau)"
  echo "  DO (docker): run=${nall}  tun=${ntun}  app_khac_tun=${napps}"
  echo "  CONG THUC (KHONG do tung TUN; 0.7/1.1/1.5 Mbps va 70/110/150MB la he so, khong phai so do):"
  echo "    1 app/TUN:  ${t1}   (UL ${u1} / RAM ${r1} / CPU ${c1})"
  echo "    2 app/TUN:  ${t2}   (UL ${u2} / RAM ${r2} / CPU ${c2})"
  echo "    3 app/TUN:  ${t3}   (UL ${u3} / RAM ${r3} / CPU ${c3})"
}


cmd_ket() {
  echo "======== KET LUAN ========"
  local cc="" ul=0 nbw=0 dlvn=0 dluse=0 dlde=0
  [ -f "$DIR/hw.txt" ] && cc="$(sed -n 's/.*"country":"\([^"]*\)".*/\1/p' "$DIR/hw.txt" | head -1)"
  [ -f "$BFILE" ] && eval "$(awk -F, '
    $1=="ts"{next}
    {n++; if($2+0>0){u+=$2;nu++} if($4+0>0){v+=$4;nv++} if($5+0>0){d+=$5;nd++} if($6+0>0){e+=$6;ne++}}
    END{printf "ul=%.1f nbw=%d dlvn=%.1f dlde=%.1f dluse=%.1f\n", nu?u/nu:0,n, nv?v/nv:0, nd?d/nd:0, ne?e/ne:0}
  ' "$BFILE")"
  local vn=na use=na usw=na fr=na
  if [ -f "$DIR/last_tcp.txt" ]; then
    vn="$(awk '{print $1}' "$DIR/last_tcp.txt")"
    use="$(awk '{print $12}' "$DIR/last_tcp.txt")"
    usw="$(awk '{print $14}' "$DIR/last_tcp.txt")"
    fr="$(awk '{print $11}' "$DIR/last_tcp.txt")"
  fi
  local ntun=0
  have docker && ntun="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE '^tun' || true)"
  local ipok=""
  case "$cc" in
    Vietnam) ipok="IP Viet Nam" ;;
    Canada|"United States") ipok="IP My/Canada" ;;
    *) ipok="IP cung noi dat may" ;;
  esac
  echo "  May: ${cc:-?}  →  dung $ipok"
  echo "  --- Toc do ---"
  echo "  Len (upload):     ${ul} Mbps"
  if [ "$cc" = Vietnam ]; then
    echo "  Tai trong nuoc:   ${dlvn} Mbps   (0 = file do hong, khong phai het mang)"
    echo "  Tai ra My:        ${dluse} Mbps"
  else
    echo "  Tai My (ASH):     ${dluse} Mbps"
    echo "  Tai DE (tham khao): ${dlde} Mbps"
  fi
  echo "  --- Do tre (bat tay, ms) ---"
  if [ "$cc" = Vietnam ]; then
    echo "  Cung khu VN:      ${vn} ms"
    echo "  Ra My:            ${use} ms    Ra FR: ${fr} ms"
  else
    echo "  Cung khu My:      ${use} ms (dong)   ${usw} ms (tay)"
    echo "  Ra VN:            ${vn} ms    Ra FR: ${fr} ms"
  fi
  if awk -v n="$nbw" 'BEGIN{exit !(n+0<2)}'; then
    echo "  Bop mang: CHUA BIET (moi do toc do 1 lan, de them vai gio)"
  else
    echo "  Bop mang: xem dong FUP_UL ben duoi (nhieu lan do)"
  fi
  echo "  Ong TUN: $ntun"
  if awk -v u="$ul" -v o="$ntun" 'BEGIN{exit !(u+0>0 && o+0>0 && u/o<0.15)}'; then
    echo "  Ganh: MONG — nhieu ong chung duong len. Them IP: khong."
  else
    echo "  Ganh: chua thay ket. Them IP: chi $ipok."
  fi
}


cmd_xung() {
  echo "======== XUNG DOT CUNG IP ========"
  if ! have docker || ! docker info >/dev/null 2>&1; then echo "  khong doc duoc docker"; return 0; fi
  docker ps --format '{{.Names}}' 2>/dev/null | awk '
    {
      n=tolower($0)
      app="x"
      if (n ~ /pawns/) app="Pawns"
      else if (n ~ /packetstream/) app="PS"
      else if (n ~ /traffmon/) app="Traffmo"
      else if (n ~ /earnfm/) app="EarnFM"
      else if (n ~ /bitping/) app="Bitping"
      else if (n ~ /honeygain/) app="HG"
      else if (n ~ /earnapp/) app="EarnApp"
      else next
      if (match($0, /[0-9a-f]{10,}/)) suf=substr($0, RSTART, 16)
      else suf="host"
      g[suf]=g[suf] "," app
    }
    END{
      ok=0; bad=0; host=""
      for (s in g) {
        line=g[s]
        if (line ~ /Pawns/ && line ~ /PS/) { bad++; bd=bd " Pawns+PS" }
        nP=gsub(/Pawns/,"Pawns",line); if (nP>1) { bad++; bd=bd " 2xPawns" }
        nS=gsub(/PS/,"PS",line); if (nS>1) { bad++; bd=bd " 2xPS" }
        if (line ~ /Pawns/ && line ~ /Traffmo/ && line !~ /PS/) ok++
        if (line ~ /EarnFM/ || (line ~ /Bitping/ && line ~ /Traffmo/ && line !~ /Pawns/)) host="co"
      }
      if (bad) print "  XUNG DOT:" bd
      else print "  XUNG DOT: khong (Pawns+PS / trung app)"
      if (ok) print "  " ok " ong: Traffmo + Pawns (thuong OK)"
      if (host=="co") print "  IP may (khong TUN): EarnFM/Bitping/Traffmo — IP Oracle"
      print "  1 IP = 1 Pawns hoac 1 PacketStream, khong ca hai."
    }
  '
}


cmd_uninstall() {
  [ "$(id -u)" -eq 0 ] || return 1
  have systemctl && { systemctl disable --now bwpath.service 2>/dev/null || true; rm -f /etc/systemd/system/bwpath.service; }
  rm -f /etc/cron.d/bwpath /usr/local/bin/bwpath
  echo "Da go"
}

case "${1:-auto}" in
  auto|"") cmd_auto ;;
  --version|-V) echo "$VER" ;;
  1|once) cmd_once ;;
  2|bw) cmd_bw ;;
  ports) cmd_ports ;;
  3|report) cmd_report ;;
  4|fit) cmd_fit; cmd_risk; cmd_cap ;;
  risk) cmd_risk ;;
  cap) cmd_cap ;;
  tun) cmd_tun ;;
  ket) cmd_ket ;;
  xung) cmd_xung ;;
  5|install) cmd_install ;;
  6|uninstall) cmd_uninstall ;;
  7|purge) purge_old; echo purged ;;
  reset) reset_series; echo reset ;;
  daemon) cmd_daemon ;;
  *) echo "sudo bash $SELF" ;;
esac

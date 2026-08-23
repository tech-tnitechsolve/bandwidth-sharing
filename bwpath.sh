#!/usr/bin/env bash
# bwpath.sh v4 — mot file, mot lenh: sudo bash bwpath.sh
# Do path VN + SG + EU + NA + AU + SA. Khong lay CF anycast lam "quoc te".
# CF bi chan/challenge -> bo qua CF, van do origin unicast.
set -u
export LC_ALL=C LANG=C
VER="4.0.0"

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
EFILE="$DIR/e.log"
ST="$DIR/.st"

have() { command -v "$1" >/dev/null 2>&1; }
iso() { date -Is 2>/dev/null || date; }

need_curl() { have curl || { echo "Thieu curl — sudo bash $SELF"; return 1; }; }

is_installed() {
  [ -x /usr/local/bin/bwpath ] || [ -x "$PREFIX/bwpath.sh" ] || return 1
  { have systemctl && [ -f /etc/systemd/system/bwpath.service ]; } && return 0
  [ -f /etc/cron.d/bwpath ] && return 0
  return 1
}
svc_active() { have systemctl && systemctl is-active --quiet bwpath.service 2>/dev/null; }

ensure_pkgs() {
  have curl && have ping && return 0
  [ "$(id -u)" -eq 0 ] || return 1
  echo "[bwpath] cai goi thieu..."
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl iputils-ping traceroute iproute2 ca-certificates >/dev/null
  elif have dnf; then dnf install -y -q curl iputils traceroute iproute ca-certificates >/dev/null
  elif have yum; then yum install -y -q curl iputils traceroute iproute ca-certificates >/dev/null
  elif have apk; then apk add --no-cache curl iputils traceroute iproute2 ca-certificates >/dev/null
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
Description=bwpath path quality 7d
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/bwpath daemon
Restart=always
RestartSec=20
Environment=BWPATH_DIR=${DIR}
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now bwpath.service
    echo "OK systemd bwpath.service $VER"
  else
    printf '%s\n' "*/5 * * * * BWPATH_DIR=${DIR} /usr/local/bin/bwpath once >/dev/null 2>&1" \
      "17 * * * * BWPATH_DIR=${DIR} /usr/local/bin/bwpath bw >/dev/null 2>&1" > /etc/cron.d/bwpath
    chmod 644 /etc/cron.d/bwpath
    echo "OK cron $VER"
  fi
}

ensure_install() {
  ensure_pkgs || true
  if [ "$(id -u)" -ne 0 ]; then
    is_installed || exec sudo -E bash "$SELF"
    return 0
  fi
  if ! is_installed; then
    echo "[bwpath] chua cai — cai $VER"
    cmd_install
    return 0
  fi
  # da cai: cap nhat file neu khac version, khong cai service lan 2
  local old="?"
  old="$("$PREFIX/bwpath.sh" --version 2>/dev/null || echo "?")"
  install_files
  if [ "$old" != "$VER" ]; then
    echo "[bwpath] cap nhat $old -> $VER, restart daemon"
    have systemctl && systemctl restart bwpath.service 2>/dev/null || true
  else
    echo "[bwpath] da cai $VER — khong cai lai"
    svc_active || { echo "[bwpath] start daemon"; systemctl start bwpath.service 2>/dev/null || true; }
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

cmd_auto() {
  echo "======== bwpath $VER AUTO  $(iso) ========"
  if [ "$(id -u)" -ne 0 ] && ! is_installed; then
    have sudo && exec sudo -E bash "$SELF"
    echo "Can: sudo bash $SELF"; exit 1
  fi
  [ "$(id -u)" -eq 0 ] && ensure_install
  echo "[bwpath] do socket cac chau (unicast, khong tin CF)..."
  cmd_once || true
  if bw_recent; then echo "[bwpath] bo qua bw (<50 phut, tranh an line)"
  else echo "[bwpath] do Mbps nhe..."; cmd_bw || true; fi
  echo ""; cmd_report || true
  echo ""; cmd_fit || true
  echo ""; cmd_risk || true
  echo ""
  echo "Daemon: $(svc_active && echo DANG CHAY || echo ?). Log $DIR"
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
  _trim "$SFILE" 1; _trim "$BFILE" 1; _trim "$EFILE" 0
  for f in "$SFILE" "$BFILE" "$EFILE"; do
    [ -f "$f" ] || continue
    local n; n="$(wc -l < "$f")"
    if [ "$n" -gt 2300 ]; then
      if [ "$f" = "$EFILE" ]; then tail -n 2000 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      else { head -1 "$f"; tail -n 2000 "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"; fi
    fi
  done
}
event() { printf '%s %s\n' "$(iso)" "$*" >> "$EFILE"; }

# s.csv v4: them cot vung. Dong cu (18 cot) van doc duoc.
HDR_S="ts,epoch,ip,cf,ph,l_gg,r_gg,j_gg,l_vn,r_vn,j_vn,tcp_vn,tcp_sg,tcp_de,tcp_fr,tcp_use,tcp_usw,tcp_au,tcp_br,par,ok,cf_ok"
HDR_B="ts,ul,ul_src,dl_vn,dl_de,dl_use,dl_au,dl_br"

ensure_hdr() {
  mkdir -p "$DIR"
  if [ ! -f "$SFILE" ]; then echo "$HDR_S" > "$SFILE"
  elif ! head -1 "$SFILE" | grep -q 'tcp_au'; then
    mv "$SFILE" "$SFILE.v3.bak" 2>/dev/null || true
    echo "$HDR_S" > "$SFILE"
    echo "[bwpath] schema s.csv v4 (giu $SFILE.v3.bak)"
  fi
  if [ ! -f "$BFILE" ]; then echo "$HDR_B" > "$BFILE"
  elif ! head -1 "$BFILE" | grep -q 'dl_au'; then
    mv "$BFILE" "$BFILE.v3.bak" 2>/dev/null || true
    echo "$HDR_B" > "$BFILE"
  fi
}

# chi lay SO loss — bug cu: tr -d % de ra "25 packet loss"
ping_triple() {
  local host="$1" f="$2"
  if ping -4 -c "$PING_N" -W 2 -i 0.25 "$host" >"$f" 2>/dev/null \
     || ping -c "$PING_N" -W 2 "$host" >"$f" 2>/dev/null; then
    local loss avg mdev
    loss="$(awk '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /%/){gsub("%","",$i); print $i; exit}}' "$f")"
    avg="$(awk -F'[/ ]' '/rtt min|round-trip/{
      for(i=1;i<=NF;i++) if($i+0>0){a[++n]=$i}
      if(n>=3) print a[2]
    }' "$f")"
    mdev="$(awk -F'[/ ]' '/rtt min|round-trip/{
      for(i=1;i<=NF;i++) if($i+0>0){a[++n]=$i}
      if(n>=4) print a[4]
    }' "$f")"
    echo "${loss:-100} ${avg:-na} ${mdev:-na}"
  else
    echo "100 na na"
  fi
}

# curl probe: connect_ms http_code cf_block(0/1)  — CF challenge van co TCP
# ta tach: http 403/503 + header cf-ray + server cloudflare = block ung dung, TCP van OK
curl_probe() {
  local url="$1" hdr="$2" body="$3"
  local w
  w="$(curl -4 -sS -D "$hdr" -o "$body" --max-time 10 \
        -w '%{time_connect} %{http_code}' "$url" 2>/dev/null || echo "0 000")"
  local tc code
  tc="$(echo "$w" | awk '{print $1}')"
  code="$(echo "$w" | awk '{print $2}')"
  local cf=0
  if grep -qiE '^server:[[:space:]]*cloudflare' "$hdr" 2>/dev/null; then
    case "$code" in 403|429|503|5??) cf=1 ;; esac
    grep -qi 'just a moment\|cf-mitigated\|attention required' "$body" 2>/dev/null && cf=1
  fi
  local ms
  if awk -v t="$tc" 'BEGIN{exit !(t+0>0)}'; then
    ms="$(awk -v t="$tc" 'BEGIN{printf "%.1f", t*1000}')"
  else
    ms="na"
  fi
  echo "$ms $code $cf"
}

num_or_na() { case "${1:-}" in ""|na|0.0) echo na ;; *) echo "$1" ;; esac; }

path_hash() {
  local out="na"
  have traceroute && out="$(traceroute -4 -n -w 1 -q 1 -m 5 8.8.8.8 2>/dev/null | awk 'NR>1{print $2}' | tr '\n' ',')"
  if have sha1sum; then printf '%s' "$out" | sha1sum | awk '{print substr($1,1,10)}'
  else printf '%s' "$out" | wc -c; fi
}

dl_mbps() {
  local url="$1" bytes="${2:-$BYTES}" w
  w="$(curl -4 -o /dev/null -sS --max-time 16 -r "0-$((bytes-1))" -w '%{speed_download} %{http_code}' "$url" 2>/dev/null || echo "0 000")"
  local spd code
  spd="$(echo "$w" | awk '{print $1}')"
  code="$(echo "$w" | awk '{print $2}')"
  case "$code" in 200|206) awk -v b="$spd" 'BEGIN{printf "%.2f", b*8/1e6}' ;; *) echo 0 ;; esac
}

cmd_once() {
  need_curl || return 1
  purge_old; ensure_hdr
  local tmp; tmp="$(mktemp -d /tmp/bwpath.XXXXXX)"
  local epoch ts pub colo ph cf_ok=1
  epoch="$(date +%s)"; ts="$(iso)"
  pub="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null \
        || curl -4 -fsS --max-time 6 https://ifconfig.me/ip 2>/dev/null || echo fail)"
  # CF colo: that bai / challenge -> na, KHONG danh BAD
  local cft
  cft="$(curl -4 -fsS --max-time 5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
  colo="$(printf '%s\n' "$cft" | awk -F= '/^colo=/{print $2}')"
  if [ -z "$colo" ]; then colo="na"; cf_ok=0; fi

  [ -f "$ST.ip" ] && [ "$pub" != "$(cat "$ST.ip")" ] && event "IP $pub"
  [ -f "$ST.colo" ] && [ "$colo" != "$(cat "$ST.colo")" ] && [ "$colo" != "na" ] && event "COLO $colo"
  echo "$pub" > "$ST.ip"; echo "$colo" > "$ST.colo"
  if [ "${DO_TRACE:-0}" = 1 ] || [ ! -f "$ST.ph" ]; then
    ph="$(path_hash)"
    [ -f "$ST.ph" ] && [ "$ph" != "$(cat "$ST.ph")" ] && event "PATH $ph"
    echo "$ph" > "$ST.ph"
  else ph="$(cat "$ST.ph")"; fi

  # loss: 8.8.8.8 (unicast-anycast Google) — khong dung 1.1.1.1 lam chuan on dinh
  local l_gg r_gg j_gg l_vn r_vn j_vn
  read -r l_gg r_gg j_gg <<<"$(ping_triple 8.8.8.8 "$tmp/pg")"
  read -r l_vn r_vn j_vn <<<"$(ping_triple 203.113.131.1 "$tmp/pv")"

  # TCP unicast / origin theo CHAU
  local p vn sg de fr use usw au br
  p="$(curl_probe https://vnexpress.net/ "$tmp/h" "$tmp/b")"; vn="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://www.google.com.sg/ "$tmp/h" "$tmp/b")"; sg="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://speed.hetzner.de/ "$tmp/h" "$tmp/b")"; de="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://proof.ovh.net/ "$tmp/h" "$tmp/b")"; fr="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://ash-speed.hetzner.com/ "$tmp/h" "$tmp/b")"; use="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://hil-speed.hetzner.com/ "$tmp/h" "$tmp/b")"; usw="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://mirror.aarnet.edu.au/ "$tmp/h" "$tmp/b")"; au="$(echo "$p" | awk '{print $1}')"
  p="$(curl_probe https://www.uol.com.br/ "$tmp/h" "$tmp/b")"; br="$(echo "$p" | awk '{print $1}')"

  # song song: KHONG dung CF.  wikipedia + example + hetzner DE
  local i okc=0
  for i in 1 2 3 4 5 6; do
    (
      case $((i % 3)) in
        0) u=https://example.com/ ;;
        1) u=https://www.wikipedia.org/ ;;
        2) u=https://speed.hetzner.de/ ;;
      esac
      c="$(curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || echo 000)"
      echo "$c" > "$tmp/c$i"
    ) &
  done
  wait
  for i in 1 2 3 4 5 6; do
    c="$(cat "$tmp/c$i" 2>/dev/null || echo 000)"
    case "$c" in 2??|3??) okc=$((okc+1)) ;; esac
  done
  local par=$((okc * 10 / 6))

  local ok=1
  # BAD: mat IP hoac mat nhieu vung (khong phat BAD chi vi CF)
  local dead=0
  for x in "$vn" "$sg" "$de" "$use"; do
    [ "$x" = "na" ] && dead=$((dead+1))
  done
  [ "$pub" = "fail" ] && ok=0
  [ "$dead" -ge 3 ] && ok=0
  echo "$l_gg" | grep -Eq '^[0-9]' && awk -v l="$l_gg" 'BEGIN{exit !(l+0>=20)}' && ok=0
  [ "$ok" = 0 ] && event "BAD dead=$dead loss_gg=$l_gg par=$par cf_ok=$cf_ok"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$epoch" "$pub" "$colo" "$ph" \
    "$l_gg" "$r_gg" "$j_gg" "$l_vn" "$r_vn" "$j_vn" \
    "$vn" "$sg" "$de" "$fr" "$use" "$usw" "$au" "$br" \
    "$par" "$ok" "$cf_ok" >> "$SFILE"
  rm -rf "$tmp"
  echo "$ts ok=$ok ip=$pub cf=$colo/$cf_ok VN=$vn SG=$sg DE=$de FR=$fr US-E=$use US-W=$usw AU=$au BR=$br par=$par/10"
}

cmd_bw() {
  need_curl || return 1
  purge_old; ensure_hdr
  local ul=0 src=none
  # upload: CF truoc, fail -> skip (khong gia Mbps)
  local w
  w="$(dd if=/dev/zero bs=300000 count=1 2>/dev/null | curl -4 -sS -o /dev/null --max-time 12 \
        -X POST --data-binary @- -w '%{speed_upload} %{http_code}' https://speed.cloudflare.com/__up 2>/dev/null || echo "0 000")"
  if echo "$w" | awk '{exit !($2+0>=200 && $2+0<400 && $1+0>0)}'; then
    ul="$(echo "$w" | awk '{printf "%.2f", $1*8/1e6}')"; src=cf
  else
    src=cf_block
    ul=0
  fi
  local dl_vn dl_de dl_use dl_au dl_br
  dl_vn="$(dl_mbps "http://speedtest.hcm.fpt.vn/speedtest/random4000x4000.jpg" "$BYTES")"
  awk -v x="$dl_vn" 'BEGIN{exit !(x+0<1)}' && dl_vn="$(dl_mbps "https://vnexpress.net/" 400000)"
  dl_de="$(dl_mbps "https://speed.hetzner.de/100MB.bin" "$BYTES")"
  dl_use="$(dl_mbps "https://ash-speed.hetzner.com/100MB.bin" "$BYTES")"
  dl_au="$(dl_mbps "https://mirror.aarnet.edu.au/pub/ubuntu/releases/24.04/SHA256SUMS" 400000)"
  dl_br="$(dl_mbps "https://www.uol.com.br/" 400000)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(iso)" "$ul" "$src" "$dl_vn" "$dl_de" "$dl_use" "$dl_au" "$dl_br" >> "$BFILE"
  echo "bw ul=$ul($src) vn=$dl_vn de=$dl_de use=$dl_use au=$dl_au br=$dl_br"
}

cmd_daemon() {
  echo "bwpath $VER daemon ${INTERVAL}s $DIR"
  local i=0
  while true; do
    cmd_once || event EXC
    i=$((i+1))
    [ $((i % BW_EVERY)) -eq 0 ] && cmd_bw || true
    [ $((i % TRACE_EVERY)) -eq 0 ] && DO_TRACE=1 cmd_once || true
    sleep "$INTERVAL"
  done
}

# doc ca schema v4; bo qua gia tri na / 0 vo nghia
cmd_report() {
  purge_old
  echo "======== bwpath $VER REPORT  $(iso) ========"
  echo "dir=$DIR  (CF chi la ghi chu; chuan quoc te = TCP unicast DE/FR/US/AU/BR)"
  [ -f "$SFILE" ] || { echo "chua co mau"; return 1; }
  echo "s.csv=$(wc -l < "$SFILE")  b.csv=$([ -f "$BFILE" ] && wc -l < "$BFILE" || echo 0)"
  echo ""
  awk -F, '
    $1=="ts"{next}
    NF<20 {next}  # bo dong schema cu neu con sot
    {
      n++; bad+=($(NF-1)+0==0)
      if($6+0>=0 && $6+0<100){lg+=$6;nlg++}
      if($7+0>0){rg+=$7;nrg++; if(mn==""||$7<mn)mn=$7; if($7>mx)mx=$7}
      if($8+0>0){jg+=$8;nj++}
      if($9+0>=0 && $9+0<100){lv+=$9;nlv++}
      if($10+0>0){rv+=$10;nrv++}
      split("12 vn 13 sg 14 de 15 fr 16 use 17 usw 18 au 19 br", meta, " ")
      if($12+0>0){tvn+=$12;nvn++}
      if($13+0>0){tsg+=$13;nsg++}
      if($14+0>0){tde+=$14;nde++; if($14>xde)xde=$14}
      if($15+0>0){tfr+=$15;nfr++}
      if($16+0>0){tue+=$16;nue++; if($16>xue)xue=$16}
      if($17+0>0){tuw+=$17;nuw++}
      if($18+0>0){tau+=$18;nau++}
      if($19+0>0){tbr+=$19;nbr++}
      if($20+0>0){par+=$20;np++}
      ip[$3]++; colo[$4]++; ph[$5]++
    }
    END{
      if(!n){print "no v4 samples (doi 1 mau moi)"; exit}
      printf "samples=%d bad=%d\n", n,bad
      if(nlg) printf "LOSS 8.8.8.8 avg=%.2f%%  rtt=%.1f span=%.1f jit=%.1f   [on dinh last-mile, KHONG phai EU]\n", lg/nlg,nrg?rg/nrg:0,nrg?mx-mn:0,nj?jg/nj:0
      if(nlv) printf "LOSS VN DNS  avg=%.2f%%  rtt=%.1f  tcp_vn=%.0f\n", lv/nlv,nrv?rv/nrv:0,nvn?tvn/nvn:0
      printf "TCP ms  VN=%.0f  SG=%.0f\n", nvn?tvn/nvn:0, nsg?tsg/nsg:0
      printf "      EU  DE=%.0f (max %.0f)  FR=%.0f\n", nde?tde/nde:0,xde+0, nfr?tfr/nfr:0
      printf "      NA  US-E=%.0f (max %.0f)  US-W=%.0f\n", nue?tue/nue:0,xue+0, nuw?tuw/nuw:0
      printf "      AU=%.0f  SA-BR=%.0f\n", nau?tau/nau:0, nbr?tbr/nbr:0
      if(np) printf "par(non-CF)=%.1f/10\n", par/np
      ni=0;for(k in ip)ni++; nc=0;for(k in colo)nc++; nh=0;for(k in ph)nh++
      printf "identity ip=%d colo=%d path=%d\n", ni,nc,nh
    }
  ' "$SFILE"
  echo ""
  if [ -f "$BFILE" ] && grep -q dl_au "$BFILE"; then
    awk -F, '
      $1=="ts"{next}
      {n++
       if($2+0>0){u+=$2;nu++; if(umin==""||$2<umin)umin=$2}
       if($4+0>0){v+=$4;nv++}
       if($5+0>0){d+=$5;nd++}
       if($6+0>0){e+=$6;ne++}
       if($7+0>0){a+=$7;na++}
       if($8+0>0){b+=$8;nb++}
       src[$3]++
      }
      END{
        if(!n){print "no bw v4"; exit}
        printf "bw n=%d  ul_src: ", n
        for(k in src) printf "%s=%d ", k,src[k]
        print ""
        if(nu) printf "UL     avg=%.1f min=%.1f\n", u/nu,umin
        if(nv) printf "DL VN  %.1f\n", v/nv
        if(nd) printf "DL DE  %.1f   [EU]\n", d/nd
        if(ne) printf "DL US-E %.1f  [NA]\n", e/ne
        if(na) printf "DL AU  %.1f\n", a/na
        if(nb) printf "DL BR  %.1f   [SA]\n", b/nb
      }
    ' "$BFILE"
  else echo "chua co bw v4 — se co sau 1 lan do Mbps"; fi
  echo ""
  echo "--- events ---"
  [ -f "$EFILE" ] && tail -15 "$EFILE" || echo none
}

g_tcp() { awk -v x="$1" 'BEGIN{
  if(x==""||x=="na"||x+0==0||x+0>800) print "NA";
  else if(x<=90) print "GOOD";
  else if(x<=220) print "OK";
  else print "WEAK"}'; }
g_loss() { awk -v x="$1" 'BEGIN{
  if(x+0>80) print "NA";
  else if(x<=0.5) print "GOOD";
  else if(x<=2) print "OK";
  else print "WEAK"}'; }
g_mbps() { awk -v x="$1" 'BEGIN{
  if(x+0<=0) print "NA";
  else if(x>=20) print "GOOD";
  else if(x>=8) print "OK";
  else print "WEAK"}'; }
g_par() { awk -v x="$1" 'BEGIN{if(x>=9)print "GOOD"; else if(x>=7)print "OK"; else print "WEAK"}'; }
g_stab() { awk -v i="$1" -v p="$2" 'BEGIN{if(i<=1&&p<=2)print "GOOD"; else if(i<=2&&p<=5)print "OK"; else print "WEAK"}'; }

cmd_fit() {
  purge_old
  echo "======== bwpath $VER FIT  $(iso) ========"
  [ -f "$SFILE" ] || { echo "chua co mau"; return 1; }
  eval "$(awk -F, '
    $1=="ts"{next}
    NF<20{next}
    {n++; if($6+0<80){lg+=$6;nlg++}
     if($12+0>0){vn+=$12;nvn++} if($13+0>0){sg+=$13;nsg++}
     if($14+0>0){de+=$14;nde++} if($15+0>0){fr+=$15;nfr++}
     if($16+0>0){ue+=$16;nue++} if($17+0>0){uw+=$17;nuw++}
     if($18+0>0){au+=$18;nau++} if($19+0>0){br+=$19;nbr++}
     if($20+0>0){par+=$20;np++}
     ip[$3]++; ph[$5]++}
    END{
      if(!n){print "HAVE=0"; exit}
      printf "HAVE=1\nN=%d\nLOSS=%.3f\n",n,nlg?lg/nlg:999
      printf "VN=%.1f\nSG=%.1f\nDE=%.1f\nFR=%.1f\nUSE=%.1f\nUSW=%.1f\nAU=%.1f\nBR=%.1f\nPAR=%.1f\n",
        nvn?vn/nvn:0,nsg?sg/nsg:0,nde?de/nde:0,nfr?fr/nfr:0,nue?ue/nue:0,nuw?uw/nuw:0,nau?au/nau:0,nbr?br/nbr:0,np?par/np:0
      ni=0;for(k in ip)ni++; nh=0;for(k in ph)nh++; printf "N_IP=%d\nN_PATH=%d\n",ni,nh
    }
  ' "$SFILE")"
  [ "${HAVE:-0}" = 1 ] || { echo "chua co mau v4 — chay lai 1 lan after update"; return 1; }
  UL=0; VN_BW=0; DE_BW=0; US_BW=0
  [ -f "$BFILE" ] && grep -q dl_au "$BFILE" && eval "$(awk -F, '
    $1=="ts"{next}
    {if($2+0>0){u+=$2;nu++} if($4+0>0){v+=$4;nv++} if($5+0>0){d+=$5;nd++} if($6+0>0){e+=$6;ne++}}
    END{printf "UL=%.2f\nVN_BW=%.2f\nDE_BW=%.2f\nUS_BW=%.2f\n",nu?u/nu:0,nv?v/nv:0,nd?d/nd:0,ne?e/ne:0}
  ' "$BFILE")"

  echo "n=$N loss8.8=${LOSS}%  TCP VN=$VN SG=$SG | EU DE=$DE FR=$FR | NA E=$USE W=$USW | AU=$AU BR=$BR"
  echo "par=$PAR ul=$UL"
  G_LOSS="$(g_loss "$LOSS")"
  G_VN="$(g_tcp "$VN")"; G_SG="$(g_tcp "$SG")"
  G_DE="$(g_tcp "$DE")"; G_FR="$(g_tcp "$FR")"
  G_USE="$(g_tcp "$USE")"; G_USW="$(g_tcp "$USW")"
  G_AU="$(g_tcp "$AU")"; G_BR="$(g_tcp "$BR")"
  G_UL="$(g_mbps "$UL")"; G_PAR="$(g_par "$PAR")"; G_STAB="$(g_stab "$N_IP" "$N_PATH")"
  echo "grades loss=$G_LOSS vn=$G_VN sg=$G_SG de=$G_DE fr=$G_FR use=$G_USE usw=$G_USW au=$G_AU br=$G_BR ul=$G_UL par=$G_PAR stab=$G_STAB"
  echo ""
  fit() {
    local name="$1" need="$2" why="$3" worst="GOOD" v d
    local IFS=','
    for d in $need; do
      case "$d" in
        loss) v="$G_LOSS" ;; vn) v="$G_VN" ;; sg) v="$G_SG" ;;
        de) v="$G_DE" ;; fr) v="$G_FR" ;; use) v="$G_USE" ;; usw) v="$G_USW" ;;
        au) v="$G_AU" ;; br) v="$G_BR" ;; ul) v="$G_UL" ;; par) v="$G_PAR" ;; stab) v="$G_STAB" ;;
        *) v="OK" ;;
      esac
      [ "$v" = "WEAK" ] && worst="WEAK"
      [ "$v" = "OK" ] && [ "$worst" = "GOOD" ] && worst="OK"
      [ "$v" = "NA" ] && [ "$worst" != "WEAK" ] && worst="OK"
    done
    local lab
    case "$worst" in GOOD) lab="KHOP tot" ;; OK) lab="KHOP TB" ;; WEAK) lab="LECH path" ;; esac
    printf "  %-20s %-12s %s\n" "$name" "$lab" "$why"
  }
  echo "--- fit (khong dung CF loss de giet het app) ---"
  fit "Honeygain-proxy" "ul,par,stab,sg" "A burst; can SG/VN + UL"
  fit "Honeygain-CDN"   "ul,de,use" "B long-haul"
  fit "Wipter"          "ul,par,vn,sg,de,use" "A+B can VN va it nhat 1 trong DE/US"
  fit "EarnApp"         "ul,par,use,de,stab" "buyer US/EU"
  fit "PacketStream"    "ul,par,stab" "job ngan"
  fit "EarnFM"          "ul,sg" "A nhe"
  fit "IPRoyal Pawns"   "ul,stab,sg" "sticky"
  fit "Proxyrack"       "ul,par,stab" "thread"
  fit "AntGain"         "ul,par,sg" "A"
  fit "Traffmonetizer"  "ul,sg" "chiu RTT"
  fit "Peer2Profit"     "ul" "volume"
  fit "Repocket"        "ul,par" "burst"
  fit "Bitping"         "loss,stab" "probe"
  fit "Grass/Gradient"  "stab" "WS"
  fit "Mysterium"       "loss,stab" "tunnel"
  echo ""
  echo "Vung: DE/FR=EU  US-E/W=Bac My  AU=Uc  BR=Nam My  SG/VN=A"
}

cmd_risk() {
  echo "======== CHECKLIST VUNG + RUI RO  $(iso) ========"
  echo "TCP unicast: tot <=90  dung duoc <=220  yeu <=350  loi/timeout = NA"
  echo "TAM neu <8 mau socket / <4 bw. Khong dung ping CF."
  [ -f "$SFILE" ] || { echo "chua data"; return 1; }
  awk -F, '
    function tag(ms, n,   t) {
      if(n<1 || ms+0<=0) return "NA"
      if(ms<=90) return "TOT"
      if(ms<=220) return "OK"
      if(ms<=350) return "YEU"
      return "LOI"
    }
    $1=="ts"{next}
    NF<20{next}
    {
      n++
      if($6+0<80){lg+=$6;nlg++}
      if($7+0>0){rg+=$7; if(mn==""||$7<mn)mn=$7; if($7>mx)mx=$7; nrg++}
      if($12+0>0){vn+=$12;nvn++}
      if($13+0>0){sg+=$13;nsg++}
      if($14+0>0){de+=$14;nde++}
      if($15+0>0){fr+=$15;nfr++}
      if($16+0>0){ue+=$16;nue++}
      if($17+0>0){uw+=$17;nuw++}
      if($18+0>0){au+=$18;nau++}
      if($19+0>0){br+=$19;nbr++}
      ip[$3]++; ph[$5]++
    }
    END{
      if(!n){print "chua mau v4"; exit}
      loss=nlg?lg/nlg:999; span=nrg?mx-mn:999
      ni=0;for(k in ip)ni++; nh=0;for(k in ph)nh++
      st="OK"; if(n<8) st="TAM"
      if(loss>2 || span>70 || ni>2) st="LOI"
      else if(loss>0.5 || span>25) { if(st!="TAM") st="YEU" }
      printf "[ON DINH]     %-4s  loss8.8=%.2f%% span=%.0f n=%d ip=%d path=%d\n", st,loss,span,n,ni,nh
      printf "[A / VN-SG]   %-4s  VN=%.0f  SG=%.0f ms\n", tag(nvn?vn/nvn:0,nvn), nvn?vn/nvn:0, nsg?sg/nsg:0
      printf "[EU DE+FR]    %-4s  DE=%.0f  FR=%.0f\n", tag(nde?de/nde:0,nde), nde?de/nde:0, nfr?fr/nfr:0
      printf "[BAC MY]      %-4s  US-E=%.0f  US-W=%.0f\n", tag(nue?ue/nue:0,nue), nue?ue/nue:0, nuw?uw/nuw:0
      printf "[UC]          %-4s  AU=%.0f\n", tag(nau?au/nau:0,nau), nau?au/nau:0
      printf "[NAM MY]      %-4s  BR=%.0f\n", tag(nbr?br/nbr:0,nbr), nbr?br/nbr:0
    }
  ' "$SFILE"
  if [ -f "$BFILE" ] && grep -q dl_au "$BFILE"; then
    awk -F, '
      $1=="ts"{next}
      {n++; if($2+0>0){u+=$2;nu++; if(umin==""||$2<umin)umin=$2}
       if($3=="cf_block") cb++
       if($5+0>0){d+=$5;nd++} if($6+0>0){e+=$6;ne++}}
      END{
        f="TAM"; if(n>=4) f="OK"
        ua=nu?u/nu:0; ur=ua>0?100*umin/ua:0
        if(n>=4 && ua>0 && ur<40) f="LOI"
        else if(n>=4 && ua>0 && ur<70) f="YEU"
        printf "[FUP/UL]      %-4s  UL avg=%.1f min/avg=%.0f%%  cf_block=%d/%d\n", f,ua,ur,cb+0,n
        if(nd) printf "  DL DE %.1f   DL US-E %.1f Mbps\n", nd?d/nd:0, ne?e/ne:0
      }
    ' "$BFILE"
  else echo "[FUP/UL]      TAM   chua bw v4"; fi
}

cmd_uninstall() {
  [ "$(id -u)" -eq 0 ] || { echo "sudo $SELF uninstall"; return 1; }
  have systemctl && { systemctl disable --now bwpath.service 2>/dev/null || true; rm -f /etc/systemd/system/bwpath.service; systemctl daemon-reload || true; }
  rm -f /etc/cron.d/bwpath /usr/local/bin/bwpath
  echo "Da go. Log: $DIR"
}

case "${1:-auto}" in
  auto|"") cmd_auto ;;
  --version|-V) echo "$VER" ;;
  1|once) cmd_once ;;
  2|bw) cmd_bw ;;
  3|report) cmd_report ;;
  4|fit) cmd_fit; cmd_risk ;;
  risk|8) cmd_risk ;;
  5|install) cmd_install ;;
  6|uninstall) cmd_uninstall ;;
  7|purge) purge_old; echo purged ;;
  daemon) cmd_daemon ;;
  *) echo "sudo bash $SELF"; exit 1 ;;
esac

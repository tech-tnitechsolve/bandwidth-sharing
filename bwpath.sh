#!/usr/bin/env bash
# bwpath.sh — MỘT FILE cho Linux server
# Do noi dia + quoc te, log 7 ngay (tu cat), khop traffic tung platform (ke ca Wipter).
# Khong xet loai IP.
#
# Mot lenh:
#   sudo bash bwpath.sh
# Chua cai -> cai goi + systemd/cron + do + report + fit
# Da cai   -> khong cai lai, chi do + report + fit, dam bao daemon dang chay
#
set -u
export LC_ALL=C LANG=C
VER="3.2.0"

SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
DIR="${BWPATH_DIR:-/var/log/bwpath}"
KEEP_DAYS="${BWPATH_KEEP_DAYS:-7}"
INTERVAL="${BWPATH_INTERVAL:-300}"
BW_EVERY="${BWPATH_BW_EVERY:-12}"
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

need_curl() { have curl || { echo "Thieu curl — chay: sudo bash $SELF"; return 1; }; }

is_installed() {
  [ -x /usr/local/bin/bwpath ] || [ -x "$PREFIX/bwpath.sh" ] || return 1
  if have systemctl && [ -f /etc/systemd/system/bwpath.service ]; then return 0; fi
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

ensure_install() {
  ensure_pkgs || true
  if is_installed; then
    echo "[bwpath] da cai — khong cai lai"
    if have systemctl && [ -f /etc/systemd/system/bwpath.service ]; then
      svc_active || { echo "[bwpath] start daemon"; systemctl start bwpath.service 2>/dev/null || true; }
    fi
    return 0
  fi
  [ "$(id -u)" -eq 0 ] || exec sudo -E bash "$SELF"
  echo "[bwpath] chua cai — dang cai 24/7"
  cmd_install
}

bw_recent() {
  # tranh do bw lap neu vua do < 50 phut (khong tu an line)
  [ -f "$BFILE" ] || return 1
  local last
  last="$(tail -1 "$BFILE" | awk -F, '{print $1}')"
  [ -n "$last" ] && [ "$last" != "ts" ] || return 1
  local e now
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
  if [ "$(id -u)" -eq 0 ]; then ensure_install
  else echo "[bwpath] da cai — chi do"; fi
  echo "[bwpath] do socket..."
  cmd_once || true
  if bw_recent; then
    echo "[bwpath] bo qua bw (da do <50 phut — tranh tu an bang thong)"
  else
    echo "[bwpath] do Mbps nhe (~2MB/huong)..."
    cmd_bw || true
  fi
  echo ""; cmd_report || true
  echo ""; cmd_fit || true
  echo ""; cmd_risk || true
  echo ""
  echo "Daemon: $(svc_active && echo DANG CHAY || echo khong ro). Log $DIR (7 ngay)."
}

mkdir -p "$DIR" 2>/dev/null || true

purge_old() {
  local cut
  cut="$(date -d "-${KEEP_DAYS} days" +%s 2>/dev/null || echo 0)"
  [ "$cut" -gt 0 ] || return 0
  _trim() {
    local f="$1" hdr="${2:-1}"
    [ -f "$f" ] || return 0
    awk -v cut="$cut" -v hdr="$hdr" '
      function ep(s, c,e){c="date -d \"" s "\" +%s 2>/dev/null"; c|getline e; close(c); return e+0}
      hdr && NR==1 {print; next}
      {e=ep($1); if(e==0||e>=cut) print}
    ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  }
  _trim "$SFILE" 1
  _trim "$BFILE" 1
  _trim "$EFILE" 0
  for f in "$SFILE" "$BFILE" "$EFILE"; do
    [ -f "$f" ] || continue
    local n; n="$(wc -l < "$f")"
    if [ "$n" -gt 2300 ]; then
      if [ "$f" = "$EFILE" ]; then tail -n 2000 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
      else { head -1 "$f"; tail -n 2000 "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
      fi
    fi
  done
}

event() { printf '%s %s\n' "$(iso)" "$*" >> "$EFILE"; }

ensure_hdr() {
  mkdir -p "$DIR"
  [ -f "$SFILE" ] || echo "ts,epoch,ip,colo,ph,l_cf,r_cf,j_cf,l_vn,r_vn,j_vn,tcp_vn,tcp_sg,tcp_us,tcp_de,ttfb_vn,par10,ok" > "$SFILE"
  [ -f "$BFILE" ] || echo "ts,ul_cf,dl_cf,dl_vn,dl_sg,dl_us,dl_de" > "$BFILE"
}

ping_triple() {
  local host="$1" f="$2"
  if ping -4 -c "$PING_N" -W 2 -i 0.2 "$host" >"$f" 2>/dev/null || ping -c "$PING_N" -W 2 "$host" >"$f" 2>/dev/null; then
    local loss avg mdev
    loss="$(grep -oE '[0-9.]+% packet loss' "$f" | head -1 | tr -d '%')"
    avg="$(awk -F'/' '/rtt|round-trip/{print $5}' "$f")"
    mdev="$(awk -F'/' '/rtt|round-trip/{print $7}' "$f" | tr -d ' ms')"
    echo "${loss:-100} ${avg:-na} ${mdev:-na}"
  else
    echo "100 na na"
  fi
}

tcp_ms() {
  local t; t="$(curl -4 -o /dev/null -sS --max-time 8 -w '%{time_connect}' "$1" 2>/dev/null || echo "")"
  [ -z "$t" ] && { echo na; return; }
  awk -v t="$t" 'BEGIN{printf "%.1f", t*1000}'
}

ttfb_ms() {
  local t; t="$(curl -4 -o /dev/null -sS --max-time 12 -w '%{time_starttransfer}' "$1" 2>/dev/null || echo "")"
  awk -v t="${t:-0}" 'BEGIN{if(t+0>0) printf "%.0f", t*1000; else print "na"}'
}

dl_mbps() {
  local url="$1" bytes="${2:-$BYTES}" w
  w="$(curl -4 -o /dev/null -sS --max-time 16 -r "0-$((bytes-1))" -w '%{speed_download}' "$url" 2>/dev/null || echo 0)"
  awk -v b="$w" 'BEGIN{printf "%.2f", b*8/1e6}'
}

path_hash() {
  local out="na"
  have traceroute && out="$(traceroute -4 -n -w 1 -q 1 -m 5 1.1.1.1 2>/dev/null | awk 'NR>1{print $2}' | tr '\n' ',')"
  if have sha1sum; then printf '%s' "$out" | sha1sum | awk '{print substr($1,1,10)}'
  else printf '%s' "$out" | wc -c; fi
}

cmd_once() {
  need_curl || return 1
  purge_old; ensure_hdr
  local tmp; tmp="$(mktemp -d /tmp/bwpath.XXXXXX)"
  local epoch ts pub colo ph
  epoch="$(date +%s)"; ts="$(iso)"
  pub="$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null || echo fail)"
  colo="$(curl -4 -fsS --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^colo=/{print $2}')"
  colo="${colo:-na}"
  [ -f "$ST.ip" ] && [ "$pub" != "$(cat "$ST.ip")" ] && event "IP $pub"
  [ -f "$ST.colo" ] && [ "$colo" != "$(cat "$ST.colo")" ] && [ "$colo" != "na" ] && event "COLO $colo"
  echo "$pub" > "$ST.ip"; echo "$colo" > "$ST.colo"
  if [ "${DO_TRACE:-0}" = 1 ] || [ ! -f "$ST.ph" ]; then
    ph="$(path_hash)"
    [ -f "$ST.ph" ] && [ "$ph" != "$(cat "$ST.ph")" ] && event "PATH $ph"
    echo "$ph" > "$ST.ph"
  else ph="$(cat "$ST.ph")"; fi

  local l_cf r_cf j_cf l_vn r_vn j_vn
  read -r l_cf r_cf j_cf <<<"$(ping_triple 1.1.1.1 "$tmp/p1")"
  read -r l_vn r_vn j_vn <<<"$(ping_triple 203.113.131.1 "$tmp/p2")"
  local tcp_vn tcp_sg tcp_us tcp_de ttfb_vn
  tcp_vn="$(tcp_ms https://vnexpress.net/)"
  tcp_sg="$(tcp_ms https://www.google.com.sg/)"
  tcp_us="$(tcp_ms https://ash-speed.hetzner.com/)"
  tcp_de="$(tcp_ms https://speed.hetzner.de/)"
  ttfb_vn="$(ttfb_ms https://vnexpress.net/)"

  local i okc=0
  for i in 1 2 3 4 5 6; do
    ( curl -4 -sS -o /dev/null -w '%{http_code}' --max-time 8 https://www.cloudflare.com/cdn-cgi/trace >"$tmp/c$i" 2>/dev/null || echo 000 >"$tmp/c$i" ) &
  done
  wait
  for i in 1 2 3 4 5 6; do [ "$(cat "$tmp/c$i" 2>/dev/null)" = "200" ] && okc=$((okc+1)); done
  # scale 6 -> /10 cot cu: 6/6 = 10
  okc=$((okc * 10 / 6))

  local ok=1
  awk -v l="$l_cf" 'BEGIN{exit !(l+0>=8)}' && ok=0
  [ "$pub" = "fail" ] && ok=0
  [ "$okc" -lt 7 ] && ok=0
  [ "$ok" = 0 ] && event "BAD loss=$l_cf par=$okc"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$epoch" "$pub" "$colo" "$ph" \
    "$l_cf" "$r_cf" "$j_cf" "$l_vn" "$r_vn" "$j_vn" \
    "$tcp_vn" "$tcp_sg" "$tcp_us" "$tcp_de" "$ttfb_vn" "$okc" "$ok" >> "$SFILE"
  rm -rf "$tmp"
  echo "$ts ok=$ok ip=$pub colo=$colo vn_rtt=$r_vn de_tcp=$tcp_de par=$okc/10"
}

cmd_bw() {
  need_curl || return 1
  purge_old; ensure_hdr
  local ul dlcf dlvn dlsg dlus dlde
  ul="$(dd if=/dev/zero bs=300000 count=1 2>/dev/null | curl -4 -sS -o /dev/null --max-time 12 -X POST --data-binary @- -w '%{speed_upload}' https://speed.cloudflare.com/__up 2>/dev/null || echo 0)"
  ul="$(awk -v b="$ul" 'BEGIN{printf "%.2f", b*8/1e6}')"
  dlcf="$(curl -4 -o /dev/null -sS --max-time 12 -w '%{speed_download}' "https://speed.cloudflare.com/__down?bytes=${BYTES}" 2>/dev/null || echo 0)"
  dlcf="$(awk -v b="$dlcf" 'BEGIN{printf "%.2f", b*8/1e6}')"
  dlvn="$(dl_mbps "http://speedtest.hcm.fpt.vn/speedtest/random4000x4000.jpg" "$BYTES")"
  awk -v x="$dlvn" 'BEGIN{exit !(x+0<1)}' && dlvn="$(dl_mbps "https://vnexpress.net/" 800000)"
  dlsg=0
  dlus="$(dl_mbps "https://ash-speed.hetzner.com/100MB.bin" "$BYTES")"
  dlde="$(dl_mbps "https://speed.hetzner.de/100MB.bin" "$BYTES")"
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$(iso)" "$ul" "$dlcf" "$dlvn" "$dlsg" "$dlus" "$dlde" >> "$BFILE"
  echo "bw ul=$ul cf=$dlcf vn=$dlvn sg=$dlsg us=$dlus de=$dlde"
}

cmd_daemon() {
  echo "bwpath $VER daemon ${INTERVAL}s keep=${KEEP_DAYS}d $DIR"
  local i=0
  while true; do
    cmd_once || event "EXC"
    i=$((i+1))
    [ $((i % BW_EVERY)) -eq 0 ] && cmd_bw || true
    [ $((i % TRACE_EVERY)) -eq 0 ] && DO_TRACE=1 cmd_once || true
    sleep "$INTERVAL"
  done
}

cmd_report() {
  purge_old
  echo "======== bwpath $VER REPORT  $(iso) ========"
  echo "dir=$DIR  keep=${KEEP_DAYS}d"
  [ -f "$SFILE" ] && echo "s.csv=$(wc -l < "$SFILE") dong" || { echo "Chua co mau. Bam [1] hoac: $0 once"; return 1; }
  [ -f "$BFILE" ] && echo "b.csv=$(wc -l < "$BFILE") dong"
  echo ""
  awk -F, '
    $1=="ts"{next}
    {
      n++; bad+=($NF+0==0)
      if($6+0>=0){lc+=$6;nlc++}
      if($7+0>0){rc+=$7;nrc++; if(minc==""||$7<minc)minc=$7; if($7>maxc)maxc=$7}
      if($8+0>0){jc+=$8;nj++}
      if($9+0>=0){lv+=$9;nlv++}
      if($10+0>0){rv+=$10;nrv++}
      if($12+0>0){tv+=$12;ntv++}
      if($13+0>0){tsg+=$13;nsg++}
      if($14+0>0){tus+=$14;nus++}
      if($15+0>0){tde+=$15;nde++; if($15>mxde)mxde=$15}
      if($17+0>0){par+=$17;np++}
      ip[$3]++; colo[$4]++; ph[$5]++
    }
    END{
      if(!n){print "no samples"; exit}
      printf "samples=%d  bad=%d (%.2f%%)\n", n,bad,100*bad/n
      if(nlc) printf "CF   loss=%.2f%%  rtt=%.1f  span=%.1f  jit=%.1f\n", lc/nlc,nrc?rc/nrc:0,nrc?maxc-minc:0,nj?jc/nj:0
      if(nlv) printf "VN   loss=%.2f%%  rtt=%.1f  tcp=%.0f ms     [noi dia]\n", lv/nlv,nrv?rv/nrv:0,ntv?tv/ntv:0
      if(nsg) printf "TCP  SG=%.0f  US=%.0f  DE=%.0f (max %.0f)  [quoc te]\n", tsg/nsg,nus?tus/nus:0,nde?tde/nde:0,mxde+0
      if(np)  printf "par10 avg=%.1f/10\n", par/np
      nip=0;for(k in ip)nip++; nc=0;for(k in colo)nc++; nh=0;for(k in ph)nh++
      printf "identity  ip=%d  colo=%d  path=%d\n", nip,nc,nh
    }
  ' "$SFILE"
  echo ""
  if [ -f "$BFILE" ]; then
    awk -F, '
      $1=="ts"{next}
      {n++
       if($2+0>0){u+=$2;nu++; if(umin==""||$2<umin)umin=$2}
       if($3+0>0){c+=$3;nc++}
       if($4+0>0){v+=$4;nv++; if(vmin==""||$4<vmin)vmin=$4}
       if($5+0>0){s+=$5;ns++}
       if($6+0>0){a+=$6;na++}
       if($7+0>0){d+=$7;nd++; if(dmin==""||$7<dmin)dmin=$7}
      }
      END{
        if(!n){print "chua co bw"; exit}
        printf "bw n=%d\n", n
        if(nu) printf "UL  CF  avg=%.1f min=%.1f\n", u/nu,umin
        if(nc) printf "DL  CF  avg=%.1f  (PoP gan)\n", c/nc
        if(nv) printf "DL  VN  avg=%.1f min=%.1f  [noi dia]\n", v/nv,vmin
        if(ns) printf "DL  SG  avg=%.1f\n", s/ns
        if(na) printf "DL  US  avg=%.1f\n", a/na
        if(nd) printf "DL  DE  avg=%.1f min=%.1f  [quoc te EU]\n", d/nd,dmin
      }
    ' "$BFILE"
  else echo "Chua co bw. Bam [2]"; fi
  echo ""
  echo "--- events ---"
  [ -f "$EFILE" ] && tail -20 "$EFILE" || echo none
}

g_loss() { awk -v x="$1" 'BEGIN{if(x>80)print "NA"; else if(x<=0.5)print "GOOD"; else if(x<=2)print "OK"; else print "WEAK"}'; }
g_span() { awk -v x="$1" 'BEGIN{if(x>800)print "NA"; else if(x<=25)print "GOOD"; else if(x<=70)print "OK"; else print "WEAK"}'; }
g_tcp()  { awk -v x="$1" 'BEGIN{if(x>900)print "WEAK"; else if(x<=90)print "GOOD"; else if(x<=220)print "OK"; else print "WEAK"}'; }
g_mbps() { awk -v x="$1" 'BEGIN{if(x<=0)print "NA"; else if(x>=20)print "GOOD"; else if(x>=8)print "OK"; else print "WEAK"}'; }
g_par()  { awk -v x="$1" 'BEGIN{if(x>=9.5)print "GOOD"; else if(x>=8)print "OK"; else print "WEAK"}'; }
g_stab() { awk -v i="$1" -v p="$2" 'BEGIN{if(i<=1&&p<=2)print "GOOD"; else if(i<=2&&p<=5)print "OK"; else print "WEAK"}'; }

cmd_fit() {
  purge_old
  echo "======== bwpath $VER FIT (path vs cach app hut traffic)  $(iso) ========"
  [ -f "$SFILE" ] || { echo "Chua co mau. Bam [1] roi doi them, hoac de daemon chay."; return 1; }
  eval "$(awk -F, '
    $1=="ts"{next}
    {n++; bad+=($NF+0==0)
     if($6+0>=0){lc+=$6;nlc++}
     if($7+0>0){rc+=$7;nrc++; if(mn==""||$7<mn)mn=$7; if($7>mx)mx=$7}
     if($9+0>=0){lv+=$9;nlv++}
     if($10+0>0){rv+=$10;nrv++}
     if($12+0>0){tv+=$12;ntv++}
     if($13+0>0){tsg+=$13;nsg++}
     if($14+0>0){tus+=$14;nus++}
     if($15+0>0){tde+=$15;nde++}
     if($17+0>0){par+=$17;np++}
     ip[$3]++; ph[$5]++}
    END{
      if(!n){print "HAVE=0"; exit}
      printf "HAVE=1\nN=%d\nBAD=%d\nLOSS_CF=%.3f\nSPAN=%.2f\n",n,bad,nlc?lc/nlc:999,nrc?mx-mn:999
      printf "LOSS_VN=%.3f\nRTT_VN=%.2f\nTCP_VN=%.1f\nTCP_SG=%.1f\nTCP_US=%.1f\nTCP_DE=%.1f\nPAR=%.2f\n",
        nlv?lv/nlv:999,nrv?rv/nrv:999,ntv?tv/ntv:999,nsg?tsg/nsg:999,nus?tus/nus:999,nde?tde/nde:999,np?par/np:0
      ni=0;for(k in ip)ni++; nh=0;for(k in ph)nh++; printf "N_IP=%d\nN_PATH=%d\n",ni,nh
    }
  ' "$SFILE")"
  [ "${HAVE:-0}" = 1 ] || { echo "s.csv rong"; return 1; }
  UL=0; VN=0; SG=0; US=0; DE=0
  [ -f "$BFILE" ] && eval "$(awk -F, '
    $1=="ts"{next}
    {if($2+0>0){u+=$2;nu++} if($4+0>0){v+=$4;nv++} if($5+0>0){s+=$5;ns++} if($6+0>0){a+=$6;na++} if($7+0>0){d+=$7;nd++}}
    END{printf "UL=%.2f\nVN=%.2f\nSG=%.2f\nUS=%.2f\nDE=%.2f\n",nu?u/nu:0,nv?v/nv:0,ns?s/ns:0,na?a/na:0,nd?d/nd:0}
  ' "$BFILE")"
  echo "n=$N bad=$BAD  lossCF=${LOSS_CF}% span=${SPAN}ms  VN loss=${LOSS_VN}% rtt=${RTT_VN} tcp=${TCP_VN}"
  echo "TCP SG=${TCP_SG} US=${TCP_US} DE=${TCP_DE}  par=${PAR}/10  ip=$N_IP path=$N_PATH"
  echo "Mbps UL=$UL  DL VN=$VN SG=$SG US=$US DE=$DE"
  echo ""
  G_LOSS="$(g_loss "$LOSS_CF")"; G_SPAN="$(g_span "$SPAN")"
  G_VN="$(g_tcp "$TCP_VN")"; G_SG="$(g_tcp "$TCP_SG")"; G_US="$(g_tcp "$TCP_US")"; G_DE="$(g_tcp "$TCP_DE")"
  G_UL="$(g_mbps "$UL")"; G_VNbw="$(g_mbps "$VN")"; G_USbw="$(g_mbps "$US")"; G_DEbw="$(g_mbps "$DE")"
  G_PAR="$(g_par "$PAR")"; G_STAB="$(g_stab "$N_IP" "$N_PATH")"
  echo "grades loss=$G_LOSS span=$G_SPAN vn=$G_VN sg=$G_SG us=$G_US de=$G_DE ul=$G_UL vnBW=$G_VNbw usBW=$G_USbw deBW=$G_DEbw par=$G_PAR stab=$G_STAB"
  echo ""
  fit() {
    local name="$1" need="$2" why="$3" worst="GOOD" v d
    local IFS=','
    for d in $need; do
      case "$d" in
        loss) v="$G_LOSS" ;; span) v="$G_SPAN" ;; vn) v="$G_VN" ;; sg) v="$G_SG" ;;
        us) v="$G_US" ;; de) v="$G_DE" ;; ul) v="$G_UL" ;; vnbw) v="$G_VNbw" ;;
        usbw) v="$G_USbw" ;; debw) v="$G_DEbw" ;; par) v="$G_PAR" ;; stab) v="$G_STAB" ;; *) v="OK" ;;
      esac
      [ "$v" = "WEAK" ] && worst="WEAK"
      [ "$v" = "OK" ] && [ "$worst" = "GOOD" ] && worst="OK"
      [ "$v" = "NA" ] && [ "$worst" = "GOOD" ] && worst="OK"
    done
    local lab; case "$worst" in GOOD) lab="KHOP tot" ;; OK) lab="KHOP trung binh" ;; WEAK) lab="LECH path" ;; esac
    printf "  %-20s %-18s %s\n" "$name" "$lab" "$why"
  }
  echo "--- khop CO CAU HUT TRAFFIC ---"
  fit "Honeygain-proxy" "loss,span,ul,stab,sg,par"          "A HTTPS ngan + UPLOAD + burst"
  fit "Honeygain-CDN"   "ul,debw,span"                      "B object dai / long-haul"
  fit "Wipter"          "loss,span,ul,stab,par,vnbw,debw,usbw" "A+B web + CDN; can VN va US/DE"
  fit "EarnApp"         "loss,span,ul,stab,de,us,par"       "A nang buyer US/EU"
  fit "PacketStream"    "loss,span,ul,stab,par"             "A job ngan"
  fit "EarnFM"          "loss,ul,sg"                        "A nhe"
  fit "IPRoyal Pawns"   "loss,span,ul,stab"                 "A sticky"
  fit "Proxyrack"       "loss,ul,par,stab"                  "A nhieu thread"
  fit "AntGain"         "loss,span,ul,par"                  "A"
  fit "Traffmonetizer"  "loss,ul,sg"                        "A chiu RTT cao hon"
  fit "Peer2Profit"     "loss,ul"                           "A volume"
  fit "Repocket"        "loss,ul,span"                      "A burst"
  fit "Bitping"         "loss,span,stab"                    "C probe"
  fit "Grass/Gradient"  "stab,loss"                         "C WebSocket"
  fit "Mysterium"       "loss,span,stab"                    "C tunnel"
  echo ""
  echo "Wipter: VN tot + DE/US yeu = chi job gan. Nguoc lai = thieu noi dia."
  echo "LECH = socket khong du suc cho dung kieu traffic — khong ket luan loai IP."
}

cmd_risk() {
  echo "======== CHECKLIST RUI RO THU NHAP (path)  $(iso) ========"
  echo "Nguong: loss<=0.5%  span<=25ms  TCP US/DE<=220ms  UL min/avg>=70%  DE min/avg>=50%"
  echo "Can >=12 mau socket (~1h) va >=4 mau bw (~6h) de ket luan FUP. It hon = TAM."
  [ -f "$SFILE" ] || { echo "chua co data"; return 1; }
  awk -F, '
    $1=="ts"{next}
    {
      n++; bad+=($NF+0==0)
      if($6+0>=0){lc+=$6;nlc++}
      if($7+0>0){rc+=$7;nrc++; if(mn==""||$7<mn)mn=$7; if($7>mx)mx=$7}
      if($8+0>0){jc+=$8;nj++}
      if($9+0>=0){lv+=$9;nlv++}
      if($14+0>0){tus+=$14;nus++; if($14>xus)xus=$14}
      if($15+0>0){tde+=$15;nde++; if($15>xde)xde=$15}
      if($17+0>0){par+=$17;np++}
      ip[$3]++; ph[$5]++
    }
    END{
      loss=nlc?lc/nlc:999; span=nrc?mx-mn:999; jit=nj?jc/nj:999
      us=nus?tus/nus:999; de=nde?tde/nde:999
      nip=0;for(k in ip)nip++; nh=0;for(k in ph)nh++
      printf "DATA socket=%d bad=%d\n", n,bad
      # on dinh
      s="OK"
      if(n<12) s="TAM"
      if(loss>2 || span>70 || jit>25 || bad*100/n>8 || nip>2 || nh>5) s="LOI"
      else if(loss>0.5 || span>25 || jit>12 || nip>1 || nh>2) { if(s!="TAM") s="YEU" }
      printf "[ON DINH / CHAP CHON]  %-4s  loss=%.2f%% span=%.0fms jit=%.1f bad=%.1f%% ip=%d path=%d\n", s,loss,span,jit,n?100*bad/n:0,nip,nh
      # tre quoc te — connect unicast US/DE, KHONG dung ping 1.1.1.1
      t="OK"
      if(n<8) t="TAM"
      if(us>350 || de>350 || us>800 || de>800) t="LOI"
      else if(us>220 || de>220) { if(t!="TAM") t="YEU" }
      printf "[TRE QUOC TE US/DE]    %-4s  TCP_US=%.0f (max %.0f)  TCP_DE=%.0f (max %.0f) ms\n", t,us,xus+0,de,xde+0
    }
  ' "$SFILE"
  if [ -f "$BFILE" ]; then
    awk -F, '
      $1=="ts"{next}
      {
        n++
        if($2+0>0){u+=$2;nu++; if(umin==""||$2<umin)umin=$2}
        if($4+0>0){v+=$4;nv++; if(vmin==""||$4<vmin)vmin=$4}
        if($6+0>0){a+=$6;na++; if(amin==""||$6<amin)amin=$6}
        if($7+0>0){d+=$7;nd++; if(dmin==""||$7<dmin)dmin=$7}
      }
      END{
        if(!n){print "[FUP / BOP LINE]        TAM   chua co bw"; exit}
        ua=nu?u/nu:0; da=nd?d/nd:0; aa=na?a/na:0
        ur=ua>0?100*umin/ua:0; dr=da>0?100*dmin/da:0; ar=aa>0?100*amin/aa:0
        f="OK"
        if(n<4) f="TAM"
        if((ua>0 && ur<40) || (da>0 && dr<35) || ua>0 && ua<5) f="LOI"
        else if((ua>0 && ur<70) || (da>0 && dr<50)) { if(f!="TAM") f="YEU" }
        printf "[FUP / BOP LINE]        %-4s  UL min/avg=%.0f%% (avg %.1f min %.1f)  DE min/avg=%.0f%%  US min/avg=%.0f%%  n_bw=%d\n", f,ur,ua,umin+0,dr,ar,n
        print "  LOI = line bi shape/FUP hoac long-haul sap — buyer timeout, thu nhap giam."
        print "  YEU = co dau hieu hop dem/dem yeu. OK = khong thay bop tren mau do."
      }
    ' "$BFILE"
  else
    echo "[FUP / BOP LINE]        TAM   chua co bw"
  fi
  echo "OK=an toan path  YEU=can theo doi  LOI=anh huong job  TAM=chua du mau"
}

cmd_install() {
  [ "$(id -u)" -eq 0 ] || { echo "Chay: sudo $SELF install"; return 1; }
  mkdir -p "$PREFIX" "$DIR"
  cp -a "$SELF" "$PREFIX/bwpath.sh"
  chmod 755 "$PREFIX/bwpath.sh"
  ln -sfn "$PREFIX/bwpath.sh" /usr/local/bin/bwpath
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
    echo "OK systemd bwpath.service"
  else
    printf '%s\n' "*/5 * * * * BWPATH_DIR=${DIR} /usr/local/bin/bwpath once >/dev/null 2>&1" \
      "11 * * * * BWPATH_DIR=${DIR} /usr/local/bin/bwpath bw >/dev/null 2>&1" > /etc/cron.d/bwpath
    chmod 644 /etc/cron.d/bwpath
    echo "OK cron"
  fi
  echo "Lenh: bwpath     hoac   bwpath 1 / 2 / 3 / 4"
  echo "Log:  $DIR  (s.csv b.csv e.log, 7 ngay tu cat)"
}

cmd_uninstall() {
  [ "$(id -u)" -eq 0 ] || { echo "sudo $SELF uninstall"; return 1; }
  have systemctl && { systemctl disable --now bwpath.service 2>/dev/null || true; rm -f /etc/systemd/system/bwpath.service; systemctl daemon-reload 2>/dev/null || true; }
  rm -f /etc/cron.d/bwpath /usr/local/bin/bwpath
  echo "Da go. Log giu: $DIR"
}

pause() { echo ""; printf "Enter de ve menu..."; read -r _ || true; }

menu() {
  while true; do
    echo ""
    echo "========== bwpath $VER =========="
    echo "  [1]  Do 1 mau socket (VN + SG/US/DE)"
    echo "  [2]  Do bang thong noi dia / quoc te"
    echo "  [3]  Bao cao 7 ngay"
    echo "  [4]  Fit platform (Wipter, Honeygain, ...)"
    echo "  [5]  Cai 24/7  (can sudo)"
    echo "  [6]  Go cai dat"
    echo "  [7]  Xoa log > ${KEEP_DAYS} ngay"
    echo "  [0]  Thoat"
    echo "================================="
    printf "Chon: "
    read -r c || exit 0
    case "$c" in
      1|once) cmd_once; pause ;;
      2|bw) cmd_bw; pause ;;
      3|report) cmd_report; pause ;;
      4|fit) cmd_fit; echo ""; cmd_risk; pause ;;
      5|install) cmd_install; pause ;;
      6|uninstall) cmd_uninstall; pause ;;
      7|purge) purge_old; echo "purged"; pause ;;
      0|q|quit|exit) exit 0 ;;
      *) echo "Khong ro." ;;
    esac
  done
}

case "${1:-auto}" in
  auto|"") cmd_auto ;;
  menu) menu ;;
  1|once) cmd_once ;;
  2|bw) cmd_bw ;;
  3|report) cmd_report ;;
  4|fit) cmd_fit; cmd_risk ;;
  risk|8) cmd_risk ;;
  5|install) cmd_install ;;
  6|uninstall) cmd_uninstall ;;
  7|purge) purge_old; echo purged ;;
  daemon) cmd_daemon ;;
  -h|--help|help)
    echo "sudo bash $SELF     # MOT LENH: cai neu chua + do + report + fit"
    echo "$SELF menu          # menu tay"
    ;;
  *) echo "sudo bash $SELF"; exit 1 ;;
esac

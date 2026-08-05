#!/usr/bin/env bash
#============================================================================
#  fix_vps_cu.sh - VA NONG cho VPS DA CHAY setup_vps.sh BAN CU
#
#  Chay TREN TUNG VPS CU 1 LAN:
#     sudo bash fix_vps_cu.sh
#
#  CHI lam 4 viec, KHONG dong vao container dang chay tot:
#   1) Cai lai ii-restart-all.sh ban moi: TU QUET folder (khong BASE_DIR co dinh
#      -> khong con loi sai duong dan kieu /home/ubunt nhu ban cu)
#   2) Cai lai ii-status.sh ban moi (tu quet /opt /root /home /srv)
#   3) Dam bao cron 04:15 + logrotate ton tai dung chuan
#   4) Revive ngay cac container dang Exited (don task containerd ket truoc
#      -> start lai) de he thong chay tron ngay, khong phai cho toi 04:15
#
#  An toan: chi "docker restart/start" cac container CO TRONG containernames.txt
#  (tuc container cua cac folder InternetIncome), khong yt he thong khac.
#============================================================================
set -u

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_0=''
fi
log()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!!]${C_0} $*"; }
die()  { echo -e "${C_R}[XX]${C_0} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Chay bang root: sudo bash $0"
command -v docker >/dev/null 2>&1 || die "Khong thay docker - VPS nay chua setup gi?"
has_systemd() { command -v systemctl >/dev/null 2>/dev/null && [[ -d /run/systemd/system ]]; }

EXTRA_ROOT="${1:-}"
if [[ -n "$EXTRA_ROOT" && ! -d "$EXTRA_ROOT" ]]; then
  warn "Tham so them thu muc quet nhung khong ton tai: $EXTRA_ROOT (bo qua)"
  EXTRA_ROOT=""
fi

#------------------- 1+2. CAI HELPER BAN MOI (tu quet, khong BASE_DIR) -------
cat > /usr/local/bin/ii-restart-all.sh <<'EOS'
#!/usr/bin/env bash
# ii-restart-all.sh - TU QUET & restart MOI folder InternetIncome
# - Tim containernames.txt trong /opt /root /home /srv (toi 4 tang), sort -u chong trung.
# - Khong dung BASE_DIR co dinh -> folder them/xoa TU DONG duoc nhan dien moi lan chay.
# - Co don task containerd ket (loi "AlreadyExists", moby/moby#50040) + revive Exited.
LOG=/var/log/ii-restart.log
ROOTS=(/opt /root /home /srv __EXTRA__)
ts() { date '+%F %T'; }
HAVE_CTR=0; command -v ctr >/dev/null 2>&1 && HAVE_CTR=1

{
  echo "[$(ts)] ==================== ii-restart-all ===================="
  mapfile -t FILES < <(find "${ROOTS[@]}" -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)
  if (( ${#FILES[@]} == 0 )); then
    echo "[$(ts)] chua thay folder nao (chua --start hoac khong trong ${ROOTS[*]})"
  else
    # Don task containerd ket TRUOC de "docker restart" khoi gap loi AlreadyExists
    STUCK=$(docker ps -aq --no-trunc -f status=exited 2>/dev/null || true)
    if (( HAVE_CTR == 1 )) && [[ -n "$STUCK" ]]; then
      for cid in $STUCK; do
        ctr -n moby task kill -s SIGKILL "$cid" >/dev/null 2>&1
        ctr -n moby task rm "$cid" >/dev/null 2>&1
      done
      echo "[$(ts)] da don task containerd ket (neu co)"
    fi
    TOTAL=0
    for cn in "${FILES[@]}"; do
      d=$(dirname "$cn")
      [[ -f "${d}/internetIncome.sh" ]] || continue
      n=$(grep -c . "$cn" 2>/dev/null || echo 0)
      TOTAL=$((TOTAL+n))
      echo "[$(ts)] >>> ${d} (${n} container)"
      xargs -r -a "$cn" docker restart 2>&1 || echo "[$(ts)] !! loi restart tai ${d}"
      sleep 15
    done
    # Revive: container thuoc cac folder con Exited -> start lai
    # (docker start tren container dang chay = no-op, khong hai)
    sleep 10
    cat "${FILES[@]}" 2>/dev/null | xargs -r docker start >/dev/null 2>&1
    STILL=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
    echo "[$(ts)] xong: ${TOTAL} container / ${#FILES[@]} folder | con Exited: ${STILL}"
  fi
} >> "$LOG" 2>&1
EOS
if [[ -n "$EXTRA_ROOT" ]]; then
  sed -i "s|__EXTRA__|\"${EXTRA_ROOT}\"|" /usr/local/bin/ii-restart-all.sh
else
  sed -i "s| __EXTRA__||" /usr/local/bin/ii-restart-all.sh
fi
chmod +x /usr/local/bin/ii-restart-all.sh
log "Da cai ii-restart-all.sh ban moi (tu quet /opt /root /home /srv${EXTRA_ROOT:+ + $EXTRA_ROOT})"

cat > /usr/local/bin/ii-status.sh <<'EOS'
#!/usr/bin/env bash
# ii-status.sh [duong_dan_them] - folder nao chay bao nhieu container + tai nguyen
ROOTS=("$@")
if (( ${#ROOTS[@]} == 0 )); then ROOTS=(/opt /root /home /srv); fi

echo "===== INTERNETINCOME STATUS ====="
found=0
while IFS= read -r cn; do
  d=$(dirname "$cn")
  [[ -f "${d}/internetIncome.sh" ]] || continue
  found=1
  total=$(grep -c . "$cn" 2>/dev/null || echo 0)
  running=0
  while IFS= read -r c; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == "true" ]] && running=$((running+1))
  done < "$cn"
  mark=""
  (( running < total )) && mark="  <-- THIEU $((total-running))"
  printf "  %-46s %4s/%-4s running%s\n" "$d" "$running" "$total" "$mark"
done < <(find "${ROOTS[@]}" -maxdepth 4 -name containernames.txt -type f 2>/dev/null | sort -u)
if (( found == 0 )); then echo "  (chua thay folder InternetIncome nao)"; fi

echo "----- tai nguyen -----"
echo "  docker : $(docker ps -q 2>/dev/null | wc -l) running / $(docker ps -aq 2>/dev/null | wc -l) total (exited: $(docker ps -aq -f status=exited 2>/dev/null | wc -l))"
free -h | awk '/^Mem:/{printf "  RAM    : %s/%s dang dung\n",$3,$2} /^Swap:/{printf "  Swap   : %s/%s dang dung\n",$3,$2}'
df -h / | awk 'NR==2{printf "  Disk / : %s/%s (%s)\n",$3,$2,$5}'
EOS
chmod +x /usr/local/bin/ii-status.sh
log "Da cai ii-status.sh ban moi"

#------------------- 3. DAM BAO CRON + LOGROTATE DUNG CHUAN ------------------
cat > /etc/logrotate.d/ii-logs <<'EOF'
/var/log/ii-*.log {
    weekly
    rotate 4
    size 10M
    missingok
    notifempty
    copytruncate
}
EOF

cat > /etc/cron.d/internetincome <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 04:15 hang ngay: restart lan luot tat ca folder InternetIncome (tu quet)
15 4 * * * root /usr/local/bin/ii-restart-all.sh
# 05:30 chu nhat: don image docker dang (<none>)
30 5 * * 0 root /usr/bin/docker image prune -f >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/internetincome
if has_systemd; then
  systemctl enable --now cron >/dev/null 2>&1 || true
else
  service cron start >/dev/null 2>&1 || true
fi
log "Cron 04:15 hang ngay OK (/etc/cron.d/internetincome)"

#------------------- 4. REVIVE CONTAINER EXITED NGAY BAY GIO -----------------
HAVE_CTR=0; command -v ctr >/dev/null 2>&1 && HAVE_CTR=1
EX_COUNT=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
if (( EX_COUNT > 0 )); then
  log "Thay ${EX_COUNT} container Exited -> dang revive..."
  # Don task containerd ket truoc (loi AlreadyExists), full ID 64 ky tu
  if (( HAVE_CTR == 1 )); then
    for cid in $(docker ps -aq --no-trunc -f status=exited 2>/dev/null); do
      ctr -n moby task kill -s SIGKILL "$cid" >/dev/null 2>&1
      ctr -n moby task rm "$cid" >/dev/null 2>&1
    done
  fi
  docker ps -aq -f status=exited 2>/dev/null | xargs -r -n1 docker start >/dev/null 2>&1
  STILL=$(docker ps -aq -f status=exited 2>/dev/null | wc -l)
  if (( STILL > 0 )); then
    warn "Van con ${STILL} container chua bat duoc - xem: docker ps -a"
  else
    log "Da revive sach ${EX_COUNT} container Exited"
  fi
else
  log "Khong co container Exited nao - he thong dang sach"
fi

#------------------- 5. TU KIEM CHUNG ---------------------------------------
echo
echo "===================== FIX XONG - TU KIEM CHUNG ====================="
/usr/local/bin/ii-status.sh
echo
echo "  - Bay gio ve sau: cron 04:15 tu quet & restart, khong can lam gi them."
echo "  - Khi nao ranh: upload setup_vps.sh BAN MOI roi chay 'sudo bash ~/setup_vps.sh'"
echo "    de chuan hoa 100% he thong (idempotent, khong restart docker neu config cu)."
echo "====================================================================="

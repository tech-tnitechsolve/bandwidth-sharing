#!/usr/bin/env bash
#=============================================================================
#  win-init.sh — entrypoint của Windows-box container (Wine + Xvfb)
#-----------------------------------------------------------------------------
#  Nhiệm vụ (theo thứ tự):
#   0) [root] Pin DNS đi qua TUN (chống lộ query ra DNS VPS) + hạ quyền wineuser.
#   1) Đợi TUN/network sẵn sàng qua route tun* (kill-switch: chưa an toàn = không chạy).
#   2) Lần chạy đầu: wineboot -> áp identity.reg -> cài app.
#   3) Bật Xvfb (desktop ảo), tùy chọn x11vnc.
#   4) Chạy từng app + vòng lặp tự phục hồi + kill-switch mạng + log thông minh.
#
#  LOG THÔNG MINH (chống nghẽn ổ):
#   * Mỗi app ghi log riêng: <prefix>/apps/logs/<KEY>.log  (timestamp UTC đầu dòng)
#   * File quá WIN_LOG_MAX_KB (mặc định 2MB) -> xoay giữ 1 bản .log.1
#   * Log/ảnh cũ hơn WIN_LOG_RETENTION_DAYS (mặc định 4 ngày) -> tự xóa
#   * Dòng log quá dài bị cắt (WIN_LOG_MAX_LINE) -> không phình disk
#   * Heartbeat + netstate ghi vào <prefix>/apps/.alive_<KEY> / .netstate để
#     orchestrator đọc (--health/--status) mà KHÔNG cần gửi request qua proxy.
#
#  Biến env (do orchestrator truyền):
#   WIN_APPS, <KEY>_INSTALLER/_LAUNCH/_DETECT/_ARGS/_CWD/_INSTALL_FLAGS,
#   <KEY>_LOGIN_EMAIL/_LOGIN_PASSWORD/_WIN_TITLE/_LOGIN_SCRIPT,
#   WIN_IDENTITY_DIR, WIN_PREFIX_DIR, WIN_VNC, WIN_SCREEN,
#   WIN_COMPUTER_NAME, WIN_DNS_SERVERS, WIN_SET_HOSTNAME,
#   WIN_LOG_RETENTION_DAYS, WIN_LOG_MAX_KB, WIN_LOG_MAX_LINE
#=============================================================================
set -uo pipefail

if [[ -t 1 ]]; then C_=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N=$'\033[0m'; else C_=''; G=''; Y=''; R=''; N=''; fi
say(){ printf '%s[*]%s %s\n' "$C_" "$N" "$*"; }
warn(){ printf '%s[!]%s %s\n' "$Y" "$N" "$*" >&2; }

# ============================================================ [ROOT] chống lộ mạng
#  DNS phải đi qua TUN (không lộ query ra DNS VPS). Viết resolv.conf + hostname
#  rồi hạ quyền xuống wineuser (wine cần chạy đúng user sở hữu prefix).
if [[ "$(id -u)" == 0 ]]; then
  if [[ -w /etc/resolv.conf ]]; then
    { printf '# win-init: DNS đi qua TUN/proxy (tránh lộ query ra DNS VPS)\n'
      _ns_list="${WIN_DNS_SERVERS:-8.8.8.8,1.1.1.1}"
      for ns in ${_ns_list//,/ }; do
        [[ -n "$ns" ]] && printf 'nameserver %s\n' "$ns"
      done
    } > /etc/resolv.conf 2>/dev/null || true
  fi
  if [[ "${WIN_SET_HOSTNAME:-1}" == "1" && -n "${WIN_COMPUTER_NAME:-}" ]] && command -v hostname >/dev/null 2>&1; then
    hostname "$WIN_COMPUTER_NAME" 2>/dev/null || true
  fi
  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv --reuid=10001 --regid=10001 --init-groups /usr/local/bin/win-init.sh "$@"
  elif command -v runuser >/dev/null 2>&1; then
    exec runuser -u wineuser -- /usr/local/bin/win-init.sh "$@"
  else
    warn "thiếu setpriv/runuser — không thể hạ quyền xuống wineuser; vẫn chạy tiếp (có thể lỗi quyền wine)."
  fi
fi

# ============================================================ env
IDIR="${WIN_IDENTITY_DIR:-/identity}"
PDIR="${WIN_PREFIX_DIR:-/prefix}"
HOME_DIR="${WIN_HOME:-/winehome}"
DISPLAY_NUM="${WIN_DISPLAY:-99}"
SCREEN="${WIN_SCREEN:-1280x720x24}"
LOG_RETENTION_DAYS="${WIN_LOG_RETENTION_DAYS:-4}"
LOG_MAX_KB="${WIN_LOG_MAX_KB:-2048}"
LOG_MAX_LINE="${WIN_LOG_MAX_LINE:-400}"
NET_INTERVAL="${WIN_NET_INTERVAL:-10}"      # giây giữa 2 lần kiểm tra mạng
PURGE_INTERVAL="${WIN_PURGE_INTERVAL:-600}"  # giây giữa 2 lần dọn log cũ
export WINEPREFIX="$PDIR" WINEARCH="${WINEARCH:-win64}" WINEDEBUG=-all HOME="$HOME_DIR" DISPLAY=":$DISPLAY_NUM"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree=d;mshtml=d}"
export TMP=/winehome/tmp TEMP=/winehome/tmp
mkdir -p "$HOME_DIR/tmp" "$PDIR/drive_c" "$PDIR/apps/logs" 2>/dev/null || true
chmod -R 777 "$PDIR/apps" 2>/dev/null || true
LOGDIR="$PDIR/apps/logs"

# ============================================================ log thông minh
log_line(){ # <file> <line>
  local f="$1" line="${2:0:${LOG_MAX_LINE}}"
  printf '[%sZ] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S)" "$line" >> "$f" 2>/dev/null || true
}
log_app(){ # <key> : đọc stdin -> ghi file log + in ra stdout (docker logs vẫn xem được)
  local k="$1" f="$LOGDIR/${k}.log" n=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    log_line "$f" "$line"
    printf '[%s] %s\n' "$k" "$line"
    n=$((n+1))
    if (( n % 100 == 0 )); then rotate_log "$f"; fi
  done
}
rotate_log(){ # <file> : quá WIN_LOG_MAX_KB -> giữ 1 bản .log.1
  local f="$1" sz
  [[ -f "$f" ]] || return 0
  sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
  if (( sz > LOG_MAX_KB * 1024 )); then
    mv -f "$f" "$f.1" 2>/dev/null || true
    : > "$f"
  fi
}
purge_logs(){ # xóa log + ảnh cũ hơn LOG_RETENTION_DAYS ngày
  local f now age
  now=$(date +%s)
  for f in "$LOGDIR"/* "$PDIR/apps"/*.png "$PDIR/apps"/.netstate "$PDIR/apps"/.alive_* "$PDIR/apps"/.restarts_*; do
    [[ -f "$f" ]] || continue
    age=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo "$now") ))
    if (( age > LOG_RETENTION_DAYS * 86400 )); then rm -f "$f" 2>/dev/null || true; fi
  done
}

# ============================================================ net guard (kill-switch)
#  Đọc /proc/net/route (netns CHUNG với TUN). Trạng thái:
#    UP   : có route phủ toàn IPv4 qua tun* (0.0.0.0/1 + 128.0.0.0/1 hoặc default qua tun)
#    LEAK : KHÔNG có route tun mà vẫn còn default route (0.0.0.0/0) qua iface khác -> LỘ IP VPS
#    DOWN : không có route nào (offline, an toàn — kill-switch tự nhiên)
net_state(){
  awk '
    NR==1{next}
    {
      iface=$1; dest=$2; mask=$8;
      if (dest=="00000000" && mask=="00000000") { if (iface ~ /^tun/) td=1; else od=1; }
      if (dest=="00000000" && mask=="80000000" && iface ~ /^tun/) tl=1;
      if (dest=="80000000" && mask=="80000000" && iface ~ /^tun/) th=1;
    }
    END {
      if (td || (tl && th)) { print "UP"; exit }
      if (od) { print "LEAK"; exit }
      print "DOWN"
    }' /proc/net/route 2>/dev/null
}
net_guard_loop(){ # chạy nền: ghi .netstate mỗi chu kỳ + kill wine khi LEAK
  local st prev=""
  while true; do
    st=$(net_state)
    printf '%s|%s\n' "$(date +%s)" "$st" > "$PDIR/apps/.netstate" 2>/dev/null || true
    if [[ "$st" != "$prev" ]]; then
      log_line "$LOGDIR/net.log" "NET $st"
      prev="$st"
    fi
    if [[ "$st" == "LEAK" ]]; then
      warn "LEAK RISK: default route KHÔNG qua tun -> kill wine (kill-switch chống lộ IP VPS)"
      wineserver -k 2>/dev/null || true
    fi
    sleep "$NET_INTERVAL"
  done
}
wait_net(){ # đợi route qua tun (không chạy app khi chưa an toàn)
  local i=0 st
  while [[ $i -lt 180 ]]; do
    st=$(net_state)
    [[ "$st" == "UP" ]] && return 0
    sleep 2; i=$((i+1))
  done
  warn "không có route tun sau 360s — app sẽ chờ tiếp (kill-switch an toàn, KHÔNG chạy khi có nguy cơ lộ IP)."
}

# ============================================================ first-run (identity)
first_run(){
  local marker="$PDIR/.wininit-done"
  [[ -f "$marker" ]] && return 0
  if [[ ! -d "$PDIR/drive_c/windows" && -d /opt/winprefix-template ]]; then
    say "Copy wine prefix template -> $PDIR (first-boot tức thì)..."
    cp -a /opt/winprefix-template/. "$PDIR"/ 2>/dev/null || true
  fi
  [[ -d "$PDIR/drive_c/windows" ]] || { say "Template không có — chạy wineboot"; wineboot -u >/dev/null 2>&1 || true; }
  rm -f "$PDIR/dosdevices/z:" 2>/dev/null || true
  if [[ -f /usr/local/bin/identity.sh && -f "$IDIR/identity.reg" ]]; then
    /usr/local/bin/identity.sh apply "$IDIR" "$PDIR" || warn "áp identity thất bại"
  else
    warn "không thấy identity.reg (đường dẫn $IDIR)"
  fi
  mkdir -p "$PDIR/apps"
  touch "$marker"
  say "First-run xong."
}

# ============================================================ install app (retry-safe)
install_apps(){
  local k inst src flags m
  for k in ${WIN_APPS//,/ }; do
    k="${k//[^A-Za-z0-9_]/}"
    [[ -z "$k" ]] && continue
    eval "inst=\${${k}_INSTALLER:-}"
    [[ -n "$inst" ]] || continue
    m="$PDIR/apps/.installed_${k}"
    [[ -f "$m" ]] && continue
    src="/installers/$inst"
    if [[ -f "$src" ]]; then
      eval "flags=\${${k}_INSTALL_FLAGS:-/S}"
      say "Cài đặt $k từ $inst (flags: $flags)..."
      wine "$src" $flags >/dev/null 2>&1 || true
      timeout 120 wineserver -w 2>/dev/null || true
      touch "$m"
    else
      warn "Không thấy installer '$inst' trong /installers — chưa cài $k (sẽ thử lại lần chạy sau)."
    fi
  done
}

# ============================================================ auto-detect exe
resolve_launch(){
  local k cur pat found winpath
  for k in ${WIN_APPS//,/ }; do
    k="${k//[^A-Za-z0-9_]/}"; [[ -z "$k" ]] && continue
    eval "cur=\${${k}_LAUNCH:-}"
    eval "pat=\${${k}_DETECT:-}"
    if [[ ( -z "$cur" || "$cur" == "auto" ) && -n "$pat" ]]; then
      found=$(find "$PDIR/drive_c" -type f -iname "$pat" 2>/dev/null \
        | grep -viE '/(unins|uninstall|update)[0-9]*\.exe$' | head -1)
      if [[ -n "$found" ]]; then
        winpath="${found#$PDIR/drive_c/}"
        winpath="C:\\\\${winpath//\//\\\\}"
        export "${k}_LAUNCH=$winpath"
        say "[$k] auto-detect exe: $winpath"
      else
        warn "[$k] chưa tìm thấy exe khớp '$pat' — nếu app đã cài, đặt <KEY>_LAUNCH thủ công."
      fi
    fi
  done
}

# ============================================================ desktop ảo
start_x(){
  pkill -f "Xvfb :$DISPLAY_NUM" 2>/dev/null || true
  Xvfb ":$DISPLAY_NUM" -screen 0 "$SCREEN" -nolisten tcp >/dev/null 2>&1 &
  XPID=$!
  local i=0
  while [[ $i -lt 30 ]] && [[ ! -e "/tmp/.X11-unix/X$DISPLAY_NUM" ]]; do sleep 1; i=$((i+1)); done
  [[ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ]] || warn "Xvfb chưa sẵn sàng"
  if [[ "${WIN_VNC:-0}" == "1" ]] && command -v x11vnc >/dev/null 2>&1; then
    say "Bật x11vnc trên :$DISPLAY_NUM (port 5900) để login lần đầu."
    x11vnc -display ":$DISPLAY_NUM" -forever -shared -nopw -rfbport 5900 >/dev/null 2>&1 &
  fi
}

# ============================================================ app + tự phục hồi + kill-switch
launch_one(){
  local k="$1"
  eval "local exe=\${${k}_LAUNCH:-}"
  eval "local args=\${${k}_ARGS:-}"
  eval "local cwd=\${${k}_CWD:-}"
  [[ -n "$exe" ]] || { warn "thiếu ${k}_LAUNCH — bỏ qua app $k"; return; }
  (
    local win_dir="${cwd:-${exe%\\*}}"
    win_dir="${win_dir%\\}"
    local unix_dir="${win_dir//\\//}"
    unix_dir="${unix_dir#C:}"; unix_dir="${unix_dir#c:}"
    [[ -d "$PDIR/drive_c$unix_dir" ]] && cd "$PDIR/drive_c$unix_dir" 2>/dev/null || true
    eval "local le=\${${k}_LOGIN_EMAIL:-}"; eval "local lp=\${${k}_LOGIN_PASSWORD:-}"
    local n=0 st wp waitsec
    while true; do
      # kill-switch: chỉ chạy app khi net đi qua tun (chống lộ IP VPS khi proxy chết)
      while true; do
        st=$(cut -d'|' -f2 "$PDIR/apps/.netstate" 2>/dev/null)
        [[ -z "$st" ]] && st=$(net_state)
        [[ "$st" == "UP" ]] && break
        warn "[$k] net=$st — chờ tunnel (không chạy app khi có nguy cơ lộ IP VPS)"
        sleep 10
      done
      say "[$k] chạy: $exe $args"
      printf '%s' "$(date +%s)" > "$PDIR/apps/.alive_${k}" 2>/dev/null || true
      n=$((n+1)); printf '%s' "$n" > "$PDIR/apps/.restarts_${k}" 2>/dev/null || true
      if [[ -n "$le" && -n "$lp" && ! -f "$PDIR/apps/.loggedin_${k}" ]] && [[ -x /usr/local/bin/login.sh ]]; then
        ( sleep 8; /usr/local/bin/login.sh "$k" ) &
      fi
      wine "$exe" $args 2>&1 | log_app "$k" &
      wp=$!
      # heartbeat: refresh mỗi 60s khi pipeline (wine+log) còn sống
      while kill -0 "$wp" 2>/dev/null; do
        printf '%s' "$(date +%s)" > "$PDIR/apps/.alive_${k}" 2>/dev/null || true
        sleep 60
      done
      wait "$wp" 2>/dev/null || true
      waitsec=$(( n>5 ? 120 : 15 ))
      warn "[$k] đã thoát (lần $n) — tự restart sau ${waitsec}s"
      sleep "$waitsec"
    done
  ) &
}

# ============================================================ main
trap 'say "nhận tín hiệu dừng — đóng wine"; wineserver -k 2>/dev/null || true; exit 0' TERM INT

wait_net
net_guard_loop &
( while true; do purge_logs; sleep "$PURGE_INTERVAL"; done ) &
first_run
install_apps
resolve_launch
start_x

if [[ -n "${WIN_APPS:-}" ]]; then
  for k in ${WIN_APPS//,/ }; do
    k="${k//[^A-Za-z0-9_]/}"
    [[ -n "$k" ]] && launch_one "$k"
  done
else
  warn "WIN_APPS rỗng — không có app nào được cấu hình. Container chỉ giữ Xvfb."
fi

say "Windows-box sẵn sàng (PID $$). Dùng x11vnc để login app lần đầu nếu cần."
while :; do sleep 3600 & wait $! 2>/dev/null || true; done

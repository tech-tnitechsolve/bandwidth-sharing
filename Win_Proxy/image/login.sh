#!/usr/bin/env bash
#=============================================================================
#  login.sh — TỰ ĐĂNG NHẬP app Windows bằng xdotool (thao tác GIỐNG NGƯỜI THẬT)
#-----------------------------------------------------------------------------
#  Chạy TRONG container Windows-box (có Xvfb). Dùng khi đã khai báo:
#     <KEY>_LOGIN_EMAIL / <KEY>_LOGIN_PASSWORD
#     <KEY>_WIN_TITLE     (tựa cửa sổ login, tùy chọn)
#     <KEY>_LOGIN_SCRIPT  (tùy chọn: kịch bản phím riêng)
#
#  "Chuẩn real": tốc độ gõ thay đổi ngẫu nhiên, nghỉ ngẫu nhiên giữa các bước,
#  di chuột tự nhiên, click tập trung cửa sổ — gần như thao tác tay của con người.
#
#  Cách dùng:
#     login.sh <KEY>            # tự login
#     login.sh <KEY> shot       # chỉ chụp màn hình hiện tại
#=============================================================================
set -uo pipefail

say(){ printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }

PDIR="${WIN_PREFIX_DIR:-/prefix}"
k="${1:-}"
[[ -n "$k" ]] || { warn "thiếu KEY app"; exit 1; }
k="${k//[^A-Za-z0-9_]/}"

#------------------------------------------------------------ helpers "giống người"
pause(){ sleep "0.$((1 + RANDOM % 6))"; }                       # 0.1–0.6s
rest(){   sleep "$((1 + RANDOM % 2))"; }                        # 1–2s
human_type(){                                                   # gõ với tốc độ thay đổi
  xdotool type --delay "$(( 45 + RANDOM % 85 ))" --clearmodifiers "$1" 2>/dev/null
}
mouse_move(){                                                   # di chuột tự nhiên tới x,y
  local x="${1:-400}" y="${2:-300}" steps=$(( 4 + RANDOM % 4 )) i
  for (( i=1; i<=steps; i++ )); do
    xdotool mousemove $(( x/steps*i )) $(( y/steps*i )) 2>/dev/null
    sleep "0.$((1 + RANDOM % 3))"
  done
}

shot(){
  local f="$PDIR/apps/${k}.png"
  if command -v scrot >/dev/null 2>&1; then
    scrot -o "$f" 2>/dev/null && say "đã chụp màn hình: ${f}"
  elif command -v import >/dev/null 2>&1; then
    import -window root "$f" 2>/dev/null && say "đã chụp màn hình: ${f}"
  else
    warn "không có scrot/import để chụp ảnh"
  fi
}

[[ "${2:-}" == "shot" ]] && { shot; exit 0; }

eval "email=\${${k}_LOGIN_EMAIL:-}"
eval "pass=\${${k}_LOGIN_PASSWORD:-}"
eval "title=\${${k}_WIN_TITLE:-}"
eval "script=\${${k}_LOGIN_SCRIPT:-}"

[[ -n "$email" && -n "$pass" ]] || { warn "$k: thiếu ${k}_LOGIN_EMAIL / ${k}_LOGIN_PASSWORD — bỏ qua auto-login (dùng VNC)."; exit 0; }

# đợi cửa sổ app xuất hiện (tối đa ~2 phút)
wid=""; i=0
for (( i=0; i<60; i++ )); do
  if [[ -n "$title" ]]; then
    wid=$(xdotool search --name "$title" 2>/dev/null | head -1)
  else
    wid=$(xdotool search --onlyvisible --class '.*' 2>/dev/null | head -1)
  fi
  [[ -n "$wid" ]] && break
  sleep 2
done
[[ -n "$wid" ]] || { warn "$k: không thấy cửa sổ app để login — chụp ảnh kiểm tra."; shot; exit 1; }

xdotool windowactivate --sync "$wid" 2>/dev/null; rest
mouse_move "$((200 + RANDOM % 500))" "$((200 + RANDOM % 300))"

if [[ -n "$script" ]]; then
  # kịch bản: các bước ngăn cách bởi ';' — type:X | key:X | sleep:N | click | click:X,Y
  IFS=';' read -r -a steps <<< "$script"
  s=""; xy=""
  for s in "${steps[@]}"; do
    s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
    [[ -z "$s" ]] && continue
    case "$s" in
      type:*) human_type "${s#type:}" ;;
      key:*)  xdotool key "${s#key:}" ;;
      sleep:*) sleep "${s#sleep:}" ;;
      click:*) xy="${s#click:}"; mouse_move "${xy%%,*}" "${xy##*,}"; xdotool click 1 ;;
      click)  xdotool click 1 ;;
      *) warn "bước không rõ: $s" ;;
    esac
    pause
  done
else
  # mặc định: click vào ô đầu -> gõ email -> Tab -> gõ password -> Enter (như người thật)
  xdotool click 1; rest
  human_type "$email"; rest
  xdotool key Tab; pause
  human_type "$pass"; rest
  mouse_move "$((300 + RANDOM % 300))" "$((300 + RANDOM % 200))"
  xdotool key Return
fi

sleep 8
shot
touch "$PDIR/apps/.loggedin_${k}"
say "$k: đã gửi thông tin login (ảnh xác minh: ${PDIR}/apps/${k}.png)"

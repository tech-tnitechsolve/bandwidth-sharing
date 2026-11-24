#!/usr/bin/env bash
################################################################################
# Tên file   : fix_bandwidth.sh (Hardened One-Shot Edition)
# Mục đích   : Đánh thức an toàn các node bị kẹt/treo socket trong 1 folder
# Đặc tính   :
#   - Đo thụ động qua Kernel theo từng PID container (Zero-Probe, không lộ IP)
#   - Cô lập 100% trong thư mục hiện tại (không ảnh hưởng folder khác)
#   - Giữ nguyên TUN, tôn trọng FlapGuard / Proxy-Dead / Restart Policy gốc
#   - Chỉ restart tối đa 1 lần (có cooldown 300s chống spam restart gây ban)
################################################################################
set -uo pipefail

# 1. Tự động nâng quyền sudo nếu đang chạy bằng user thường
if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

C_G='\033[0;32m'; C_Y='\033[0;33m'; C_B='\033[0;34m'; C_R='\033[0;31m'; C_C='\033[0;36m'; C_0='\033[0m'

FORCE_RESTART=0
COOLDOWN_SEC=300
WAIT_VERIFY_SEC=20

for arg in "$@"; do
  case "$arg" in
    --force) FORCE_RESTART=1 ;;
  esac
done

if [ ! -f "containernames.txt" ]; then
  echo -e "${C_R}[LỖI] Không tìm thấy file containernames.txt trong thư mục này!${C_0}"
  echo -e "${C_Y}Hãy chắc chắn bạn đặt file fix_bandwidth.sh trong cùng folder với internetIncome.sh.${C_0}"
  exit 1
fi

# Chống chạy chồng chéo với internetIncome.sh tại chính thư mục này
if [ -f "process.pid" ]; then
  II_PID=$(cat "process.pid" 2>/dev/null || true)
  if [[ -n "$II_PID" ]] && kill -0 "$II_PID" 2>/dev/null; then
    echo -e "${C_Y}[BỎ QUA] internetIncome.sh (PID $II_PID) đang thao tác trong thư mục này. Thoát an toàn.${C_0}"
    exit 0
  fi
fi

# Khóa flock riêng theo thư mục hiện tại để tránh chạy đè 2 tiến trình cùng lúc
LOCK_HASH=$(printf '%s' "$PWD" | md5sum 2>/dev/null | awk '{print $1}' || echo "default")
exec 9>"/tmp/ii-fix-bandwidth-${LOCK_HASH}.lock"
if ! flock -n 9; then
  echo -e "${C_Y}[BỎ QUA] Đang có một phiên fix_bandwidth.sh khác chạy tại thư mục này.${C_0}"
  exit 0
fi

STATE_DIR="/var/lib/ii-fix-bandwidth"
mkdir -p "$STATE_DIR" 2>/dev/null || true
find "$STATE_DIR" -name '*.last' -mtime +1 -delete 2>/dev/null || true

is_infra_container() {
  local name="$1" img="$2"
  case "$name" in
    tun*|gluetun*|hev*|tun2proxy*|dind*|adnadedind*|internetincomewatchtower*)
      return 0 ;;
  esac
  case "$img" in
    *tun2proxy*|*tun2socks*|*hev-socks5-tunnel*|*gluetun*|*docker:cli*|*watchtower*)
      return 0 ;;
  esac
  return 1
}

is_heavy_app() {
  local name="$1"
  case "$name" in
    ebesucher*|adnade*|depinext*|uprock*|customchrome*|customfirefox*)
      return 0 ;;
  esac
  return 1
}

in_flapguard_cooldown() {
  local name="$1"
  local f="/var/lib/ii-flapguard/${name}.state"
  [ -f "$f" ] || return 1
  local _rc _t stopped_at
  read -r _rc _t stopped_at < "$f" 2>/dev/null || return 1
  [ "${stopped_at:-0}" -gt 0 ] 2>/dev/null
}

in_repocket_proxy_dead() {
  local name="$1"
  local f="/var/lib/ii-repocket-watchdog/${name}.state"
  [ -f "$f" ] || return 1
  local _fc _la cooldown_until last_err now
  read -r _fc _la cooldown_until last_err < "$f" 2>/dev/null || return 1
  now=$(date +%s)
  [ "${last_err:-}" = "PROXY_DEAD" ] && [ "$now" -lt "${cooldown_until:-0}" ] 2>/dev/null
}

in_recent_fix_cooldown() {
  [ "$FORCE_RESTART" -eq 1 ] && return 1
  local name="$1"
  local f="$STATE_DIR/${name}.last"
  [ -f "$f" ] || return 1
  local last_ts now elapsed
  last_ts=$(cat "$f" 2>/dev/null || echo 0)
  now=$(date +%s)
  elapsed=$(( now - last_ts ))
  [ "$elapsed" -ge 0 ] && [ "$elapsed" -lt "$COOLDOWN_SEC" ]
}

# Đếm chuẩn xác số socket ESTAB thuộc riêng PID của container (không dính app anh em chung TUN)
count_container_estab() {
  local cname="$1" net_pid="$2"
  local c_pids pid_group ss_out cnt
  [[ "${net_pid:-0}" -gt 0 ]] 2>/dev/null || { echo 0; return; }
  c_pids=$(docker top "$cname" -eo pid 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}' || true)
  [ -z "$c_pids" ] && { echo 0; return; }
  pid_group=$(printf '%s\n' "$c_pids" | paste -sd'|' -)
  ss_out=$(nsenter -t "$net_pid" -n ss -tunap 2>/dev/null | awk '$2 == "ESTAB"' || true)
  [ -z "$ss_out" ] && { echo 0; return; }
  cnt=$(printf '%s\n' "$ss_out" | grep -cE "pid=(${pid_group})([^0-9]|$)" || true)
  cnt=${cnt//[^0-9]/}
  echo "${cnt:-0}"
}

echo -e "\n${C_B}======================================================================${C_0}"
echo -e "${C_B}>>> [GIAI ĐOẠN 1/3] QUÉT & KIỂM TRA AN TOÀN TRONG THƯ MỤC HIỆN TẠI <<<${C_0}"
echo -e "${C_C}    Thư mục: $PWD${C_0}"
echo -e "${C_B}======================================================================${C_0}"

WORKERS=()
INFRA_KEPT=0

while IFS= read -r cname || [ -n "$cname" ]; do
  cname=$(echo "$cname" | tr -d '\r' | xargs)
  [ -z "$cname" ] && continue
  [[ "$cname" == \#* ]] && continue

  cimg=$(docker inspect -f '{{.Config.Image}}' "$cname" 2>/dev/null || echo "")
  if [ -z "$cimg" ]; then
    echo -e "-> [${cname}] ${C_Y}Không tồn tại trong Docker (bỏ qua)${C_0}"
    continue
  fi

  if is_infra_container "$cname" "$cimg"; then
    INFRA_KEPT=$((INFRA_KEPT + 1))
    continue
  fi

  WORKERS+=("$cname")
done < "containernames.txt"

echo -e "-> Giữ nguyên hoàn toàn ${C_G}${INFRA_KEPT}${C_0} container hạ tầng (TUN/Gluetun/DinD)."

if [ ${#WORKERS[@]} -eq 0 ]; then
  echo -e "${C_Y}Không phát hiện container Platform nào trong containernames.txt.${C_0}"
  exit 0
fi

declare -A TUN_JUST_STARTED
declare -A SKIP_REASON
declare -A DID_RESTART_MAP
NEED_WAIT=0
ACTION_COUNT=0
EARNAPP_LOG_CLEANED=0
NOW=$(date +%s)

for w in "${WORKERS[@]}"; do
  info=$(docker inspect -f '{{.State.Status}}|{{.State.Pid}}|{{.State.StartedAt}}|{{.HostConfig.NetworkMode}}' "$w" 2>/dev/null || echo "")
  if [ -z "$info" ]; then
    SKIP_REASON["$w"]="Không tìm thấy container"
    continue
  fi

  IFS='|' read -r status pid started_at net_mode <<< "$info"

  # 1. Tôn trọng các cơ chế tự vệ của setup_vps.sh (tuyệt đối không gỡ ép)
  if in_flapguard_cooldown "$w"; then
    echo -e "-> [$w] ${C_Y}[BỎ QUA AN TOÀN] Đang trong thời gian khóa FlapGuard 12h${C_0}"
    SKIP_REASON["$w"]="Đang cooldown FlapGuard 12h"
    continue
  fi

  if in_repocket_proxy_dead "$w"; then
    echo -e "-> [$w] ${C_Y}[BỎ QUA AN TOÀN] Proxy nguồn đang chết (Repocket Watchdog tạm dừng)${C_0}"
    SKIP_REASON["$w"]="Proxy nguồn đang chết"
    continue
  fi

  # 2. Kiểm tra TUN/Gluetun cha thực tế qua NetworkMode (nếu có)
  if [[ "$net_mode" =~ ^container:(.+)$ ]]; then
    parent_tun="${BASH_REMATCH[1]}"
    tun_status=$(docker inspect -f '{{.State.Status}}' "$parent_tun" 2>/dev/null || echo "missing")
    if [ "$tun_status" = "missing" ]; then
      echo -e "-> [$w] ${C_R}[BỎ QUA] Tunnel cha $parent_tun không tồn tại${C_0}"
      SKIP_REASON["$w"]="Thiếu Tunnel cha $parent_tun"
      continue
    elif [ "$tun_status" != "running" ]; then
      echo -e "-> Tunnel cha $parent_tun đang [${tun_status^^}] -> ${C_Y}Bật lại Tunnel (1 lần)...${C_0}"
      docker start "$parent_tun" >/dev/null 2>&1 || true
      TUN_JUST_STARTED["$parent_tun"]=1
      sleep 4
      tun_status_after=$(docker inspect -f '{{.State.Status}}' "$parent_tun" 2>/dev/null || echo "unknown")
      if [ "$tun_status_after" != "running" ]; then
        echo -e "-> [$w] ${C_R}[BỎ QUA] Tunnel cha $parent_tun bật không lên${C_0}"
        SKIP_REASON["$w"]="Tunnel cha $parent_tun lỗi"
        continue
      fi
    elif [ -n "${TUN_JUST_STARTED[$parent_tun]:-}" ]; then
      # Tunnel vừa được bật ở node trước đó, chờ nhẹ để đồng bộ
      sleep 1
    fi
  fi

  # 3. Kiểm tra cooldown chống restart liên tiếp nếu vừa chạy script xong
  if in_recent_fix_cooldown "$w"; then
    # Nếu hiện tại đã lên kết nối thì xóa cooldown, giữ nguyên
    if [ "$status" = "running" ]; then
      conns=$(count_container_estab "$w" "$pid")
      if [ "$conns" -gt 0 ]; then
        rm -f "$STATE_DIR/${w}.last" 2>/dev/null || true
        echo -e "-> [$w] Đang có [${C_G}${conns}${C_0}] kết nối sống -> ${C_G}Cắn data tốt (GIỮ NGUYÊN)${C_0}"
        continue
      fi
    fi
    echo -e "-> [$w] ${C_Y}[BỎ QUA] Vừa được đánh thức chưa tới ${COOLDOWN_SEC}s (chống spam restart)${C_0}"
    SKIP_REASON["$w"]="Vừa đánh thức < ${COOLDOWN_SEC}s"
    continue
  fi

  # 4. Xử lý node đang tắt hoặc đang bị kẹt 0 socket (CHỈ TÁC ĐỘNG 1 LẦN)
  if [ "$status" != "running" ]; then
    echo -e "-> [$w] Đang ở trạng thái [${status^^}] -> ${C_Y}Khởi động lại 1 lần (giữ nguyên policy gốc)...${C_0}"
    if [[ "$w" == earnapp* && "$EARNAPP_LOG_CLEANED" -eq 0 && -d "earnappdata" ]]; then
      find earnappdata -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null || true
      EARNAPP_LOG_CLEANED=1
    fi
    docker start "$w" >/dev/null 2>&1 || true
    echo "$NOW" > "$STATE_DIR/${w}.last"
    DID_RESTART_MAP["$w"]=1
    NEED_WAIT=1
    ACTION_COUNT=$((ACTION_COUNT + 1))
    if is_heavy_app "$w"; then sleep 5; else sleep 0.6; fi
  else
    # Tránh restart nhầm container mới khởi tạo chưa kịp bắt tay mạng
    started_epoch=$(date -d "$started_at" +%s 2>/dev/null || echo 0)
    uptime_sec=$(( NOW - started_epoch ))
    if [ "$started_epoch" -gt 0 ] && [ "$uptime_sec" -lt 60 ]; then
      echo -e "-> [$w] Mới chạy ${uptime_sec}s (đang khởi tạo) -> ${C_G}GIỮ NGUYÊN${C_0}"
      continue
    fi

    conns=$(count_container_estab "$w" "$pid")
    if [ "$conns" -eq 0 ]; then
      # Kiểm tra lại sau 4s tránh bắt nhầm nhịp reconnect bình thường
      sleep 4
      conns=$(count_container_estab "$w" "$pid")
    fi

    if [ "$conns" -eq 0 ]; then
      echo -e "-> [$w] Kẹt socket [0 kết nối riêng] -> ${C_Y}Đánh thức 1 lần (Restart)...${C_0}"
      if [[ "$w" == earnapp* && "$EARNAPP_LOG_CLEANED" -eq 0 && -d "earnappdata" ]]; then
        find earnappdata -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null || true
        EARNAPP_LOG_CLEANED=1
      fi
      docker restart "$w" >/dev/null 2>&1 || true
      echo "$NOW" > "$STATE_DIR/${w}.last"
      DID_RESTART_MAP["$w"]=1
      NEED_WAIT=1
      ACTION_COUNT=$((ACTION_COUNT + 1))
      if is_heavy_app "$w"; then sleep 5; else sleep 0.6; fi
    else
      rm -f "$STATE_DIR/${w}.last" 2>/dev/null || true
      echo -e "-> [$w] Đang có [${C_G}${conns}${C_0}] kết nối sống -> ${C_G}Cắn data tốt (GIỮ NGUYÊN)${C_0}"
    fi
  fi
done

echo -e "\n${C_B}======================================================================${C_0}"
echo -e "${C_B}>>> [GIAI ĐOẠN 2/3] CHỜ ${WAIT_VERIFY_SEC} GIÂY ĐỂ NODE BẮT TAY & ỔN ĐỊNH <<<${C_0}"
echo -e "${C_B}======================================================================${C_0}"

if [ "$NEED_WAIT" -eq 1 ]; then
  if [ -t 1 ]; then
    for ((i=WAIT_VERIFY_SEC; i>=1; i--)); do
      echo -ne "  Đang chờ đường truyền ổn định & bắt tay với Proxy: ${i}s...  \r"
      sleep 1
    done
    echo -e "\n  -> Đã hết thời gian chờ ổn định!"
  else
    echo "  -> Đang chờ ${WAIT_VERIFY_SEC}s để các node mới đánh thức ổn định..."
    sleep "$WAIT_VERIFY_SEC"
  fi
else
  echo "  -> Toàn bộ node đủ điều kiện đều đang khỏe, bỏ qua thời gian chờ!"
fi

echo -e "\n${C_B}======================================================================${C_0}"
echo -e "${C_B}>>> [GIAI ĐOẠN 3/3] NGHIỆM THU KẾT QUẢ CUỐI CÙNG QUA KERNEL SOCKET <<<${C_0}"
echo -e "${C_B}======================================================================${C_0}"

SUCCESS=0
ACTIVE_TOTAL=0
SKIP_COUNT=0

for w in "${WORKERS[@]}"; do
  if [ -n "${SKIP_REASON[$w]:-}" ]; then
    SKIP_COUNT=$((SKIP_COUNT + 1))
    echo -e "-> Node $w: ${C_Y}[BỎ QUA AN TOÀN]${C_0} (${SKIP_REASON[$w]})"
    continue
  fi

  ACTIVE_TOTAL=$((ACTIVE_TOTAL + 1))
  status=$(docker inspect -f '{{.State.Status}}' "$w" 2>/dev/null || echo "unknown")
  pid=$(docker inspect -f '{{.State.Pid}}' "$w" 2>/dev/null || echo 0)
  conns=0
  if [ "$status" = "running" ] && [ "$pid" -gt 0 ]; then
    conns=$(count_container_estab "$w" "$pid")
  fi

  if [ "$conns" -gt 0 ]; then
    rm -f "$STATE_DIR/${w}.last" 2>/dev/null || true
    echo -e "-> Node $w: Có [${C_G}${conns}${C_0}] kết nối sống -> ${C_G}[HOẠT ĐỘNG ỔN ĐỊNH]${C_0}"
    SUCCESS=$((SUCCESS + 1))
  else
    if [ -n "${DID_RESTART_MAP[$w]:-}" ]; then
      echo -e "-> Node $w: Vẫn [0] kết nối sau khi đánh thức -> ${C_R}[CHƯA THÔNG] (Dừng tại đây, không restart lần 2 — hãy kiểm tra Proxy)${C_0}"
    else
      echo -e "-> Node $w: Có [${C_R}0${C_0}] kết nối -> ${C_R}[CHƯA THÔNG] (Kiểm tra lại IP/Port Proxy)${C_0}"
    fi
  fi
done

echo -e "\n${C_G}>>> KẾT QUẢ: ${SUCCESS}/${ACTIVE_TOTAL} NODE ĐANG KẾT NỐI TỐT | ĐÃ ĐÁNH THỨC: ${ACTION_COUNT} | BỎ QUA AN TOÀN: ${SKIP_COUNT} <<<${C_0}\n"
exit 0

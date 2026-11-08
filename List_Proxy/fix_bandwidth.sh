#!/usr/bin/env bash
################################################################################
# Tên file   : fix_bandwidth.sh
# Mục đích   : Tự động đánh thức & sửa lỗi nghẽn socket sau khi nạp lại data Proxy
# Đặc tính   : Đo thụ động qua Kernel (Zero-Probe) - Tuyệt đối KHÔNG LỘ IP VPS
# Chế độ chạy: One-Shot (Chạy 1 lần duy nhất, không lặp vô tận, tự thoát an toàn)
################################################################################
set -uo pipefail

# 1. Tự động nâng quyền sudo nếu đang chạy bằng user thường
if [ "$EUID" -ne 0 ]; then
  exec sudo bash "$0" "$@"
fi

C_G='\033[0;32m'; C_Y='\033[0;33m'; C_B='\033[0;34m'; C_R='\033[0;31m'; C_0='\033[0m'

if [ ! -f "containernames.txt" ]; then
  echo -e "${C_R}[LỖI] Không tìm thấy file containernames.txt trong thư mục này!${C_0}"
  echo -e "${C_Y}Hãy chắc chắn bạn đặt file fix_bandwidth.sh trong cùng folder với internetIncome.sh.${C_0}"
  exit 1
fi

echo -e "\n${C_B}======================================================================${C_0}"
echo -e "${C_B}>>> [GIAI ĐOẠN 1/3] QUÉT VÀ KIỂM TRA CHUYÊN SÂU NỘI BỘ THƯ MỤC <<<${C_0}"
echo -e "${C_B}======================================================================${C_0}"

WORKERS=$(grep -E '^(traffmon|pawns)' containernames.txt 2>/dev/null || true)
if [ -z "$WORKERS" ]; then
  echo -e "${C_Y}Không phát hiện container Traffmonetizer hoặc Pawns trong containernames.txt.${C_0}"
  exit 0
fi

NEED_WAIT=0

for w in $WORKERS; do
  tun_ctr=$(echo "$w" | sed -E 's/^(traffmon|pawns)/tun/')
  
  # Bảo vệ card mạng ảo TUN: Nếu tunnel bị tắt thì bật trước
  if docker inspect "$tun_ctr" >/dev/null 2>&1; then
    tun_status=$(docker inspect -f '{{.State.Status}}' "$tun_ctr" 2>/dev/null || echo "unknown")
    if [ "$tun_status" != "running" ]; then
      echo -e "-> Tunnel $tun_ctr đang tắt -> ${C_Y}Khởi động lại Tunnel...${C_0}"
      docker start "$tun_ctr" >/dev/null 2>&1 || true
      sleep 1
    fi
  fi

  # Gỡ án phạt FlapGuard cho worker này (nếu có)
  rm -f "/var/lib/ii-flapguard/${w}.state" 2>/dev/null || true

  # Kiểm tra trạng thái thực tế của Worker
  status=$(docker inspect -f '{{.State.Status}}' "$w" 2>/dev/null || echo "unknown")
  pid=$(docker inspect -f '{{.State.Pid}}' "$w" 2>/dev/null || echo 0)

  if [ "$status" != "running" ]; then
    echo -e "-> [$w] Đang ở trạng thái [${status^^}] -> ${C_Y}Đang kích hoạt lại...${C_0}"
    docker update --restart=unless-stopped "$w" >/dev/null 2>&1 || true
    docker start "$w" >/dev/null 2>&1 || true
    NEED_WAIT=1
  else
    # Đo lường kết nối chuẩn xác bằng wc -l (Luôn ra 1 số nguyên duy nhất)
    conns=0
    if [ "$pid" -gt 0 ]; then
      conns=$(nsenter -t "$pid" -n ss -tan state established 2>/dev/null | grep -v 'Recv-Q' | wc -l)
      conns=$(echo "$conns" | tr -dc '0-9')
      conns=${conns:-0}
    fi

    if [ "$conns" -eq 0 ]; then
      echo -e "-> [$w] Bị kẹt socket [0 kết nối] -> ${C_Y}Đang đánh thức (Restart)...${C_0}"
      docker restart "$w" >/dev/null 2>&1 || true
      NEED_WAIT=1
    else
      echo -e "-> [$w] Đang có [${C_G}${conns}${C_0}] kết nối sống -> ${C_G}Cắn data tốt (GIỮ NGUYÊN)${C_0}"
    fi
  fi
done

echo -e "\n${C_B}======================================================================${C_0}"
echo -e "${C_B}>>> [GIAI ĐOẠN 2/3] ĐỢI 12 GIÂY ĐỂ ĐƯỜNG HẦM THIẾT LẬP LẠI PHIÊN MỚI <<<${C_0}"
echo -e "${C_B}======================================================================${C_0}"

if [ "$NEED_WAIT" -eq 1 ]; then
  for i in {12..1}; do
    echo -ne "  Đang chờ hệ thống ổn định và bắt tay với Proxy: ${i}s... \r"
    sleep 1
  done
  echo -e "\n  -> Đường truyền đã sẵn sàng!"
else
  echo "  -> Toàn bộ node đều đang khỏe mạnh, bỏ qua thời gian chờ!"
fi

echo -e "\n${C_B}======================================================================${C_0}"
echo -e "${C_B}>>> [GIAI ĐOẠN 3/3] NGHIỆM THU KẾT QUẢ CUỐI CÙNG QUA KERNEL SOCKET <<<${C_0}"
echo -e "${C_B}======================================================================${C_0}"

SUCCESS=0
TOTAL=0

for w in $WORKERS; do
  TOTAL=$((TOTAL + 1))
  pid=$(docker inspect -f '{{.State.Pid}}' "$w" 2>/dev/null || echo 0)
  conns=0
  if [ "$pid" -gt 0 ]; then
    conns=$(nsenter -t "$pid" -n ss -tan state established 2>/dev/null | grep -v 'Recv-Q' | wc -l)
    conns=$(echo "$conns" | tr -dc '0-9')
    conns=${conns:-0}
  fi

  if [ "$conns" -gt 0 ]; then
    echo -e "-> Node $w: Có [${C_G}${conns}${C_0}] kết nối qua Proxy -> ${C_G}[HOẠT ĐỘNG HOÀN HẢO 100%]${C_0}"
    SUCCESS=$((SUCCESS + 1))
  else
    echo -e "-> Node $w: Có [${C_R}0${C_0}] kết nối -> ${C_R}[CHƯA THÔNG] (Hãy kiểm tra lại IP/Port của Proxy này)${C_0}"
  fi
done

echo -e "\n${C_G}>>> KẾT QUẢ TỔNG THỂ: ${SUCCESS}/${TOTAL} NODE ĐÃ KẾT NỐI VÀ ĐANG CẮN DATA THÀNH CÔNG! <<<${C_0}\n"
exit 0

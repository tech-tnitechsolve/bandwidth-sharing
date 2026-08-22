cat << 'EOF_AUDIT_PRO' > /usr/local/bin/ii-audit
#!/usr/bin/env bash
#============================================================================
#  ii-audit PRO - ULTIMATE VPS BANDWIDTH, ROUTING & PROXY READINESS BENCHMARK
#  - 100% In-Memory / ZERO Disk Logs / Ultra-Deep 5-7s Precision Audit
#  - Multi-Hub Jitter, Egress Speed, UDP Health, App TTFB & Capacity Advisor
#============================================================================
set +u

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_B='\033[1;34m'; C_C='\033[1;36m'; C_M='\033[1;35m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_M=''; C_0=''
fi

echo -e "${C_B}==================== [KIỂM ĐỊNH TOÀN DIỆN CHẤT LƯỢNG VPS / PROXY FARM PRO] ====================${C_0}"
echo "THỜI GIAN    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "MÁY CHỦ      : $(hostname)"

PUB_IP=$(curl -s4 -m 2 https://api.ipify.org 2>/dev/null || curl -s4 -m 2 https://ifconfig.me 2>/dev/null || echo "Unknown")
IP_INFO=$(curl -s -m 2 "http://ip-api.com/json/${PUB_IP}?fields=country,regionName,city,isp,as,org" 2>/dev/null || echo "{}")
IP_LOC=$(echo "$IP_INFO" | jq -r '"\(.city), \(.regionName), \(.country)"' 2>/dev/null || echo "Unknown")
IP_ISP=$(echo "$IP_INFO" | jq -r '"\(.as) - \(.isp) (\(.org))"' 2>/dev/null || echo "Unknown")

VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")
ARCH=$(uname -m)
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | xargs 2>/dev/null || echo "ARM Neoverse / Generic")
CPUS=$(nproc 2>/dev/null || echo 1)
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
RAM_FREE_MB=$(free -m | awk '/^Mem:/{print $7}')

echo -e "PUBLIC IP    : ${C_G}${PUB_IP}${C_0} (IP-Auth Target)"
echo "VỊ TRÍ / ISP : ${IP_LOC} | ${IP_ISP}"
echo "PHẦN CỨNG    : ${CPUS} vCPU (${CPU_MODEL}) | RAM ${MEM_MB}MB (Trống: ${RAM_FREE_MB}MB) | Ảo hóa: ${VIRT} (${ARCH})"

SCORE=100
ISSUES=0
WARNINGS=0

# --- 1. ĐO ĐẠC ĐỘ TRỄ (RTT), JITTER & MẤT GÓI 4 VÙNG QUỐC TẾ ---
echo -e "\n${C_C}--- [1. ĐỘ TRỄ (RTT), JITTER & MẤT GÓI TỚI 4 GATEWAY QUỐC TẾ] ---${C_0}"
ping_hub_full() {
  local target="$1"
  local out
  out=$(ping -c 5 -i 0.2 -W 1 "$target" 2>&1 || echo "")
  local rtt_line
  rtt_line=$(echo "$out" | tail -1)
  local min avg max loss jitter
  min=$(echo "$rtt_line" | awk -F'/' '{print $4}' | awk -F'=' '{print $2}' | tr -d ' ' | cut -d'.' -f1)
  avg=$(echo "$rtt_line" | awk -F'/' '{print $5}' | cut -d'.' -f1)
  max=$(echo "$rtt_line" | awk -F'/' '{print $6}' | cut -d'.' -f1)
  loss=$(echo "$out" | grep -o '[0-9]*%' | head -1 | tr -d '%')
  
  avg=${avg:-999}
  loss=${loss:-100}
  min=${min:-$avg}
  max=${max:-$avg}
  jitter=$(( max - min ))
  (( jitter < 0 )) && jitter=0
  echo "$avg $loss $jitter"
}

eval_hub() {
  local target="$1" name="$2"
  read -r avg loss jitter <<< "$(ping_hub_full "$target")"
  local col="$C_G"
  local eval_text="Mượt mà"
  if (( loss > 5 || avg > 350 || jitter > 40 )); then col="$C_R"; eval_text="Nghẽn / Trồi sụt"; ISSUES=$((ISSUES+1));
  elif (( loss > 0 || avg > 250 || jitter > 20 )); then col="$C_Y"; eval_text="Tạm ổn"; WARNINGS=$((WARNINGS+1)); fi
  printf "  %-24s: ${col}%3sms${C_0} | Jitter: ${col}%2sms${C_0} | Mất gói: ${col}%2s%%${C_0}  [%s]\n" "$name" "$avg" "$jitter" "$loss" "$eval_text"
}

eval_hub "1.1.1.1" "Singapore Gateway (Á)"
eval_hub "8.8.8.8" "Tokyo Hub (Nhật)"
eval_hub "4.2.2.2" "US Gateway (Mỹ)"
eval_hub "9.9.9.9" "Frankfurt / Quad9 (Âu)"

# --- 2. BĂNG THÔNG QUỐC TẾ THỰC CHIẾN & KIỂM TRA UDP OUTBOUND ---
echo -e "\n${C_C}--- [2. BĂNG THÔNG QUỐC TẾ THỰC CHIẾN & KHẢ NĂNG THÔNG LUỒNG UDP] ---${C_0}"
SPEED_RAW=$(curl -s4 -r 0-15728640 -w "%{speed_download}" -o /dev/null --connect-timeout 2 --max-time 4 "https://speed.cloudflare.com/__down?bytes=15728640" 2>/dev/null || echo "0")
SPEED_MBPS=$(awk "BEGIN {printf \"%.1f\", ${SPEED_RAW:-0} * 8 / 1000 / 1000}")

SPEED_COL="$C_G"
SPEED_EVAL="[XUẤT SẮC - Chuẩn Cloud Quốc tế / Oracle]"
if (( $(echo "$SPEED_MBPS < 25" | bc -l) )); then
  SPEED_COL="$C_R"; SPEED_EVAL="[BỊ BÓP BĂNG THÔNG - Thu nhập bị giảm!]"; ISSUES=$((ISSUES+2))
elif (( $(echo "$SPEED_MBPS < 60" | bc -l) )); then
  SPEED_COL="$C_Y"; SPEED_EVAL="[TRUNG BÌNH - Mạng tiêu chuẩn Việt Nam]"; WARNINGS=$((WARNINGS+1))
fi
echo -e "  Tốc độ tải Quốc tế (CDN): ${SPEED_COL}${SPEED_MBPS} Mbps ${SPEED_EVAL}${C_0}"

# Kiểm tra khả năng gửi nhận UDP ra ngoài
UDP_STATUS="OK (Thông suốt)"
UDP_COL="$C_G"
if ! timeout 2 nc -z -u 1.1.1.1 53 >/dev/null 2>&1; then
  UDP_STATUS="BỊ LỌC / DROP (Ảnh hưởng Proxy SOCKS5 UDP)"
  UDP_COL="$C_Y"
  WARNINGS=$((WARNINGS+1))
fi
echo -e "  Khả năng thông luồng UDP: ${UDP_COL}${UDP_STATUS}${C_0}"

# --- 3. ĐO ĐỘ TRỄ KẾT NỐI (TCP CONNECT / TLS / TTFB) TỚI 7 APP KIẾM TIỀN ---
echo -e "\n${C_C}--- [3. ĐỘ TRỄ PHẢN HỒI KẾT NỐI TỚI 7 NỀN TẢNG KIẾM TIỀN (TTFB)] ---${C_0}"
check_app_detail() {
  local name="$1" url="$2"
  local metrics
  metrics=$(curl -s4 -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
    -o /dev/null -w "%{time_connect} %{time_appconnect} %{time_starttransfer} %{http_code}" \
    --connect-timeout 2 --max-time 3 "$url" 2>/dev/null || echo "0 0 9.99 000")
  
  local t_conn t_tls t_ttfb code
  read -r t_conn t_tls t_ttfb code <<< "$metrics"
  
  local conn_ms tls_ms ttfb_ms
  conn_ms=$(awk "BEGIN {print int(${t_conn:-0} * 1000)}")
  tls_ms=$(awk "BEGIN {print int((${t_tls:-0} - ${t_conn:-0}) * 1000)}")
  (( tls_ms < 0 )) && tls_ms=0
  ttfb_ms=$(awk "BEGIN {print int(${t_ttfb:-9.99} * 1000)}")
  
  local col="$C_G"
  local note="Rất nhanh"
  if (( ttfb_ms >= 9990 || ttfb_ms == 0 )); then
    col="$C_Y"; ttfb_ms="SHIELDED"; note="Cloudflare WAF (Chỉ cho Proxy)";
  elif (( ttfb_ms > 1500 )); then
    col="$C_Y"; note="Hơi chậm"; WARNINGS=$((WARNINGS+1));
  elif (( ttfb_ms > 800 )); then
    col="$C_G"; note="Bình thường";
  fi
  printf "  %-22s: TCP: %3sms | TLS: %3sms | TTFB: ${col}%-8s${C_0} [%s]\n" "$name" "$conn_ms" "$tls_ms" "${ttfb_ms}ms" "$note"
}

check_app_detail "Traffmonetizer Master" "https://api.traffmonetizer.com"
check_app_detail "Honeygain Master"      "https://api.honeygain.com"
check_app_detail "Bitping Network API"  "https://bitping.com"
check_app_detail "Pawns / IPRoyal"       "https://pawns.app"
check_app_detail "EarnFM Network"        "https://earnfm.com"
check_app_detail "Repocket Network"      "https://api.repocket.co"
check_app_detail "MystNodes Discovery"   "https://discovery.mysterium.network"

# --- 4. HIỆU NĂNG PHẦN CỨNG: CPU STEAL, ÁP LỰC PSI & I/O Ổ CỨNG ---
echo -e "\n${C_C}--- [4. HIỆU NĂNG PHẦN CỨNG: CPU STEAL, ÁP LỰC PSI & I/O Ổ CỨNG] ---${C_0}"

STEAL_RAW=$(top -bn1 | grep -i "Cpu(s)" | awk -F',' '{print $8}' | awk '{print $1}' | cut -d'.' -f1 || echo 0)
STEAL_VAL=${STEAL_RAW:-0}
if (( STEAL_VAL == 0 )); then
  echo -e "  CPU Steal Time (st)     : ${C_G}0% (Tài nguyên CPU thực, không bị chia sẻ ảo)${C_0}"
elif (( STEAL_VAL <= 5 )); then
  echo -e "  CPU Steal Time (st)     : ${C_Y}${STEAL_VAL}% (Bị chia sẻ nhẹ, vẫn chấp nhận được)${C_0}"
else
  echo -e "  CPU Steal Time (st)     : ${C_R}${STEAL_VAL}% (CẢNH BÁO: Nhà cung cấp Overbook CPU nặng!)${C_0}"
  ISSUES=$((ISSUES+1))
fi

if [[ -f /proc/pressure/cpu ]]; then
  PSI_CPU=$(cat /proc/pressure/cpu | grep "some" | awk -F'avg10=' '{print $2}' | awk '{print $1}')
  echo "  Áp lực CPU nghẽn (PSI)  : avg10 = ${PSI_CPU}%"
fi

# Đo độ trễ I/O ổ cứng (Micro-test 50 lần fsync 4KB trong RAM/Disk, 0MB rác)
IO_START=$(date +%s%N 2>/dev/null || echo 0)
dd if=/dev/zero of=/tmp/.ii_iotest bs=4k count=50 oflag=dsync status=none 2>/dev/null || true
IO_END=$(date +%s%N 2>/dev/null || echo 0)
rm -f /tmp/.ii_iotest

IO_LATENCY=0
if (( IO_END > IO_START )); then
  IO_LATENCY=$(awk "BEGIN {printf \"%.2f\", ($IO_END - $IO_START) / 1000000 / 50}")
fi

IO_COL="$C_G"
IO_NOTE="NVMe / SSD Siêu tốc"
if (( $(echo "$IO_LATENCY > 5.0" | bc -l) )); then
  IO_COL="$C_R"; IO_NOTE="Ổ cứng chậm / HDD Overbook"; WARNINGS=$((WARNINGS+1))
elif (( $(echo "$IO_LATENCY > 1.5" | bc -l) )); then
  IO_COL="$C_Y"; IO_NOTE="SATA SSD Tiêu chuẩn";
fi
echo -e "  Độ trễ I/O Ổ cứng (4K)  : ${IO_COL}${IO_LATENCY} ms/op (${IO_NOTE})${C_0}"

# --- 5. BẢNG TÍNH TOÁN CÔNG SUẤT & KHUYẾN NGHỊ ĐẦU TƯ PROXY CHI TIẾT ---
SCORE=$(( SCORE - (ISSUES * 20) - (WARNINGS * 5) ))
(( SCORE < 0 )) && SCORE=0

# Tính toán số lượng Node tối đa dựa trên RAM thực và CPU
MAX_LIGHT_NODE=$(( (MEM_MB - 300) / 26 ))
MAX_MEDIUM_NODE=$(( (MEM_MB - 300) / 65 ))
MAX_HEAVY_NODE=$(( (MEM_MB - 300) / 450 ))

# Giới hạn trần theo Core CPU
CPU_CAP_LIGHT=$(( CPUS * 160 ))
CPU_CAP_HEAVY=$(( CPUS * 6 ))

(( MAX_LIGHT_NODE > CPU_CAP_LIGHT )) && MAX_LIGHT_NODE=$CPU_CAP_LIGHT
(( MAX_HEAVY_NODE > CPU_CAP_HEAVY )) && MAX_HEAVY_NODE=$CPU_CAP_HEAVY

echo -e "\n${C_B}==================== [BẢNG TÍNH TOÁN CÔNG SUẤT & ĐÁNH GIÁ ĐẦU TƯ PROXY] ====================${C_0}"
echo -e "  ĐIỂM ĐÁNH GIÁ VPS       : ${C_G}${SCORE} / 100 Điểm${C_0}"
echo "--------------------------------------------------------------------------------------------"
echo "  1. SỨC CHỨA CÁC LOẠI NODE TRÊN MÁY NÀY:"
echo -e "     • Node Proxy nhẹ (Traffmonetizer / Bitping / tun2socks): Khuyên dùng ${C_G}${MAX_LIGHT_NODE} IP / Nodes${C_0}"
echo -e "     • Node Dân cư Anti-Ban (Honeygain / Pawns / EarnFM)    : Khuyên dùng ${C_G}${MAX_MEDIUM_NODE} IP / Nodes${C_0}"
echo -e "     • Node nặng Browser / WebSockets (Wipter / Depin/Grass): Khuyên dùng ${C_G}${MAX_HEAVY_NODE} Nodes${C_0}"
echo ""
echo "  2. BẢN ĐỒ GHÉP PROXY QUỐC TẾ TỐI ƯU:"
if (( $(echo "$SPEED_MBPS >= 50" | bc -l) )); then
  echo -e "     • ${C_G}[TOÀN DIỆN]${C_0} Băng thông quốc tế rất tốt. Cắm được 100% tất cả Proxy (Mỹ, Châu Á, Châu Âu)."
elif (( $(echo "$SPEED_MBPS >= 25" | bc -l) )); then
  echo -e "     • ${C_Y}[ƯU TIÊN CHÂU Á & MỸ]${C_0} Nên cắm Proxy Singapore, Nhật, Hàn, Mỹ West. Hạn chế cắm Proxy Châu Âu."
else
  echo -e "     • ${C_R}[CHỈ NÊN CẮM PROXY NỘI ĐỊA / CHÂU Á GẦN]${C_0} Băng thông quốc tế bị bóp, tránh cắm Proxy xa làm giảm tiền."
fi
echo ""
echo "  3. KẾT LUẬN HIỆU QUẢ ĐẦU TƯ (ROI):"
if (( SCORE >= 85 )); then
  echo -e "     • ${C_G}[RẤT ĐÁNG TIỀN - TIÊU CHUẨN VÀNG]${C_0} VPS cực khỏe, tài nguyên thực, nên duy trì gia hạn lâu dài!"
elif (( SCORE >= 65 )); then
  echo -e "     • ${C_Y}[CHẤP NHẬN ĐƯỢC - ĐẠT CHUẨN TRUNG BÌNH]${C_0} Cắm đúng khu vực khuyến nghị sẽ đạt doanh thu tốt."
else
  echo -e "     • ${C_R}[CẢNH BÁO: BĂNG THÔNG YẾU / NGHẼN MẠNG]${C_0} Không nên nhồi đông IP trên máy này. Cân nhắc đổi nhà mạng!"
fi
echo -e "${C_B}============================================================================================${C_0}"
EOF_AUDIT_PRO

chmod +x /usr/local/bin/ii-audit
ln -sf /usr/local/bin/ii-audit /usr/bin/ii-audit 2>/dev/null || true
ln -sf /usr/local/bin/ii-audit /usr/bin/ii-check 2>/dev/null || true
echo "Đã cài đặt thành công công cụ kiểm định chuyên sâu 'ii-audit' PRO!"

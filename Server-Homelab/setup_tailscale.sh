#!/usr/bin/env bash
#============================================================================
#  setup_tailscale.sh (2026 TAILSCALE REMOTE ZERO-TRUST ENGINE)
#  Optimized for: Headless HomeLab, Remote Servers, WinSCP / SSH Access
#============================================================================
set -Eeuo pipefail

C_G='\033[1;32m'
C_Y='\033[1;33m'
C_R='\033[1;31m'
C_B='\033[1;34m'
C_C='\033[1;36m'
C_0='\033[0m'
C_BOLD='\033[1m'

log()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!!]${C_0} $*"; }
die()  { echo -e "${C_R}[XX]${C_0} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Can chay bang quyen root: sudo bash $0"

AUTH_KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --authkey)   AUTH_KEY="${2:-}"; shift 2 ;;
    --authkey=*) AUTH_KEY="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# 1. Kiểm tra & cài đặt Tailscale
if ! command -v tailscale >/dev/null 2>&1; then
  log "Dang tu dong cai dat Tailscale chinh hang..."
  curl -fsSL https://tailscale.com/install.sh | sh
else
  log "Tailscale da co san: $(tailscale version 2>/dev/null | head -n1 || echo 'Active')"
fi

# 2. Kích hoạt IP Forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-tailscale.conf <<'EOF_TS'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF_TS

# 3. Cấu hình Tường lửa UFW
if command -v ufw >/dev/null 2>&1; then
  log "Cap quyen Tuong lua UFW cho interface tailscale0..."
  ufw allow in on tailscale0 to any port 22 >/dev/null 2>&1 || true
  ufw allow 22/tcp >/dev/null 2>&1 || true
  echo "y" | ufw enable >/dev/null 2>&1 || true
fi

# 4. Kích hoạt mạng Tailscale
TARGET_USER="${SUDO_USER:-$USER}"
if [[ -n "$AUTH_KEY" ]]; then
  log "Dang tu dong dang nhap Tailscale bang Auth-Key..."
  tailscale up --authkey="$AUTH_KEY" --accept-dns=false --operator="$TARGET_USER" || true
else
  log "Khoi dong xac thuc Tailscale..."
  tailscale up --accept-dns=false --operator="$TARGET_USER" || true
fi

TS_IP=$(tailscale ip -4 2>/dev/null || echo "Dang cho ket noi...")
echo ""
echo -e "${C_C}==================== [TAILSCALE SETUP COMPLETE] ====================${C_0}"
echo -e "  IP TAILSCALE DUNG CHO WINSCP / SSH : ${C_G}${TS_IP}${C_0}"
echo -e "  Luu y: Vao https://login.tailscale.com/admin/machines de 'Disable key expiry'"
echo -e "${C_C}====================================================================${C_0}"

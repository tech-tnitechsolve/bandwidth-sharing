#!/usr/bin/env bash
#============================================================================
#  setup_tailscale.sh (2026 TAILSCALE REMOTE ZERO-TRUST ENGINE)
#  Optimized for: Headless HomeLab, Remote Servers, WinSCP / SSH Access
#  Usage:
#    sudo bash setup_tailscale.sh                     (Interactive Web Login)
#    sudo bash setup_tailscale.sh --authkey tskey-... (100% Silent Auto-Login)
#============================================================================
set -Eeuo pipefail

if [[ -t 1 ]]; then
  C_G='\033[1;32m'; C_Y='\033[1;33m'; C_R='\033[1;31m'; C_C='\033[1;36m'; C_0='\033[0m'
else
  C_G=''; C_Y=''; C_R=''; C_B=''; C_C=''; C_0=''
fi
log()  { echo -e "${C_G}[OK]${C_0} $*"; }
warn() { echo -e "${C_Y}[!!]${C_0} $*"; }
die()  { echo -e "${C_R}[XX]${C_0} $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Can chay bang quyen root: sudo bash $0"

AUTH_KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --authkey)   AUTH_KEY="${2:-}"; shift 2 ;;
    --authkey=*) AUTH_KEY="${1#*=}"; shift ;;
    *) warn "Bo qua tham so: $1" ; shift ;;
  esac
done

log "Kiem tra & Cai dat Tailscale chinh hang tu apt repo..."
if ! command -v tailscale >/dev/null 2>&1; then
  curl -fsSL https://tailscale.com/install.sh | sh
else
  log "Tailscale da duoc cai dat san: $(tailscale version | head -n1)"
fi

log "Bat IP Forwarding trong Linux Kernel cho Tailscale..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-tailscale.conf <<'EOF_TS_SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF_TS_SYSCTL

# Cấu hình Tường lửa UFW
if command -v ufw >/dev/null 2>&1; then
  log "Cap quyen Tuong lua UFW cho interface tailscale0..."
  ufw allow in on tailscale0 to any port 22 >/dev/null 2>&1 || true
  ufw allow 22/tcp >/dev/null 2>&1 || true
  echo "y" | ufw enable >/dev/null 2>&1 || true
fi

# Kích hoạt Tailscale
log "Khoi chay ket noi Tailscale..."
if [[ -n "$AUTH_KEY" ]]; then
  log "Phat hien Auth-Key -> Dang tu dong dang nhap (Silent Mode)..."
  tailscale up --authkey="$AUTH_KEY" --accept-dns=false --operator="${SUDO_USER:-$USER}"
else
  log "Chay che do xac thuc truyen thong..."
  tailscale up --accept-dns=false --operator="${SUDO_USER:-$USER}" || true
fi

TS_IP=$(tailscale ip -4 2>/dev/null || echo "Dang cho ket noi...")

echo ""
echo -e "${C_C}==================== [TAILSCALE SETUP COMPLETE] ====================${C_0}"
echo -e "  IP TAILSCALE DUNG CHO WINSCP / SSH : ${C_G}${C_BOLD}${TS_IP}${C_0}"
echo -e "  GHI NHO:"
echo -e "  1. Truy cap https://login.tailscale.com/admin/machines"
echo -e "  2. Bấm dấu '...' cạnh may chu nay -> Chọn 'Disable key expiry'"
echo -e "${C_C}====================================================================${C_0}"
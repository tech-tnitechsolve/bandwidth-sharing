#!/bin/bash
#=============================================================================
#  tier-b/qemu-win.sh — Windows THẬT (QEMU/KVM) cho nền tảng phát hiện Wine
#-----------------------------------------------------------------------------
#  KHI NÀO DÙNG: app Windows-only chạy không ổn định dưới Wine (Electron crash,
#  cần .NET, đọc SMBIOS/WMI thật, cần driver). Đây là "bản Ảo hóa Windows"
#  thật sự — fingerprint 100% giống máy thật vì CHÍNH LÀ Windows thật.
#
#  ĐÁNH ĐỔI: nặng hơn Wine rất nhiều.
#   - RAM/VM: 1.5–2GB (Win10 LTSC tối giản). VPS 8GB chạy ~3-4 VM + ZRAM.
#   - Disk/VM: overlay qcow2 ~3-8GB (chung 1 base image).
#
#  YÊU CẦU CHUẨN BỊ (1 lần):
#   1. Base image: Windows 10/11 LTSC/IoT qcow2, đã cài driver virtio-net/virtio-blk,
#      đã sysprep. Đặt đường dẫn vào BASE_IMAGE bên dưới (hoặc biến env).
#   2. TAP + TUN qua proxy: xem tier-b/README.md (dùng chính tun2socks/tun2proxy
#      của bạn — setup_vps.sh đã cài sẵn).
#   3. Cổng VNC nội bộ 127.0.0.1 để đăng nhập app lần đầu.
#=============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
IDENTITY_BIN="$ROOT/../image/identity.sh"
BASE_IMAGE="${BASE_IMAGE:-$ROOT/base/win10-ltsc.qcow2}"
RUN_DIR="$ROOT/vms"

MEM_MB="${MEM_MB:-1536}"
SMP="${SMP:-2}"
DISK_GB="${DISK_GB:-8}"

log(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[XX]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$BASE_IMAGE" ]] || die "thiếu base image: $BASE_IMAGE (xem tier-b/README.md)"
command -v qemu-system-x86_64 >/dev/null 2>&1 || die "thiếu qemu-system-x86_64 (apt install qemu-system-x86 ovmf)"

#---------------------- 1) sinh identity + lấy thông tin SMBIOS
usage(){ cat <<EOF
Cách dùng:
  qemu-win.sh --create <seed> <proxy_ip> [cc] [city] [tz]   # tạo VM + identity
  qemu-win.sh --run   <seed>                                 # chạy VM
  qemu-win.sh --stop  <seed>
  qemu-win.sh --list
EOF
}

seed_dir(){ printf '%s/%s' "$RUN_DIR" "$1"; }

smbios_args(){ # <dir> <seed>
  local j="$1/identity.json" seed="$2" mac oem model bv uuid serial bbserial
  [[ -f "$j" ]] || return 0
  # đọc giá trị từ identity.json (cùng bộ sinh như Wine — đồng bộ 2 tier)
  read -r mac     < <(grep -o '"mac": *"[^"]*"' "$j" | cut -d'"' -f4)
  read -r oem     < <(grep -o '"oem": *"[^"]*"' "$j" | cut -d'"' -f4)
  read -r model   < <(grep -o '"model": *"[^"]*"' "$j" | cut -d'"' -f4)
  read -r bv      < <(grep -o '"bios_vendor": *"[^"]*"' "$j" | cut -d'"' -f4)
  read -r uuid    < <(grep -o '"machine_guid": *"[^"]*"' "$j" | cut -d'"' -f4)
  serial=$(printf '%s' "$seed" | sha256sum | cut -c1-16)
  bbserial=$(printf '%s' "$seed" | sha256sum | cut -c17-32)
  printf '%s' \
    " -smbios type=0,vendor=\"$bv\",version=\"1.0.0\"" \
    " -smbios type=1,manufacturer=\"$oem\",product=\"$model\",serial=\"$serial\",uuid=\"$uuid\"" \
    " -smbios type=2,manufacturer=\"$oem\",product=\"$model\",serial=\"$bbserial\"" \
    " -smbios type=3,manufacturer=\"$oem\""
}

create(){
  local seed="$1" ip="$2" cc="${3:-}" city="${4:-}" tz="${5:-}" d
  d=$(seed_dir "$seed"); mkdir -p "$d"
  OUTDIR="$d" bash "$IDENTITY_BIN" gen "$seed" "$ip" "${cc:-}" "${city:-}" "${tz:-}" || die "sinh identity thất bại"
  # overlay qcow2 (chỉ ghi delta — tiết kiệm disk cho nhiều VM)
  if [[ ! -f "$d/overlay.qcow2" ]]; then
    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$d/overlay.qcow2" "${DISK_GB}G" || die "tạo overlay thất bại"
  fi
  log "đã tạo VM $seed ($d)"
}

run(){
  local seed="$1" d mac smbios vnc hex2
  d=$(seed_dir "$seed"); [[ -d "$d" ]] || die "chưa tạo VM (chạy --create trước)"
  read -r mac < <(grep -o '"mac": *"[^"]*"' "$d/identity.json" | cut -d'"' -f4)
  smbios=$(smbios_args "$d" "$seed")
  hex2=$(printf '%s' "$seed" | sha256sum | awk '{print substr($1,1,2)}')
  vnc=$(( 10 + 16#$hex2 % 200 ))   # 16# để chuyển hex -> số (tránh VNC port trùng nhau)

  # shellcheck disable=SC2086
  qemu-system-x86_64 -enable-kvm -cpu host -smp "$SMP" -m "$MEM_MB" \
    -drive file="$d/overlay.qcow2",if=virtio,format=qcow2 \
    -netdev tap,id=net0,ifname="tap${seed:0:8}",script=no,downscript=no \
    -device virtio-net-pci,netdev=net0,mac="$mac" \
    $smbios \
    -vnc "127.0.0.1:$vnc" -daemonize \
    -pidfile "$d/qemu.pid"
  log "VM $seed chạy (VNC 127.0.0.1:$vnc)"
}

stop(){
  local seed="$1" d
  d=$(seed_dir "$seed")
  [[ -f "$d/qemu.pid" ]] && kill "$(cat "$d/qemu.pid")" 2>/dev/null && rm -f "$d/qemu.pid"
  log "đã dừng VM $seed"
}

list(){ ls -1 "$RUN_DIR" 2>/dev/null || true; }

case "${1:-}" in
  --create) create "${2:?seed}" "${3:-0.0.0.0}" "${4:-}" "${5:-}" "${6:-}" ;;
  --run)    run "${2:?seed}" ;;
  --stop)   stop "${2:?seed}" ;;
  --list)   list ;;
  *)        usage ;;
esac

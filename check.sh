#!/bin/bash
# =============================================================================
#  check.sh — ORACLE ANTI-RECLAIM STATUS
#  Go: bash check.sh   |   Alias: echo "alias check='bash ~/check.sh'" >> ~/.bashrc
# =============================================================================

G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
P() { echo -e "  ${G}✓${N} $*"; }
F() { echo -e "  ${R}✗${N} $*"; }
I() { echo -e "  ${C}•${N} $*"; }

clear
echo ""
echo -e "${B}${C}╔══════════════════════════════════════════╗${N}"
echo -e "${B}${C}║   🛡️   ORACLE ANTI-RECLAIM STATUS     ║${N}"
echo -e "${B}${C}╚══════════════════════════════════════════╝${N}"

# ── CPU 3s ──
a1=$(awk '/^cpu /{print $2+$3+$4, $5}' /proc/stat)
read act1 idle1 <<< "$a1"
sleep 3
a2=$(awk '/^cpu /{print $2+$3+$4, $5}' /proc/stat)
read act2 idle2 <<< "$a2"
d_act=$((act2 - act1)); d_idle=$((idle2 - idle1))
CPU=$(( (d_act + d_idle) > 0 ? d_act * 100 / (d_act + d_idle) : 0 ))

echo -e "\n  ${B}🖥️  CPU${N}"
[ "$CPU" -ge 10 ] && P "CPU: ${G}${CPU}%${N} → DAT" || F "CPU: ${R}${CPU}%${N} → THAP"

# ── 3 Lop ──
echo -e "\n  ${B}⚡ 3 Lop bao ve${N}"
for s in oracle-keepalive oracle-fallback oracle-watchdog oracle-netalive; do
    status=$(systemctl is-active "$s" 2>/dev/null || echo "dead")
    case $s in
        oracle-keepalive) label="L1: lookbusy (chinh)" ;;
        oracle-fallback)  label="L2: fallback (du phong)" ;;
        oracle-watchdog)  label="L3: watchdog (giam sat)" ;;
        oracle-netalive)  label="   : network keepalive" ;;
    esac
    [ "$status" = "active" ] && echo -e "  ${G}●${N} $label → ${G}$status${N}" || echo -e "  ${R}●${N} $label → ${R}$status${N}"
done

# ── RAM + Uptime ──
echo -e "\n  ${B}🧠 RAM${N}"
I "$(free -m | awk '/Mem:/{printf "%d/%dMB (%.0f%%)",$3,$2,$3*100/$2}')"

echo -e "\n  ${B}⏱️  Uptime${N}"
I "$(uptime -p 2>/dev/null | sed 's/^up //')"

# ── Rule ──
echo ""
echo -e "  ${C}┌───────────────────────────────────────────┐${N}"
echo -e "  ${C}│ Oracle: CPU<20% AND Net<20% → reclaim    │${N}"
echo -e "  ${C}│ 3 Lop → CPU LUON >10% → PHA VO AND → OK │${N}"
echo -e "  ${C}└───────────────────────────────────────────┘${N}"

# ── Ket ──
echo ""
c1=$(systemctl is-active oracle-keepalive 2>/dev/null)
c2=$(systemctl is-active oracle-netalive  2>/dev/null)
c3=$(systemctl is-active oracle-watchdog  2>/dev/null)

if [ "$c1" = "active" ] && [ "$c2" = "active" ] && [ "$c3" = "active" ]; then
    echo -e "  ${B}${G}╔═══════════════════════════╗${N}"
    echo -e "  ${B}${G}║  🟢 VPS AN TOAN — OK! 🟢 ║${N}"
    echo -e "  ${B}${G}╚═══════════════════════════╝${N}"
else
    echo -e "  ${B}${R}╔══════════════════════════════════╗${N}"
    echo -e "  ${B}${R}║  🔴 CHAY LAI: sudo bash install.sh ║${N}"
    echo -e "  ${B}${R}╚══════════════════════════════════╝${N}"
fi
echo ""

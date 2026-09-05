bash -c 'ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && PKG="x86_64" || PKG="aarch64"; curl -sL "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-$PKG.tgz" | tar -xz -C /tmp/ speedtest; for s in "13623:Singapore (Singtel)" "21569:Japan Tokyo (i3D.net Transit)" "1536:Hong Kong (STC)" "18445:Taiwan Taipei (Chunghwa)"; do id="${s%%:*}"; name="${s#*:}"; echo "=================================================="; echo ">>> [TESTING] $name - Server ID: $id"; echo "=================================================="; /tmp/speedtest --accept-license --accept-gdpr -s $id; echo ""; done; rm -f /tmp/speedtest'


````````````````````````````````````````````````````````````````````````````````````````````
sudo apt update && sudo apt install -y vnstat iftop nload sysstat ethtool mtr-tiny && sudo systemctl enable --now vnstat && IFACE=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}') && watch -n 5 "clear; echo '===== NETWORK MONITOR ====='; echo 'Time: '\$(date); echo 'Interface: $IFACE'; echo; echo '--- Traffic realtime ---'; sar -n DEV 1 1 | grep -E 'IFACE|$IFACE'; echo; echo '--- Total traffic ---'; vnstat --oneline -i $IFACE; echo; echo '--- Connections ---'; ss -s; echo 'Established:' \$(ss -Htan state established | wc -l); echo; echo '--- Interface errors/drops ---'; ip -s link show $IFACE; echo; echo '--- Link status ---'; ethtool $IFACE 2>/dev/null | grep -E 'Speed|Duplex|Link detected'; echo; echo '--- Route/latency ---'; ping -c 1 -W 2 1.1.1.1"

sudo iftop -i "$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"

vnstat -d

```````````````````````````````````````````````````````````````````````````

bash -c 'ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && PKG="x86_64" || PKG="aarch64"; curl -sL "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-$PKG.tgz" | tar -xz -C /tmp/ speedtest; for s in "13623:Singapore (Singtel)" "21569:Japan Tokyo (i3D.net Transit)" "1536:Hong Kong (STC)" "18445:Taiwan Taipei (Chunghwa)"; do id="${s%%:*}"; name="${s#*:}"; echo "=================================================="; echo ">>> [TESTING] $name - Server ID: $id"; echo "=================================================="; /tmp/speedtest --accept-license --accept-gdpr -s $id; echo ""; done; rm -f /tmp/speedtest'
```````````````````````````````````````````````````````````````````````````
```````````````````````````````````````````````````````````````````````````
sudo apt update && sudo apt install -y vnstat sysstat ethtool mtr-tiny iproute2 procps && sudo systemctl enable --now vnstat && IFACE=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}') && sudo watch -n 10 "clear; echo '===== VPS NETWORK MONITOR ====='; date; echo 'Interface: $IFACE'; echo; echo '--- REAL TRAFFIC: RX/TX ---'; sar -n DEV 1 1 | awk -v i=$IFACE '\$2==i || \$1==\"Average:\" && \$3==i || \$1==\"IFACE\"'; echo; echo '--- TODAY / MONTH TRAFFIC ---'; vnstat -d -i $IFACE | tail -8; vnstat -m -i $IFACE | tail -5; echo; echo '--- CONNECTIONS ---'; ss -s; echo -n 'ESTABLISHED: '; ss -Htan state established | wc -l; echo; echo '--- TOP REMOTE CONNECTIONS ---'; ss -Htan state established | awk '{print \$5}' | sed -E 's/\[([^]]+)\]:[0-9]+/\1/; s/:[0-9]+$//' | sort | uniq -c | sort -nr | head -15; echo; echo '--- INTERFACE ERRORS / DROPS ---'; ip -s link show $IFACE | sed -n '1,8p'; echo; echo '--- LINK STATUS ---'; ethtool $IFACE 2>/dev/null | grep -E 'Speed|Duplex|Link detected'; echo; echo '--- DOCKER CONTAINERS ---'; docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null | head -20; echo; echo '--- DIRECT VPS LATENCY, NO PROXY ---'; for host in 1.1.1.1 8.8.8.8 9.9.9.9; do printf '%-15s ' \$host; ping -c 1 -W 2 \$host 2>/dev/null | tail -1; done"

```````````````````````````````````````````````````````````````````````````
```````````````````````````````````````````````````````````````````````````

sudo iftop -i "$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
```````````````````````````````````````````````````````````````````````````

xem them Giờ
```````````````````````````````````````````````````````````````````````````
vnstat -h -i eth0
```````````````````````````````````````````````````````````````````````````

xem them Ngày
```````````````````````````````````````````````````````````````````````````
vnstat -d -i eth0
```````````````````````````````````````````````````````````````````````````

Check bandwidth outbound
```````````````````````````````````````````````````````````````````````````
sar -n DEV 60 10 | grep eth0
```````````````````````````````````````````````````````````````````````````

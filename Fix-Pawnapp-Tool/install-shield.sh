#!/usr/bin/env bash
# ==============================================================================
# Pawns Shield - SOCKS5 Domain Sanitizer & IPv6 Leak Blocker (AsyncIO Epoll)
# Tương thích 100% với: curl -fsSL <url> | sudo bash
# Gỡ cài đặt        : curl -fsSL <url> | sudo bash -s -- --uninstall
# ==============================================================================
set -euo pipefail

SHIELD_PY="/usr/local/bin/pawns-shield.py"
SHIELD_SVC="/etc/systemd/system/pawns-shield.service"

# Chức năng gỡ cài đặt sạch sẽ (chống treo 90s nếu gỡ từ bản cũ)
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[*] Đang gỡ bỏ Pawns Shield..."
    systemctl disable pawns-shield 2>/dev/null || true
    timeout 3 systemctl stop pawns-shield 2>/dev/null || systemctl kill -s KILL pawns-shield 2>/dev/null || true
    iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true
    iptables -t nat -F PAWNS_SHIELD 2>/dev/null || true
    iptables -t nat -X PAWNS_SHIELD 2>/dev/null || true
    ip6tables -D OUTPUT -j PAWNS_SHIELD_V6 2>/dev/null || true
    ip6tables -F PAWNS_SHIELD_V6 2>/dev/null || true
    ip6tables -X PAWNS_SHIELD_V6 2>/dev/null || true
    ip6tables -D OUTPUT -p tcp -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true
    ip6tables -D OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    ip6tables -D OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    rm -f "$SHIELD_PY" "$SHIELD_SVC"
    systemctl daemon-reload
    echo "[+] Đã gỡ bỏ sạch sẽ Pawns Shield khỏi VPS!"
    exit 0
fi

# Yêu cầu quyền root
if [[ $EUID -ne 0 ]]; then
   echo "[!] Lỗi: Bạn phải chạy script này với quyền root (sudo)!" >&2
   exit 1
fi

echo "[*] 1/4. Đang kiểm tra môi trường hệ thống..."
command -v python3 >/dev/null 2>&1 || (apt-get update -y && apt-get install -y python3)
command -v iptables >/dev/null 2>&1 || (apt-get update -y && apt-get install -y iptables)
command -v ip6tables >/dev/null 2>&1 || (apt-get update -y && apt-get install -y iptables)

echo "[*] 2/4. Đang cài đặt bộ lọc bảo vệ mạng (pawns-shield.py)..."
cat << 'EOF' > "$SHIELD_PY"
#!/usr/bin/env python3
import asyncio
import json
import signal
import socket
import struct
import subprocess
import time
import urllib.request

SHIELD_PORT = 10888
SO_ORIGINAL_DST = 80
SO_MARK = 36
SHIELD_MARK = 0x1088

DNS_CACHE = {}
ACTIVE_TASKS = set()

def resolve_domain_sync(domain):
    now = time.time()
    cached = DNS_CACHE.get(domain)
    if cached and (now - cached["time"] < 300):
        return cached["ip"]
    try:
        req = urllib.request.Request(
            f"https://1.1.1.1/dns-query?name={domain}&type=A",
            headers={"Accept": "application/dns-json", "User-Agent": "Mozilla/5.0"}
        )
        with urllib.request.urlopen(req, timeout=3) as resp:
            data = json.loads(resp.read().decode())
            for ans in data.get("Answer", []):
                if ans.get("type") == 1:
                    ip = ans.get("data")
                    DNS_CACHE[domain] = {"ip": ip, "time": now}
                    return ip
    except Exception:
        pass
    try:
        ip = socket.gethostbyname(domain)
        DNS_CACHE[domain] = {"ip": ip, "time": now}
        return ip
    except Exception:
        pass
    d = domain.lower().strip(".")
    if d == "pawns.app" or d.endswith(".pawns.app"):
        return "185.110.216.178"
    return None

def should_sanitize(domain):
    d = domain.lower().strip(".")
    return "pawns" in d or d == "iproyal.com" or d.endswith(".iproyal.com")

async def pipe_stream(reader, writer):
    try:
        while True:
            data = await reader.read(131072)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except Exception:
            pass

async def relay_bidirectional(c_reader, c_writer, u_reader, u_writer):
    t1 = asyncio.create_task(pipe_stream(c_reader, u_writer))
    t2 = asyncio.create_task(pipe_stream(u_reader, c_writer))
    ACTIVE_TASKS.add(t1)
    ACTIVE_TASKS.add(t2)
    try:
        await asyncio.gather(t1, t2, return_exceptions=True)
    finally:
        if not t1.done():
            t1.cancel()
        if not t2.done():
            t2.cancel()
        ACTIVE_TASKS.discard(t1)
        ACTIVE_TASKS.discard(t2)

async def handle_client(c_reader, c_writer):
    task = asyncio.current_task()
    if task is not None:
        ACTIVE_TASKS.add(task)
    u_writer = None
    upstream_sock = None
    try:
        c_sock = c_writer.get_extra_info("socket")
        if c_sock is None:
            return
        c_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        c_sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

        orig_dst = c_sock.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
        orig_port, orig_ip_bytes = struct.unpack("!2xH4s8x", orig_dst)
        real_ip = socket.inet_ntoa(orig_ip_bytes)
        real_port = orig_port

        if real_port == SHIELD_PORT or real_ip in ("127.0.0.1", "0.0.0.0"):
            return

        loop = asyncio.get_running_loop()
        upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream_sock.setsockopt(socket.SOL_SOCKET, SO_MARK, SHIELD_MARK)
        upstream_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        upstream_sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        upstream_sock.setblocking(False)

        try:
            await asyncio.wait_for(loop.sock_connect(upstream_sock, (real_ip, real_port)), timeout=12)
        except Exception:
            try:
                c_writer.write(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
                await c_writer.drain()
            except Exception:
                pass
            return

        u_reader, u_writer = await asyncio.open_connection(sock=upstream_sock, limit=262144)
        upstream_sock = None

        header = await asyncio.wait_for(c_reader.readexactly(2), timeout=8)
        if header[0] != 5:
            u_writer.write(header)
            await u_writer.drain()
            await relay_bidirectional(c_reader, c_writer, u_reader, u_writer)
            return

        nmethods = header[1]
        methods = await asyncio.wait_for(c_reader.readexactly(nmethods), timeout=8)

        u_writer.write(header + methods)
        await u_writer.drain()

        up_method_resp = await asyncio.wait_for(u_reader.readexactly(2), timeout=10)
        c_writer.write(up_method_resp)
        await c_writer.drain()

        if up_method_resp[1] == 2:
            auth_ver = await asyncio.wait_for(c_reader.readexactly(1), timeout=8)
            ulen_b = await asyncio.wait_for(c_reader.readexactly(1), timeout=8)
            uname = await asyncio.wait_for(c_reader.readexactly(ulen_b[0]), timeout=8)
            plen_b = await asyncio.wait_for(c_reader.readexactly(1), timeout=8)
            passwd = await asyncio.wait_for(c_reader.readexactly(plen_b[0]), timeout=8)

            u_writer.write(auth_ver + ulen_b + uname + plen_b + passwd)
            await u_writer.drain()

            auth_resp = await asyncio.wait_for(u_reader.readexactly(2), timeout=10)
            c_writer.write(auth_resp)
            await c_writer.drain()
            if auth_resp[1] != 0:
                return

        req_header = await asyncio.wait_for(c_reader.readexactly(4), timeout=8)
        cmd, atyp = req_header[1], req_header[3]

        if atyp == 3:
            dlen_b = await asyncio.wait_for(c_reader.readexactly(1), timeout=8)
            domain_b = await asyncio.wait_for(c_reader.readexactly(dlen_b[0]), timeout=8)
            port_b = await asyncio.wait_for(c_reader.readexactly(2), timeout=8)
            domain = domain_b.decode("latin1")

            if should_sanitize(domain):
                dest_ip = await loop.run_in_executor(None, resolve_domain_sync, domain)
                if dest_ip:
                    new_req = struct.pack("!BBBB", 5, cmd, 0, 1) + socket.inet_aton(dest_ip) + port_b
                else:
                    new_req = req_header + dlen_b + domain_b + port_b
            else:
                new_req = req_header + dlen_b + domain_b + port_b
        elif atyp == 1:
            addr_b = await asyncio.wait_for(c_reader.readexactly(6), timeout=8)
            new_req = req_header + addr_b
        elif atyp == 4:
            addr_b = await asyncio.wait_for(c_reader.readexactly(18), timeout=8)
            new_req = req_header + addr_b
        else:
            return

        u_writer.write(new_req)
        await u_writer.drain()

        resp_header = await asyncio.wait_for(u_reader.readexactly(4), timeout=12)
        b_atyp = resp_header[3]
        if b_atyp == 1:
            rest = await asyncio.wait_for(u_reader.readexactly(6), timeout=12)
        elif b_atyp == 3:
            dlen_r = await asyncio.wait_for(u_reader.readexactly(1), timeout=12)
            rest = dlen_r + await asyncio.wait_for(u_reader.readexactly(dlen_r[0] + 2), timeout=12)
        elif b_atyp == 4:
            rest = await asyncio.wait_for(u_reader.readexactly(18), timeout=12)
        else:
            rest = b""

        c_writer.write(resp_header + rest)
        await c_writer.drain()
        if resp_header[1] != 0:
            return

        await relay_bidirectional(c_reader, c_writer, u_reader, u_writer)
    except Exception:
        pass
    finally:
        if task is not None:
            ACTIVE_TASKS.discard(task)
        try:
            c_writer.close()
        except Exception:
            pass
        if u_writer is not None:
            try:
                u_writer.close()
            except Exception:
                pass
        elif upstream_sock is not None:
            try:
                upstream_sock.close()
            except Exception:
                pass

def setup_universal_iptables():
    subprocess.run("iptables -t nat -N PAWNS_SHIELD 2>/dev/null || iptables -t nat -F PAWNS_SHIELD", shell=True)
    subprocess.run("iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("iptables -t nat -I OUTPUT 1 -j PAWNS_SHIELD", shell=True)

    subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -m mark --mark {hex(SHIELD_MARK)} -j RETURN", shell=True)
    for p in (1337, 22, 53, 80, 443, 8787):
        subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -p tcp --dport {p} -j RETURN", shell=True)
    for net in ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"):
        subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -d {net} -j RETURN", shell=True)
    subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -p tcp -j REDIRECT --to-ports {SHIELD_PORT}", shell=True)

    subprocess.run("ip6tables -D OUTPUT -p tcp -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -D OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -D OUTPUT -o lo -j ACCEPT 2>/dev/null || true", shell=True)

    subprocess.run("ip6tables -N PAWNS_SHIELD_V6 2>/dev/null || ip6tables -F PAWNS_SHIELD_V6", shell=True)
    subprocess.run("ip6tables -D OUTPUT -j PAWNS_SHIELD_V6 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -I OUTPUT 1 -j PAWNS_SHIELD_V6", shell=True)
    subprocess.run("ip6tables -A PAWNS_SHIELD_V6 -o lo -j RETURN 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -A PAWNS_SHIELD_V6 -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -A PAWNS_SHIELD_V6 -p tcp -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true", shell=True)

def cleanup_iptables(*args):
    subprocess.run("iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("iptables -t nat -F PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("iptables -t nat -X PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -D OUTPUT -j PAWNS_SHIELD_V6 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -F PAWNS_SHIELD_V6 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -X PAWNS_SHIELD_V6 2>/dev/null || true", shell=True)

async def run_server():
    setup_universal_iptables()
    server = await asyncio.start_server(
        handle_client, "127.0.0.1", SHIELD_PORT, backlog=4096, limit=262144
    )
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stop_event.set)
        except NotImplementedError:
            pass
    await stop_event.wait()
    cleanup_iptables()
    server.close()
    for t in list(ACTIVE_TASKS):
        t.cancel()
    await asyncio.sleep(0.05)

if __name__ == "__main__":
    try:
        asyncio.run(run_server())
    except KeyboardInterrupt:
        cleanup_iptables()
EOF

chmod +x "$SHIELD_PY"
python3 -m py_compile "$SHIELD_PY"

echo "[*] 3/4. Đang cấu hình dịch vụ Systemd..."
cat << 'EOF' > "$SHIELD_SVC"
[Unit]
Description=Pawns Shield Traffic Sanitizer (AsyncIO Epoll)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/pawns-shield.py
Restart=always
RestartSec=1
TimeoutStopSec=3
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "[*] 4/4. Đang kích hoạt dịch vụ (chuyển giao tức thì)..."
systemctl daemon-reload
systemctl enable pawns-shield >/dev/null 2>&1 || true
if systemctl is-active --quiet pawns-shield 2>/dev/null; then
    systemctl kill -s KILL pawns-shield 2>/dev/null || true
fi
systemctl start pawns-shield
sleep 1

echo "=================================================================="
echo "   CÀI ĐẶT THÀNH CÔNG! BẢN CHUẨN EPOLL ĐÃ CHÍNH THỨC HOẠT ĐỘNG! "
echo "=================================================================="
systemctl status pawns-shield --no-pager -l | head -n 10
ss -tlnp | grep 10888 || true
iptables -t nat -L PAWNS_SHIELD -n --line-numbers

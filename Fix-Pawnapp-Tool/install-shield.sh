#!/usr/bin/env bash
# ==============================================================================
# Pawns Shield - SOCKS5 Domain Sanitizer & IPv6 Leak Blocker (Optimized Edition)
# Bọc chuẩn chống Webshare suspend, giữ nguyên khóa IPv6, an toàn cho tool thứ 3
# ==============================================================================
set -euo pipefail

SHIELD_PY="/usr/local/bin/pawns-shield.py"
SHIELD_SVC="/etc/systemd/system/pawns-shield.service"

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[*] Đang gỡ bỏ Pawns Shield..."
    systemctl disable --now pawns-shield 2>/dev/null || true
    iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true
    iptables -t nat -F PAWNS_SHIELD 2>/dev/null || true
    iptables -t nat -X PAWNS_SHIELD 2>/dev/null || true
    ip6tables -D OUTPUT -j PAWNS_SHIELD_V6 2>/dev/null || true
    ip6tables -F PAWNS_SHIELD_V6 2>/dev/null || true
    ip6tables -X PAWNS_SHIELD_V6 2>/dev/null || true
    rm -f "$SHIELD_PY" "$SHIELD_SVC"
    systemctl daemon-reload
    echo "[+] Đã gỡ bỏ sạch sẽ Pawns Shield khỏi VPS!"
    exit 0
fi

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
import socket
import struct
import threading
import time
import subprocess
import urllib.request
import json
import signal
import sys

SHIELD_PORT = 10888
SO_ORIGINAL_DST = 80
SO_MARK = 36
SHIELD_MARK = 0x1088

DNS_CACHE = {}

def get_live_pawn_ip(domain="pawns.app"):
    now = time.time()
    if domain in DNS_CACHE and (now - DNS_CACHE[domain]["time"] < 300):
        return DNS_CACHE[domain]["ip"]
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
    return "185.110.216.178"

def is_pawns_domain(domain):
    d = domain.lower().strip(".")
    return (
        d == "pawns.app" or d.endswith(".pawns.app") or
        d == "iproyal.com" or d.endswith(".iproyal.com")
    )

def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)

def pipe_stream(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except: pass
        try: src.close()
        except: pass

def relay_bidirectional(client_sock, upstream_sock):
    upstream_sock.settimeout(None)
    client_sock.settimeout(None)
    t1 = threading.Thread(target=pipe_stream, args=(client_sock, upstream_sock), daemon=True)
    t2 = threading.Thread(target=pipe_stream, args=(upstream_sock, client_sock), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()

def handle_client(client_sock):
    upstream_sock = None
    try:
        client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client_sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        client_sock.settimeout(8)

        orig_dst = client_sock.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
        orig_port, orig_ip_bytes = struct.unpack("!2xH4s8x", orig_dst)
        real_ip = socket.inet_ntoa(orig_ip_bytes)
        real_port = orig_port

        # Chống vòng lặp tự trỏ
        if real_port == SHIELD_PORT or real_ip in ("127.0.0.1", "0.0.0.0"):
            client_sock.close()
            return

        upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream_sock.setsockopt(socket.SOL_SOCKET, SO_MARK, SHIELD_MARK)
        upstream_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        upstream_sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        upstream_sock.settimeout(12)

        try:
            upstream_sock.connect((real_ip, real_port))
        except Exception:
            try: client_sock.sendall(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            except: pass
            client_sock.close()
            return

        header = recv_exact(client_sock, 2)
        if not header:
            return

        if header[0] != 5:
            upstream_sock.sendall(header)
            relay_bidirectional(client_sock, upstream_sock)
            return

        nmethods = header[1]
        methods = recv_exact(client_sock, nmethods)
        if not methods:
            return

        upstream_sock.sendall(header + methods)
        up_method_resp = recv_exact(upstream_sock, 2)
        if not up_method_resp:
            return
        client_sock.sendall(up_method_resp)

        if up_method_resp[1] == 2:
            auth_ver = recv_exact(client_sock, 1)
            if not auth_ver: return
            ulen_b = recv_exact(client_sock, 1)
            if not ulen_b: return
            ulen = ulen_b[0]
            uname = recv_exact(client_sock, ulen)
            if uname is None: return
            plen_b = recv_exact(client_sock, 1)
            if not plen_b: return
            plen = plen_b[0]
            passwd = recv_exact(client_sock, plen)
            if passwd is None: return

            upstream_sock.sendall(auth_ver + bytes([ulen]) + uname + bytes([plen]) + passwd)
            auth_resp = recv_exact(upstream_sock, 2)
            if not auth_resp: return
            client_sock.sendall(auth_resp)
            if auth_resp[1] != 0: return

        req_header = recv_exact(client_sock, 4)
        if not req_header:
            return
        cmd, atyp = req_header[1], req_header[3]

        if atyp == 3:
            dlen_b = recv_exact(client_sock, 1)
            if not dlen_b: return
            dlen = dlen_b[0]
            domain_b = recv_exact(client_sock, dlen)
            target_port_bytes = recv_exact(client_sock, 2)
            if not domain_b or not target_port_bytes: return
            domain = domain_b.decode("latin1")

            # TẨY TRẮNG TÊN MIỀN PAWNS -> IPv4 ĐỘNG
            if is_pawns_domain(domain):
                dest_ip = get_live_pawn_ip(domain)
                new_req = struct.pack("!BBBB", 5, cmd, 0, 1) + socket.inet_aton(dest_ip) + target_port_bytes
            else:
                new_req = req_header + bytes([dlen]) + domain_b + target_port_bytes
        elif atyp == 1:
            addr_b = recv_exact(client_sock, 6)
            if not addr_b: return
            new_req = req_header + addr_b
        elif atyp == 4:
            addr_b = recv_exact(client_sock, 18)
            if not addr_b: return
            new_req = req_header + addr_b
        else:
            return

        upstream_sock.sendall(new_req)
        resp_header = recv_exact(upstream_sock, 4)
        if not resp_header:
            return
        b_atyp = resp_header[3]
        if b_atyp == 1:
            rest = recv_exact(upstream_sock, 6)
        elif b_atyp == 3:
            dlen_r = recv_exact(upstream_sock, 1)
            if not dlen_r: return
            rest = dlen_r + recv_exact(upstream_sock, dlen_r[0] + 2)
        elif b_atyp == 4:
            rest = recv_exact(upstream_sock, 18)
        else:
            rest = b""
        if rest is None:
            return

        client_sock.sendall(resp_header + rest)
        if resp_header[1] != 0:
            return

        relay_bidirectional(client_sock, upstream_sock)

    except Exception:
        pass
    finally:
        try: client_sock.close()
        except: pass
        if upstream_sock:
            try: upstream_sock.close()
            except: pass

def setup_universal_iptables():
    # 1. Custom Chain IPv4 NAT bọc SOCKS5 (giữ nguyên danh sách cổng né chuẩn gốc)
    subprocess.run("iptables -t nat -N PAWNS_SHIELD 2>/dev/null || iptables -t nat -F PAWNS_SHIELD", shell=True)
    subprocess.run("iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("iptables -t nat -I OUTPUT 1 -j PAWNS_SHIELD", shell=True)

    subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -m mark --mark {hex(SHIELD_MARK)} -j RETURN", shell=True)

    for p in (1337, 22, 53, 80, 443, 8787):
        subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -p tcp --dport {p} -j RETURN", shell=True)

    for net in ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"):
        subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -d {net} -j RETURN", shell=True)

    subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -p tcp -j REDIRECT --to-ports {SHIELD_PORT}", shell=True)

    # 2. Custom Chain IPv6 chống rò IPv6 (không flush làm mất rule IPv6 khác nếu có)
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
    sys.exit(0)

def main():
    setup_universal_iptables()
    signal.signal(signal.SIGTERM, cleanup_iptables)
    signal.signal(signal.SIGINT, cleanup_iptables)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    server.bind(("127.0.0.1", SHIELD_PORT))
    server.listen(4096)

    while True:
        client, _ = server.accept()
        t = threading.Thread(target=handle_client, args=(client,), daemon=True)
        t.start()

if __name__ == "__main__":
    main()
EOF

chmod +x "$SHIELD_PY"
python3 -m py_compile "$SHIELD_PY"

echo "[*] 3/4. Đang cấu hình dịch vụ Systemd..."
cat << 'EOF' > "$SHIELD_SVC"
[Unit]
Description=Pawns Shield Traffic Sanitizer
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/pawns-shield.py
Restart=always
RestartSec=2
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

echo "[*] 4/4. Đang kích hoạt dịch vụ..."
systemctl daemon-reload
systemctl enable --now pawns-shield
systemctl restart pawns-shield

echo "=================================================================="
echo "   CÀI ĐẶT THÀNH CÔNG! BẢN TỐI ƯU ĐÃ CHÍNH THỨC HOẠT ĐỘNG!      "
echo "=================================================================="
systemctl status pawns-shield --no-pager

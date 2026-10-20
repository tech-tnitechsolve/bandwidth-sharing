#!/usr/bin/env bash
# ==============================================================================
# Pawns Shield - SOCKS5 Domain Sanitizer for Webshare/Decodo (Turbo Edition)
# Tác dụng: Xóa sạch chữ "pawns.app" chống suspend proxy, bảo vệ cổng 1337
# ==============================================================================
set -euo pipefail

SHIELD_PY="/usr/local/bin/pawns-shield.py"
SHIELD_SVC="/etc/systemd/system/pawns-shield.service"
SYSCTL_CONF="/etc/sysctl.d/99-pawns-turbo.conf"

# Chức năng gỡ cài đặt
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[*] Đang gỡ bỏ Pawns Shield..."
    systemctl disable --now pawns-shield 2>/dev/null || true
    iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true
    iptables -t nat -F PAWNS_SHIELD 2>/dev/null || true
    iptables -t nat -X PAWNS_SHIELD 2>/dev/null || true
    ip6tables -D OUTPUT -p tcp -m string --string "pawns.app" --algo bm -j REJECT 2>/dev/null || true
    rm -f "$SHIELD_PY" "$SHIELD_SVC" "$SYSCTL_CONF"
    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reload
    echo "[+] Đã gỡ bỏ sạch sẽ Pawns Shield khỏi VPS!"
    exit 0
fi

# Yêu cầu quyền root
if [[ $EUID -ne 0 ]]; then
   echo "[!] Lỗi: Bạn phải chạy script này với quyền root (sudo)!" >&2
   exit 1
fi

echo "[*] 1/5. Đang kiểm tra môi trường hệ thống..."
command -v python3 >/dev/null 2>&1 || (apt-get update -y && apt-get install -y python3)
command -v iptables >/dev/null 2>&1 || (apt-get update -y && apt-get install -y iptables)

echo "[*] 2/5. Đang tối ưu thông số nhân Linux (Chống kẹt socket, tăng tốc băng thông)..."
cat << 'EOF' > "$SYSCTL_CONF"
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535
fs.file-max = 2097152
EOF
sysctl --system >/dev/null 2>&1 || true

echo "[*] 3/5. Đang cài đặt bộ lọc bảo vệ mạng (pawns-shield.py)..."
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

# Cache tĩnh Cloudflare DoH cho Pawns
DNS_CACHE = {
    "pawns.app": {"ip": "185.110.216.178", "time": time.time() + 86400 * 30},
    "bootstrap.pawns.app": {"ip": "178.156.140.194", "time": time.time() + 86400 * 30}
}

def get_live_pawn_ip(domain="pawns.app"):
    now = time.time()
    if domain in DNS_CACHE and (now - DNS_CACHE[domain]["time"] < 600):
        return DNS_CACHE[domain]["ip"]
    try:
        # Ưu tiên phân giải siêu tốc qua resolver Linux (chỉ 1ms)
        ip = socket.gethostbyname(domain)
        DNS_CACHE[domain] = {"ip": ip, "time": now}
        return ip
    except Exception:
        pass
    try:
        req = urllib.request.Request(
            f"https://1.1.1.1/dns-query?name={domain}&type=A",
            headers={"Accept": "application/dns-json"}
        )
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read().decode())
            for ans in data.get("Answer", []):
                if ans.get("type") == 1:
                    ip = ans.get("data")
                    DNS_CACHE[domain] = {"ip": ip, "time": now}
                    return ip
    except Exception:
        pass
    return DNS_CACHE.get(domain, {}).get("ip", "185.110.216.178")

def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk: return None
        buf.extend(chunk)
    return bytes(buf)

def pipe_stream(src, dst):
    try:
        while True:
            data = src.recv(131072)
            if not data: break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except: pass

def handle_client(client_sock):
    upstream_sock = None
    try:
        # Triệt tiêu độ trễ gom gói Nagle
        client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        orig_dst = client_sock.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
        orig_port, orig_ip_bytes = struct.unpack("!2xH4s8x", orig_dst)
        real_ip = socket.inet_ntoa(orig_ip_bytes)
        real_port = orig_port

        # Chống vòng lặp tự trỏ (Self-loop)
        if real_port == SHIELD_PORT or real_ip in ("127.0.0.1", "0.0.0.0"):
            client_sock.close()
            return

        upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream_sock.setsockopt(socket.SOL_SOCKET, SO_MARK, SHIELD_MARK)
        upstream_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        upstream_sock.settimeout(12)
        
        try:
            upstream_sock.connect((real_ip, real_port))
        except Exception:
            try: client_sock.sendall(b"\x05\x05\x00\x01\x00\x00\x00\x00\x00\x00")
            except: pass
            client_sock.close()
            return

        header = recv_exact(client_sock, 2)
        if not header: return

        if header[0] != 5:
            upstream_sock.sendall(header)
            t = threading.Thread(target=pipe_stream, args=(upstream_sock, client_sock), daemon=True)
            t.start()
            pipe_stream(client_sock, upstream_sock)
            t.join(timeout=300)
            return

        nmethods = header[1]
        methods = recv_exact(client_sock, nmethods)
        if not methods: return

        upstream_sock.sendall(header + methods)
        up_method_resp = recv_exact(upstream_sock, 2)
        if not up_method_resp: return
        client_sock.sendall(up_method_resp)

        if up_method_resp[1] == 2:
            auth_ver = recv_exact(client_sock, 1)
            if not auth_ver: return
            ulen = recv_exact(client_sock, 1)[0]
            uname = recv_exact(client_sock, ulen)
            plen = recv_exact(client_sock, 1)[0]
            passwd = recv_exact(client_sock, plen)

            upstream_sock.sendall(auth_ver + bytes([ulen]) + uname + bytes([plen]) + passwd)
            auth_resp = recv_exact(upstream_sock, 2)
            if not auth_resp: return
            client_sock.sendall(auth_resp)
            if auth_resp[1] != 0: return

        req_header = recv_exact(client_sock, 4)
        if not req_header: return
        cmd, atyp = req_header[1], req_header[3]

        if atyp == 3:
            dlen = recv_exact(client_sock, 1)[0]
            domain = recv_exact(client_sock, dlen).decode("latin1")
            target_port_bytes = recv_exact(client_sock, 2)

            # TẨY TRẮNG TÊN MIỀN PAWNS
            if "pawns" in domain.lower():
                dest_ip = get_live_pawn_ip(domain)
                new_req = struct.pack("!BBBB", 5, cmd, 0, 1) + socket.inet_aton(dest_ip) + target_port_bytes
            else:
                new_req = req_header + bytes([dlen]) + domain.encode("latin1") + target_port_bytes
        elif atyp == 1:
            new_req = req_header + recv_exact(client_sock, 4) + recv_exact(client_sock, 2)
        else:
            return

        upstream_sock.sendall(new_req)
        resp_header = recv_exact(upstream_sock, 4)
        if not resp_header: return
        b_atyp = resp_header[3]
        if b_atyp == 1: rest = recv_exact(upstream_sock, 6)
        elif b_atyp == 3:
            dlen_resp = recv_exact(upstream_sock, 1)[0]
            rest = bytes([dlen_resp]) + recv_exact(upstream_sock, dlen_resp + 2)
        elif b_atyp == 4: rest = recv_exact(upstream_sock, 18)
        else: rest = b""

        client_sock.sendall(resp_header + rest)
        if resp_header[1] != 0: return

        # CHUYỂN TIẾP TRỌN VẸN (BẢO TOÀN DỮ LIỆU TẢI VỀ CỦA KHÁCH)
        upstream_sock.settimeout(None)
        client_sock.settimeout(None)
        
        down_thread = threading.Thread(target=pipe_stream, args=(upstream_sock, client_sock), daemon=True)
        down_thread.start()
        
        pipe_stream(client_sock, upstream_sock)
        
        # Đợi cho khách tải xong toàn bộ dữ liệu (tối đa 300s)
        down_thread.join(timeout=300)

    except Exception:
        pass
    finally:
        try: client_sock.close()
        except: pass
        if upstream_sock:
            try: upstream_sock.close()
            except: pass

def setup_universal_iptables():
    subprocess.run("iptables -t nat -N PAWNS_SHIELD 2>/dev/null || iptables -t nat -F PAWNS_SHIELD", shell=True)
    subprocess.run("iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("iptables -t nat -I OUTPUT 1 -j PAWNS_SHIELD", shell=True)

    # 1. Bỏ qua gói tin do chính Shield phát ra
    subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -m mark --mark {hex(SHIELD_MARK)} -j RETURN", shell=True)

    # 2. BẢO VỆ CỤM CỔNG 1337 CỦA DÀN CŨ (TUYỆT ĐỐI KHÔNG CHẠM VÀO)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 1337 -j RETURN", shell=True)

    # 3. Bỏ qua các cổng hệ thống và web trực tiếp
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 22 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 53 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 80 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 443 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 8787 -j RETURN", shell=True)

    # 4. BẢO VỆ MẠNG LOCAL & DOCKER (RFC 1918)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 127.0.0.0/8 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 10.0.0.0/8 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 172.16.0.0/12 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 192.168.0.0/16 -j RETURN", shell=True)

    # 5. CHỐT CHẶN VẠN NĂNG: Chỉ bắt các kết nối TCP ra Public IP (Toàn bộ Proxy Webshare/Decodo)
    subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -p tcp -j REDIRECT --to-ports {SHIELD_PORT}", shell=True)

    # 6. Chống rò rỉ tên miền qua đường IPv6
    subprocess.run("ip6tables -A OUTPUT -p tcp -m string --string \"pawns.app\" --algo bm -j REJECT 2>/dev/null || true", shell=True)

def cleanup_iptables(*args):
    subprocess.run("iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("iptables -t nat -F PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("iptables -t nat -X PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -D OUTPUT -p tcp -m string --string \"pawns.app\" --algo bm -j REJECT 2>/dev/null || true", shell=True)
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

echo "[*] 4/5. Đang cấu hình dịch vụ Systemd..."
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

echo "[*] 5/5. Đang kích hoạt dịch vụ..."
systemctl daemon-reload
systemctl enable --now pawns-shield
systemctl restart pawns-shield

echo "=================================================================="
echo "   CẬP NHẬT THÀNH CÔNG! BẢN TURBO ĐÃ CHÍNH THỨC HOẠT ĐỘNG!      "
echo "=================================================================="
systemctl status pawns-shield --no-pager

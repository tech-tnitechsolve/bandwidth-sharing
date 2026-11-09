#!/usr/bin/env bash
# ==============================================================================
# Pawns Shield PRO - SOCKS5 Sanitizer, Egress Compliance & Anti-Abuse Firewall
# Tác dụng: Tẩy trắng "pawns.app", khóa sạch cổng hack/spam, chặn trang Auth cấm
# Tương thích 100%: Webshare, Decodo, IPv6 Leak Blocker, Không xung đột Docker
# ==============================================================================
set -euo pipefail

SHIELD_PY="/usr/local/bin/pawns-shield.py"
SHIELD_SVC="/etc/systemd/system/pawns-shield.service"

# Chức năng gỡ cài đặt sạch sẽ
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[*] Đang gỡ bỏ Pawns Shield..."
    systemctl disable --now pawns-shield 2>/dev/null || true
    iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true
    iptables -t nat -F PAWNS_SHIELD 2>/dev/null || true
    iptables -t nat -X PAWNS_SHIELD 2>/dev/null || true
    ip6tables -F OUTPUT 2>/dev/null || true
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

echo "[*] 2/4. Đang cài đặt bộ lọc bảo vệ mạng đa tầng (pawns-shield.py)..."
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

# 1. Danh sách các cổng cấm tuyệt đối (Chống Abuse/Hack/DMCA)
BLOCKED_PORTS = {
    22, 23, 25, 135, 137, 138, 139, 445, 465, 587, 
    1433, 2222, 3306, 3389, 5060, 5061, 5432, 5900, 
    6379, 6969, 27017, 51413,
    6881, 6882, 6883, 6884, 6885, 6886, 6887, 6888, 6889 # Torrent DMCA
}

# 2. Danh sách các domain Auth/Login hay bị cào mật khẩu nhất
BLOCKED_DOMAINS = {
    "accounts.google.com", "oauth2.googleapis.com", "login.microsoftonline.com",
    "login.live.com", "account.live.com", "login.yahoo.com",
    "passport.twitch.tv", "auth.netflix.com", "accounts.spotify.com",
    "login.steampowered.com", "help.steampowered.com", "auth.riotgames.com",
    "account.riotgames.com", "auth.roblox.com", "auth.ea.com",
    "login.battle.net", "id.sonyentertainmentnetwork.com", "appleid.apple.com",
    "idmsa.apple.com", "auth0.com", "auth.atlassian.com",
    "auth.ticketmaster.com", "identity.ticketmaster.com", "identity.axs.com", "auth.stubhub.com",
    "accounts.binance.com", "login.coinbase.com", "auth.revolut.com",
    "auth.kraken.com", "login.blockchain.com", "auth.paypal.com", "identity.paypal.com",
    "tenders.etimad.sa", "login.gov"
}

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
    return "185.110.216.178"

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
            data = src.recv(65536)
            if not data: break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except: pass
        try: src.close()
        except: pass

def handle_client(client_sock):
    upstream_sock = None
    try:
        client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        orig_dst = client_sock.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
        orig_port, orig_ip_bytes = struct.unpack("!2xH4s8x", orig_dst)
        real_ip = socket.inet_ntoa(orig_ip_bytes)
        real_port = orig_port

        if real_port == SHIELD_PORT or real_ip in ("127.0.0.1", "0.0.0.0"):
            client_sock.close()
            return

        upstream_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        upstream_sock.setsockopt(socket.SOL_SOCKET, SO_MARK, SHIELD_MARK)
        upstream_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        upstream_sock.settimeout(10)
        
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
            t1 = threading.Thread(target=pipe_stream, args=(client_sock, upstream_sock), daemon=True)
            t2 = threading.Thread(target=pipe_stream, args=(upstream_sock, client_sock), daemon=True)
            t1.start(); t2.start()
            t1.join(); t2.join()
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

        # Trích xuất Port đích
        target_domain = ""
        if atyp == 3:
            dlen = recv_exact(client_sock, 1)[0]
            target_domain = recv_exact(client_sock, dlen).decode("latin1").lower()
            target_port_bytes = recv_exact(client_sock, 2)
            dest_port = struct.unpack("!H", target_port_bytes)[0]
        elif atyp == 1:
            raw_ip = recv_exact(client_sock, 4)
            target_port_bytes = recv_exact(client_sock, 2)
            dest_port = struct.unpack("!H", target_port_bytes)[0]
        else:
            return

        # ==================== BỘ LỌC CHỐNG SUSPEND WEBSHARE/DECODO ====================
        # 1. Chặn các cổng độc hại (Port 22 SSH, 25 Mail, 3389 RDP, Torrent...)
        if dest_port in BLOCKED_PORTS:
            try: client_sock.sendall(b"\x05\x02\x00\x01\x00\x00\x00\x00\x00\x00") # 0x02 = Connection not allowed
            except: pass
            client_sock.close()
            return

        # 2. Chặn các trang Auth/Login nhạy cảm
        if target_domain and any(bad in target_domain for bad in BLOCKED_DOMAINS):
            try: client_sock.sendall(b"\x05\x02\x00\x01\x00\x00\x00\x00\x00\x00")
            except: pass
            client_sock.close()
            return

        # 3. TẨY TRẮNG TÊN MIỀN PAWNS (Biến pawns.app thành IP để Webshare không thấy chữ pawns)
        if atyp == 3:
            if "pawns" in target_domain:
                dest_ip = get_live_pawn_ip(target_domain)
                new_req = struct.pack("!BBBB", 5, cmd, 0, 1) + socket.inet_aton(dest_ip) + target_port_bytes
            else:
                new_req = req_header + bytes([len(target_domain)]) + target_domain.encode("latin1") + target_port_bytes
        else:
            new_req = req_header + raw_ip + target_port_bytes

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

        # 2 Luồng song song truyền nhận dữ liệu kiếm tiền (Full tốc độ 80/443)
        upstream_sock.settimeout(None)
        client_sock.settimeout(None)
        t1 = threading.Thread(target=pipe_stream, args=(client_sock, upstream_sock), daemon=True)
        t2 = threading.Thread(target=pipe_stream, args=(upstream_sock, client_sock), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()

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

    # Bỏ qua gói tin do chính Shield phát ra
    subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -m mark --mark {hex(SHIELD_MARK)} -j RETURN", shell=True)

    # Bảo vệ các cổng hệ thống và UI quản lý (Tuyệt đối không đụng vào)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 1337 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 22 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 53 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 80 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 443 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 8787 -j RETURN", shell=True)

    # BẢO VỆ MẠNG DOCKER & LOCAL (Không can thiệp vào các container Docker trên máy)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 127.0.0.0/8 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 10.0.0.0/8 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 172.16.0.0/12 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 192.168.0.0/16 -j RETURN", shell=True)

    # Bắt toàn bộ kết nối SOCKS5 của Tool Pawns Manager gửi tới Proxy Webshare/Decodo
    subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -p tcp -j REDIRECT --to-ports {SHIELD_PORT}", shell=True)

    # Khóa rò rỉ IPv6 (Ép 100% chạy IPv4 an toàn)
    subprocess.run("ip6tables -F OUTPUT 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -A OUTPUT -p tcp -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null || true", shell=True)

def cleanup_iptables(*args):
    subprocess.run("iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("iptables -t nat -F PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("iptables -t nat -X PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("ip6tables -F OUTPUT 2>/dev/null || true", shell=True)
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
echo "   CÀI ĐẶT THÀNH CÔNG! BẢN NÂNG CẤP ĐÃ CHÍNH THỨC HOẠT ĐỘNG!    "
echo "=================================================================="
systemctl status pawns-shield --no-pager

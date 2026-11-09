#!/usr/bin/env bash
# ==============================================================================
# Pawns Shield PRO (Bootstrap Matrix & Zero-Conflict Edition)
# Tích hợp: Bootstrap đa điểm (api.pawns.app, resi-api.pawns.app, iproyal.com)
# Tác dụng: Tẩy trắng 100% SOCKS5, khóa cổng hack/spam, bảo vệ an toàn tuyệt đối
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
    ip6tables -F OUTPUT 2>/dev/null || true
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

# 1. Các cổng độc hại bị cấm tuyệt đối (Không ảnh hưởng port 80/443)
BLOCKED_PORTS = {
    22, 23, 25, 135, 137, 138, 139, 445, 465, 587, 
    1433, 2222, 3306, 3389, 5060, 5061, 5432, 5900, 
    6379, 6969, 27017, 51413,
    6881, 6882, 6883, 6884, 6885, 6886, 6887, 6888, 6889 # Torrent DMCA
}

# 2. Các domain Auth/Login nhạy cảm hay bị cào mật khẩu
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

# BẢN ĐỒ BOOTSTRAP CHUẨN XÁC TỪNG DOMAIN CỦA PAWNS & IPROYAL
BOOTSTRAP_FALLBACK = {
    "pawns.app": "185.110.216.178",
    "api.pawns.app": "185.110.216.178",
    "resi-api.pawns.app": "93.189.62.83",
    "api.iproyal.com": "93.189.62.83",
    "iproyal.com": "185.110.216.178"
}

DNS_CACHE = {}
DNS_LOCK = threading.Lock()

def refresh_dns_bg(domain):
    try:
        req = urllib.request.Request(
            f"https://1.1.1.1/dns-query?name={domain}&type=A",
            headers={"Accept": "application/dns-json", "User-Agent": "Mozilla/5.0"}
        )
        with urllib.request.urlopen(req, timeout=2) as resp:
            data = json.loads(resp.read().decode())
            for ans in data.get("Answer", []):
                if ans.get("type") == 1:
                    with DNS_LOCK:
                        DNS_CACHE[domain] = {"ip": ans.get("data"), "time": time.time()}
                    return
    except Exception:
        pass

def get_live_pawn_ip(domain):
    now = time.time()
    clean_domain = domain.strip().lower()
    
    with DNS_LOCK:
        entry = DNS_CACHE.get(clean_domain)
        if entry:
            if now - entry["time"] > 300:
                threading.Thread(target=refresh_dns_bg, args=(clean_domain,), daemon=True).start()
            return entry["ip"]
    
    # Kích hoạt luồng ngầm phân giải ngay
    threading.Thread(target=refresh_dns_bg, args=(clean_domain,), daemon=True).start()
    
    # Trả về ngay IP Fallback chuẩn xác theo từng domain (0ms delay)
    for k, v in BOOTSTRAP_FALLBACK.items():
        if k in clean_domain:
            return v
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
        for s in (src, dst):
            try: s.shutdown(socket.SHUT_RDWR)
            except Exception: pass
            try: s.close()
            except Exception: pass

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
        upstream_sock.settimeout(8)
        
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
        # 1. Chặn cổng độc hại
        if dest_port in BLOCKED_PORTS:
            try: client_sock.sendall(b"\x05\x02\x00\x01\x00\x00\x00\x00\x00\x00")
            except: pass
            client_sock.close()
            return

        # 2. Chặn domain Auth nhạy cảm
        if target_domain and any(bad in target_domain for bad in BLOCKED_DOMAINS):
            try: client_sock.sendall(b"\x05\x02\x00\x01\x00\x00\x00\x00\x00\x00")
            except: pass
            client_sock.close()
            return

        # 3. TẨY TRẮNG TOÀN DIỆN: CẢ PAWNS LẪN IPROYAL
        if atyp == 3:
            if any(k in target_domain for k in ("pawns", "iproyal")):
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

        upstream_sock.settimeout(None)
        client_sock.settimeout(None)
        
        t = threading.Thread(target=pipe_stream, args=(upstream_sock, client_sock), daemon=True)
        t.start()
        pipe_stream(client_sock, upstream_sock)

    except Exception:
        pass
    finally:
        for s in (client_sock, upstream_sock):
            if s:
                try: s.close()
                except: pass

def setup_universal_iptables():
    subprocess.run("iptables -t nat -N PAWNS_SHIELD 2>/dev/null || iptables -t nat -F PAWNS_SHIELD", shell=True)
    subprocess.run("iptables -t nat -D OUTPUT -j PAWNS_SHIELD 2>/dev/null || true", shell=True)
    subprocess.run("iptables -t nat -I OUTPUT 1 -j PAWNS_SHIELD", shell=True)

    subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -m mark --mark {hex(SHIELD_MARK)} -j RETURN", shell=True)

    # Bảo vệ cổng hệ thống & Web UI 8787 & Server License 443
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 1337 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 22 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 53 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 80 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 443 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -p tcp --dport 8787 -j RETURN", shell=True)

    # Bảo vệ mạng nội bộ & Docker
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 127.0.0.0/8 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 10.0.0.0/8 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 172.16.0.0/12 -j RETURN", shell=True)
    subprocess.run("iptables -t nat -A PAWNS_SHIELD -d 192.168.0.0/16 -j RETURN", shell=True)

    subprocess.run(f"iptables -t nat -A PAWNS_SHIELD -p tcp -j REDIRECT --to-ports {SHIELD_PORT}", shell=True)

    # Khóa rò rỉ IPv6
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
Description=Pawns Shield Traffic Sanitizer (Bootstrap Matrix Edition)
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/pawns-shield.py
Restart=always
RestartSec=2
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "[*] 4/4. Đang kích hoạt dịch vụ..."
systemctl daemon-reload
systemctl enable --now pawns-shield
systemctl restart pawns-shield

echo "=================================================================="
echo "   CÀI ĐẶT THÀNH CÔNG! BẢN CHUẨN MATRIX ĐÃ HOẠT ĐỘNG!            "
echo "=================================================================="
systemctl status pawns-shield --no-pager

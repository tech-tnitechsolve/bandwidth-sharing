# WipterSlim

Mục tiêu: giữ image Wipter gốc để tránh sai flow, nhưng chạy theo mô hình InternetIncome: mỗi node đi qua tun2proxy sidecar, giới hạn tài nguyên, log nhỏ, tắt helper GUI không cần thiết.

## Dùng nhanh

```bash
cd WipterSlim
nano config.env      # điền WIPTER_EMAIL/WIPTER_PASSWORD
nano proxies.txt     # mỗi dòng 1 proxy socks5://host:port hoặc host:port
bash ./wipter-slim.sh start
bash ./wipter-slim.sh doctor
bash ./wipter-slim.sh stats
```

## Lệnh

```bash
bash ./wipter-slim.sh stop
bash ./wipter-slim.sh restart
bash ./wipter-slim.sh logs ws-app-0001
bash ./wipter-slim.sh inspect-one ws-app-0001
bash ./wipter-slim.sh slim-gui
```

## Cơ chế

- `ws-tun-0001`: tun2proxy container, route toàn bộ network qua proxy.
- `ws-app-0001`: Wipter official container, dùng `--network container:ws-tun-0001`.
- Tắt IPv6 trong tunnel.
- Memory/CPU/pids limit per container.
- Optional kill GUI helpers: `x11vnc`, `websockify`, `novnc`, `openbox`, `xterm`, `xte`.

Không kill `electron`, `Xvfb`, `wipter-tunnel` vì có thể làm app gốc hỏng.

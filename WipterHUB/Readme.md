# 🚀 WIPTER STANDALONE HUB - CẨM NANG TOÀN DIỆN TỪ A -> Z
> **Giải pháp tối ưu hóa cực hạn cho nền tảng Wipter:** Gom 10 – 1.000+ Proxy IPs vào 1 Container duy nhất, ngốn chỉ ~5.5MB RAM, 100% Real Device, tự co giãn áp suất bộ nhớ và tự động kích hoạt đường hầm Rathole Data Plane để truyền tải lưu lượng cào web.

---

## 📁 1. CẤU TRÚC THƯ MỤC CHUẨN
```text
HoangEUWip/
  ├── config.env              # Thông tin đăng nhập Email & Password
  ├── proxies.txt             # Danh sách Proxy (IP-Auth hoặc User:Pass)
  ├── Dockerfile              # Build Image Debian-Slim chuẩn Glibc (<50MB)
  ├── go.mod                  # Thư viện Go 1.22 + Gorilla WebSocket
  ├── main.go                 # Mã nguồn Master Multiplexer Engine hoàn chỉnh
  ├── wipter.sh               # Script điều khiển 1-Click & Phím tắt toàn VPS
  ├── devices_state.json      # (Tự sinh) Lưu định danh thiết bị vĩnh viễn
  └── README.md               # Toàn bộ hướng dẫn sử dụng này
```

---

## 📋 2. BẢNG TỔNG HỢP CÁC LỆNH ĐIỀU KHIỂN HÀNG NGÀY

Sau khi đã chạy lần đầu, bạn có thể đứng ở **bất kỳ thư mục nào** trên VPS để gõ:

| Lệnh gõ nhanh | Lệnh file gốc | Chức năng chi tiết |
| :--- | :--- | :--- |
| **`wipter doctor`** | `bash wipter.sh doctor` | **Khám bệnh tổng thể:** Bảng màu chi tiết từng IP sống/chết, trạng thái `[ACCEPTED]` đã được Wipter duyệt và lưu lượng cào web. |
| **`wipter stats`** | `bash wipter.sh stats` | **Kiểm tra RAM & CPU:** Xem trực tiếp container đang ăn bao nhiêu MB RAM thực tế (~5MB – 15MB). |
| **`wipter logs`** | `bash wipter.sh logs` | **Xem nhật ký hoạt động:** Báo cáo tổng hợp Telemetry 5 phút/lần (Bấm `Ctrl + C` để thoát). |
| **`wipter status`** | `bash wipter.sh status` | **Xem Uptime:** Kiểm tra trạng thái hoạt động của container. |
| **`wipter restart`** | `bash wipter.sh restart` | **Khởi động lại:** Dùng khi thêm/bớt Proxy trong `proxies.txt` hoặc thay đổi cấu hình. |
| **`wipter stop`** | `bash wipter.sh stop` | **Dừng an toàn:** Tự động lưu dữ liệu danh tính thiết bị vào `devices_state.json` và ngắt kết nối. |

---

## 🔄 3. HƯỚNG DẪN QUẢN LÝ PROXY (TĂNG / GIẢM / ĐỔI IP)

### Khi muốn giảm IP (Ví dụ: từ 100 xuống 90 IPs) hoặc thêm IP mới (Ví dụ: từ 10 lên 400 IPs):

1. Mở file `proxies.txt` để chỉnh sửa:
   ```bash
   nano ~/HoangEUWip/proxies.txt
   ```
   *(Xóa hoặc dán thêm dòng IP $\rightarrow$ Bấm `Ctrl + O` $\rightarrow$ `Enter` để lưu $\rightarrow$ `Ctrl + X` để thoát).*

2. Chạy lệnh áp dụng:
   ```bash
   wipter restart
   ```
👉 **Cơ chế an toàn:** Các IP cũ vẫn giữ nguyên 100% ID thiết bị trên Wipter (đọc từ `devices_state.json`), IP mới sẽ được đăng ký thêm và IP bị xóa sẽ tự động ngắt kết nối hoàn toàn.

---

## 🧹 4. CÁC LỆNH DỪNG, RESET VÀ XÓA SẠCH GỠ BỎ HOÀN TOÀN

### Mức 1: Tạm dừng và xóa container (Giữ nguyên ID thiết bị cũ)
```
bash wipter.sh stop
```

### Mức 2: Reset toàn bộ ID thiết bị (Cấp lại 100% ID máy mới toanh trên Wipter)
Dùng khi đổi tài khoản mới hoặc muốn Wipter nhận diện lại toàn bộ node mới:
```bash
wipter stop && rm -f ~/HoangEUWip/devices_state.json && wipter start
```

### Mức 3: Xóa sạch 100% Wipter khỏi VPS (Không để lại bất kỳ rác nào)
Chạy đoạn lệnh này để dọn sạch toàn bộ container, image, phím tắt và thư mục:
```bash
docker rm -f $(docker ps -aq --filter "name=wipter") 2>/dev/null || true
docker rmi -f wipter-engine:latest 2>/dev/null || true
rm -f /usr/local/bin/wipter /usr/bin/wipter
rm -rf ~/HoangEUWip
```

---

## 🩺 6. HƯỚNG DẪN ĐỌC BẢNG CHẨN ĐOÁN `wipter doctor`

Khi gõ lệnh `wipter doctor`, màn hình sẽ hiển thị trực quan:

```text
========================= [BẢNG CHẨN ĐOÁN CHI TIẾT TỪNG NODE WIPTER] =========================
 [TÌNH TRẠNG RAM VPS] : Trống 5580MB / Tổng 7941MB | [VÙNG CO GIÃN]: GREEN (MAX_PERFORMANCE)
---------------------------------------------------------------------------------------------------------------
 NODE ID   PROXY IP:PORT          HOSTNAME         STATUS             RELAY DATA   GHI CHÚ / TRẠNG THÁI DUYỆT
---------------------------------------------------------------------------------------------------------------
 Node 001  isp.decodo.com:10001   PC-3FD3AB        ONLINE (ALIVE)    14.25 MB     [ACCEPTED] Đã duyệt thiết bị 100%
 Node 002  isp.decodo.com:10003   PC-CAAD27        ONLINE (ALIVE)     8.10 MB     [ACCEPTED] Đã duyệt thiết bị 100%
 Node 003  isp.decodo.com:10002   PC-680C87        DEAD (ISOLATED)    0.00 MB     [PROXY_DEAD] socks5 timeout
---------------------------------------------------------------------------------------------------------------
 TỔNG KẾT: 2/3 Nodes ONLINE (66.7%) | 1 Nodes DEAD (Đang cách ly) | Băng thông: 22.35 MB
===============================================================================================================
```

* **`ONLINE (ALIVE)` (Màu xanh lá):** Node đang hoạt động hoàn hảo, sẵn sàng nhận traffic chia sẻ băng thông.
* **`[ACCEPTED] Đã duyệt thiết bị 100%`:** Máy chủ Wipter đã phản hồi chấp thuận thiết bị thành công.
* **`DEAD (ISOLATED)` (Màu đỏ):** Proxy bị chết/lỗi mạng, đang được đưa vào chế độ ngủ đông 5 phút (0% ngốn CPU/RAM). Khi proxy sống lại sẽ tự động kết nối lại.
* **`RELAY DATA`:** Dung lượng dữ liệu cào web thực tế mà node đã truyền tải thành công.

---

## 🛡️ 7. KHẮC PHỤC SỰ CỐ NHANH

1. **Lỗi `-bash: /usr/local/bin/wipter: No such file or directory` hoặc `command not found`:**
   * Chạy lệnh tạo lại phím tắt:
     ```bash
     chmod +x ~/HoangEUWip/wipter.sh
     ln -sf /root/HoangEUWip/wipter.sh /usr/local/bin/wipter
     ln -sf /root/HoangEUWip/wipter.sh /usr/bin/wipter
     hash -r
     ```
2. **Proxy IP-Authentication báo lỗi không kết nối được:**
   * Gõ `wipter start` để xem dòng `Public IPv4: x.x.x.x`.
   * Lấy IP đó dán vào mục **Whitelist IP** trên Dashboard nhà cung cấp Proxy (Decodo, Webshare...).
```
---

## 🔧 Production Hardening mới

Phiên bản hiện tại đã được tối ưu cho proxy dạng **IP-Authentication** và chạy song song với các container khác:

### Network mode

`wipter.sh` chạy container bằng Docker bridge thay vì `--net=host`:

```bash
--network bridge
-p 127.0.0.1:${WIPTER_DIAGNOSTIC_HOST_PORT:-28999}:28999
```

Lợi ích:

- Không chiếm namespace mạng của host.
- Không đụng port với container/source khác.
- Diagnostic API chỉ lắng nghe local host.
- Outbound của container vẫn SNAT qua IPv4 VPS, phù hợp các proxy IP-Auth đã whitelist IP VPS.

### Không probe IP ra ngoài

Startup script không còn gọi các dịch vụ như `api.ipify.org` hoặc `icanhazip.com`. Điều này tránh tạo request kiểm tra IP không cần thiết ra bên ngoài.

### Biến cấu hình runtime

Có thể chỉnh trong `config.env`:

```env
WIPTER_DIAGNOSTIC_HOST_PORT="28999"
WIPTER_MAX_CONN_GLOBAL="2000"
WIPTER_MAX_CONN_PER_NODE="32"
WIPTER_IDLE_TIMEOUT_SEC="120"
WIPTER_BLOCK_PRIVATE_TARGETS="true"
WIPTER_MEMORY_LIMIT=""
```

Ý nghĩa:

| Biến | Mặc định | Chức năng |
| :--- | :--- | :--- |
| `WIPTER_DIAGNOSTIC_HOST_PORT` | `28999` | Port host local cho `wipter doctor`. |
| `WIPTER_MAX_CONN_GLOBAL` | `2000` | Tổng số connection bridge tối đa toàn engine. |
| `WIPTER_MAX_CONN_PER_NODE` | `32` | Số connection bridge tối đa mỗi node. |
| `WIPTER_IDLE_TIMEOUT_SEC` | `120` | Tự đóng connection treo quá thời gian này. |
| `WIPTER_BLOCK_PRIVATE_TARGETS` | `true` | Chặn target localhost/private/link-local/metadata để tránh truy cập mạng nội bộ. |
| `WIPTER_MEMORY_LIMIT` | rỗng | Tùy chọn giới hạn RAM container, ví dụ `256m`. |

### Trạng thái mới trong `wipter doctor`

- `REG_PENDING`: websocket đã lên, đang chờ trạng thái đăng ký.
- `REG_REJECTED`: registration bị từ chối.
- `TUNNEL_RESTARTING`: tunnel process chết và supervisor đang tự restart.
- `TUNNEL_CONFIG_ERROR`: không ghi được file cấu hình tunnel.
- `[BACKPRESSURE]`: vượt giới hạn connection, engine từ chối connection mới để bảo vệ máy.
- `[BLOCKED_TARGET]`: request bị chặn vì trỏ vào IP private/internal/metadata.


### Diagnostic chuẩn hóa

`wipter doctor` hiển thị các chỉ số chính theo từng node:

| Cột | Ý nghĩa |
| :--- | :--- |
| `RELAY` | MB đã relay qua node. |
| `CONN` | Số connection đang mở của node. |
| `FAIL` | Số lần fail liên tiếp trước khi retry/quarantine. |
| `TUN` | Số lần tunnel process bị restart. |
| `ERR_CODE` | Mã lỗi rút gọn từ `last_error`, ví dụ `PROXY_DEAD`, `TUNNEL_EXIT`, `BLOCKED_TARGET`. |
| `GHI CHÚ` | Lỗi chi tiết đã sanitize. |

Muốn lấy dữ liệu đầy đủ dạng JSON để phân tích/log ngoài:

```bash
wipter json
```

Các field JSON quan trọng trong mỗi node:

```json
{
  "id": 1,
  "proxy_host": "proxy.example.com:1080",
  "device_name": "PC-ABC123",
  "status": "ONLINE",
  "status_since": "2026-09-02 12:00:00",
  "updated_at": "2026-09-02 12:01:00",
  "relay_bytes": 1048576,
  "relay_mb": "1.00",
  "last_error": "",
  "last_error_code": "",
  "last_error_at": "",
  "active_connections": 2,
  "local_bridge_port": 34567,
  "relay_ip": "x.x.x.x",
  "tunnel_restarts": 0,
  "fail_count": 0
}
```

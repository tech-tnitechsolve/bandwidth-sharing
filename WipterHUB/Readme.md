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
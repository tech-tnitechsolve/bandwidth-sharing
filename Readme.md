Hiện tượng chạy trên PC **1-2 ngày đầu rất mượt, nhưng sang ngày thứ 3, 4 trở đi có cảm giác mạng bị bóp (lag, drop tốc độ, tụt traffic)** là vấn đề kinh điển khi cắm node chia sẻ băng thông trên máy tính cá nhân.

Có **4 nguyên nhân chính** gây ra tình trạng này và cách xử lý triệt để cho từng trường hợp:

---

### Nguyên nhân 1: Modem / Router nhà mạng bị "tràn bảng NAT" (Chiếm 80% trường hợp)
* **Lý do:** Các app như Mysterium, Honeygain, EarnApp, Tun2socks mở ra **hàng chục ngàn kết nối TCP/UDP siêu nhỏ mỗi giờ**. 
* Modem do nhà mạng (Viettel, VNPT, FPT) cấp thường chỉ có RAM 128MB – 256MB và CPU rất yếu. Sau 2–3 ngày, bảng định tuyến **NAT Table** của modem bị đầy ứ (kẹt các kết nối cũ chưa kịp đóng), khiến modem bị treo ngầm, bóp nghẹt toàn bộ băng thông đi qua nó.
* **Cách kiểm tra:** Bạn thử **rút nguồn Modem nhà mạng ra cắm lại (Reboot)**. Nếu sau khi khởi động lại mạng mượt và node ăn traffic ầm ầm trở lại thì 100% thủ phạm là do Modem.
* **Cách khắc phục:**
  1. **Hẹn giờ reboot Modem:** Vào trang quản trị modem (`192.168.1.1`), tìm mục *Maintenance / Reboot Schedule* và đặt lịch cho modem tự khởi động lại vào **4h sáng mỗi ngày**.
  2. **Giải phóng kết nối nhanh hơn (trong VM):** Rút ngắn thời gian ngâm kết nối đã đóng để modem nhà mạng giải phóng RAM nhanh hơn.

---

### Nguyên nhân 2: Tính năng "Tiết kiệm điện" của Card mạng trên Windows Host
* **Lý do:** Khi bạn cắm máy 24/7, Windows sẽ tự động kích hoạt tính năng **Green Ethernet / Power Saving** trên card mạng LAN/Wi-Fi để giảm tiêu thụ điện, vô tình bóp tốc độ truyền tải sau nhiều giờ hoạt động liên tục.
* **Cách khắc phục trên Windows:**
  1. Nhấn `Windows + X` -> chọn **Device Manager**.
  2. Mở rộng mục **Network adapters** -> Chuột phải vào card mạng chính (Realtek / Intel...) -> Chọn **Properties**.
  3. Chuyển sang tab **Power Management**: **Bỏ tích** ô *"Allow the computer to turn off this device to save power"*.
  4. Chuyển sang tab **Advanced**, tìm và chuyển các mục sau về **Disabled**:
     * *Energy Efficient Ethernet (EEE)* -> **Disabled**
     * *Green Ethernet* -> **Disabled**
     * *Power Saving Mode* -> **Disabled**
  5. Vào Windows Settings -> *Power & Sleep* -> Đổi chế độ pin sang **High Performance** hoặc **Ultimate Performance**.

---

### Nguyên nhân 3: Bị Nhà mạng (ISP) bóp băng thông ẩn (FUP / DPI Shaping)
* **Lý do:** Gói cước mạng gia đình được thiết kế cho nhu cầu lướt web, xem video bình thường. Khi bạn chạy node 24/7, lưu lượng tải lên (Upload) liên tục chiếm dụng đường truyền với hàng triệu request P2P, hệ thống tự động của nhà mạng (DPI) sẽ đánh dấu IP của bạn là *"hoạt động bất thường / spam"* và tự động bóp luồng băng thông quốc tế của IP đó.
* **Cách xử lý:** 
  * Định kỳ 2-3 ngày, tắt modem khoảng **5 phút** rồi bật lại để nhà mạng cấp phát cho bạn một dải **IP WAN mới** (đổi IP sạch).

---

### Nguyên nhân 4: Nhu cầu của nền tảng giảm (Platform Demand Cycle)
* **Lý do:** Không phải do mạng của bạn bị bóp, mà do các nền tảng (Honeygain, Pawns, EarnApp...) phân phối task theo đợt. 
* Khi IP của bạn mới xuất hiện, hệ thống sẽ đẩy rất nhiều task thu thập dữ liệu (scraping). Sau 48h, khi đã quét xong các website trong khu vực của bạn, nhu cầu traffic sẽ chững lại và chỉ chạy ngắt quãng.

---

### 🛠️ Tinh chỉnh thêm trong `setup_vm.sh` để chống nghẽn Modem:

Để giúp máy ảo giải phóng kết nối nhanh gấp 3 lần, tránh làm modem nhà mạng bị tràn bảng NAT, bạn có thể chỉnh lại 2 dòng timeout này trong file `/etc/sysctl.d/99-internetincome-vm.conf` trên VM:

```ini
# Ép đóng các kết nối cũ nhanh hơn để giải cứu RAM của Modem nhà mạng
net.ipv4.tcp_fin_timeout = 10
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 10
net.netfilter.nf_conntrack_tcp_timeout_established = 300
```

### 💡 Lời khuyên vận hành:
Nếu bạn xác định chạy lâu dài: **Cài lịch tự khởi động lại Modem nhà mạng vào 4h sáng hàng ngày** là cách đơn giản và hiệu quả nhất để giữ tốc độ mạng luôn ở mức 100% công suất!

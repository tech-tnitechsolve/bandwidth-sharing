# 🌐 MASTER PRODUCTION PLAYBOOK: 24/7 BANDWIDTH SHARING & MULTI-PC HIGH-DENSITY FARM
> **Tài liệu hướng dẫn toàn diện hạ tầng ngoại cảnh:** Tối ưu hóa Modem Nhà Mạng -> Windows Host -> Phần mềm Ảo hóa (VMware/VBox) -> Mở rộng Multi-PC Farm & Tăng Băng Thông.

## 1. ĐỊNH MỨC GIỚI HẠN NODE & BĂNG THÔNG AN TOÀN

Khi chạy trên đường truyền mạng gia đình (gói 150 Mbps – 300 Mbps), việc phân bổ node cần tuân thủ bảng định mức sau:

| Hạng mục | Quy chuẩn an toàn | Hậu quả nếu vượt ngưỡng |
| :--- | :--- | :--- |
| **Loại kết nối** | **Bắt buộc cắm cáp LAN (Cat5e/Cat6)** | Wi-Fi sẽ quá nhiệt chip phát sóng, rớt gói tin và lag sau 24h. |
| **Node chạy IP Gốc** | **Tối đa 1 Node / 1 Nền tảng** trên 1 IP | Trùng IP gốc sẽ bị nền tảng hạ Quality Score, giảm 70% doanh thu. |
| **Node chạy qua Proxy** | **50 – 150 Proxies / 1 PC** (RAM 8G–16G)<br>**200 – 350 Proxies / 1 PC** (RAM 32G) | Mở quá nhiều proxy trên PC yếu sẽ tràn RAM và nghẽn CPU. |
| **Lưu lượng Upload** | **Dưới 3 TB – 5 TB / tháng / 1 đường mạng** | Vượt 5 TB/tháng sẽ bị hệ thống DPI nhà mạng đưa vào diện bóp luồng quốc tế. |

---

## 2. TỐI ƯU HÓA TOÀN DIỆN MODEM NHÀ MẠNG (ONT ROUTER)

Áp dụng trực tiếp trên trang quản trị Modem (`http://192.168.1.1` - Đăng nhập tài khoản `admin` / Mật khẩu là dãy **GPON SN** in hoa in ở tem đáy thiết bị, VD: `ZTEGDE291D38`):

### 🛠️ 4 Bước "mở khóa công suất" bắt buộc trên Modem:

1. **Hạ mức Firewall (Giảm tải CPU Modem):**
   * Vào `Internet` -> `Security` -> `Firewall` -> Chuyển **Firewall Level sang `Low`** -> Bấm **`Apply`**.
2. **TẮT BỎ Anti-DoS / Anti-hacking (Thủ phạm gây bóp mạng):**
   * Cuộn xuống mục *Anti-DoS Attack* -> *Anti-hacking* (mục giới hạn 100 kết nối/3 giây).
   * **BỎ TÍCH ô `Enable`** -> Bấm **`Apply`**.
3. **MỞ KHÓA Trần Kết Nối (Session Limit):**
   * Vào `Security` -> `Session Configuration`.
   * Chuyển **`Session Limit` sang `Off`** (Xóa bỏ hoàn toàn giới hạn 5.000 kết nối ngầm) -> Bấm **`Apply`**.
4. **BẬT DMZ (Mở thông toàn bộ cổng cho PC chạy LAN):**
   * Vào `Security` -> `DMZ` -> Chọn **`On`**.
   * Bấm *Select from the associated devices* -> Chọn đúng dòng chứa **Card mạng LAN** của PC (VD: `[DESKTOP-xxx] - IP: [192.168.1.2]`) -> Bấm **`Apply`**.
   * *(Lưu ý: Khi đã bật DMZ thì không cần tìm bật UPnP nữa vì DMZ đã bao quát mở 100% port)*.

---

## 3. TỐI ƯU HÓA MÁY TÍNH WINDOWS HOST (CHẠY 24/7 BỀN BỈ)

Thực hiện trên hệ điều hành Windows máy chủ cắm chạy máy ảo:

### A. Chế độ nguồn điện (Power Options):
1. Mở CMD quyền Administrator, dán lệnh sau để kích hoạt chế độ tối thượng:
   ```cmd
   powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
   ```
2. Mở *Control Panel -> Power Options* -> Chọn gói **`Ultimate Performance`** (hoặc `High Performance`).
3. Vào `Change plan settings` -> Đặt **Put the computer to sleep = `Never`**.
4. Bấm dòng xanh `Change advanced power settings`:
   * **Hard disk** -> *Turn off hard disk after* -> Điền **`0`** (Never).
   * **PCI Express** -> *Link State Power Management* -> Đổi thành **`Off`** *(Chống hạ nguồn khe cắm card mạng/NVMe)*.

### B. Tắt tiết kiệm điện Card mạng (Device Manager):
1. Nhấn `Windows + X` -> Chọn **Device Manager** -> Mở rộng **Network adapters**.
2. Chuột phải vào Card mạng LAN chính (Intel / Realtek) -> Chọn **Properties**:
   * **Tab `Power Management`:** **BỎ TÍCH** ô *"Allow the computer to turn off this device to save power"*.
   * **Tab `Advanced`:** Chuyển tất cả các mục sau về **`Disabled`**:
     * `Energy Efficient Ethernet (EEE)` -> **Disabled**
     * `Green Ethernet` -> **Disabled**
     * `Power Saving Mode` / `Gigabit Lite` -> **Disabled**

### C. Chặn Windows Update tự ý Restart nửa đêm:
1. Nhấn `Windows + R` -> gõ **`gpedit.msc`** -> Enter.
2. Điều hướng: `Computer Configuration` -> `Administrative Templates` -> `Windows Components` -> `Windows Update`.
3. Nhấp đúp vào: **`No auto-restart with logged on users for scheduled automatic updates installations`** -> Chọn **`Enabled`** -> Bấm **OK**.

### D. Loại trừ Windows Defender Antivirus:
* Vào `Windows Security` -> `Virus & threat protection` -> `Manage settings` -> `Exclusions` -> **Add an exclusion -> Folder** -> Trỏ đến thư mục chứa file máy ảo `.vmdk` / `.vdi` để Windows không ngốn CPU quét gói tin Docker.

---

## 4. TỐI ƯU HÓA PHẦN MỀM MÁY ẢO (VMWARE / VIRTUALBOX)

### A. Chuyển chế độ Card Mạng sang `Bridged Adapter` (BẮT BUỘC):
* **Tuyệt đối không dùng NAT Mode** (tránh bị nghẽn do 2 tầng định tuyến).
* **Cài đặt:**
  * **VMware Workstation:** Vào *VM Settings* -> *Network Adapter* -> Tích chọn **`Bridged: Connected directly to the physical network`**.
  * **VirtualBox:** Vào *Settings* -> *Network* -> *Attached to:* Chọn **`Bridged Adapter`** -> Trỏ đúng tên Card LAN vật lý của PC.
* 👉 *Tác dụng:* Máy ảo Linux nhận trực tiếp 1 địa chỉ IP riêng từ Modem (VD: `192.168.1.15`), giảm 50% độ trễ và giải phóng hoàn toàn gánh nặng xử lý mạng cho Windows host.

### B. Tỉ lệ vàng cấp phát phần cứng cho Máy ảo:
* **RAM:** Cấp tối đa **70% tổng RAM vật lý** (để lại 30% cho Windows). *Nhờ ZRAM ZSTD trong script, RAM thực tế của máy ảo sẽ được nén x2 lần*.
* **vCPU:** Cấp tối đa **75% số luồng CPU** (VD: CPU 8 Core / 16 Thread -> cấp 10 - 12 vCPU cho VM).
* **Virtualization Engine:** Tích chọn *Virtualize Intel VT-x/EPT or AMD-V/RVI* trong cài đặt CPU của máy ảo.

---

## 5. CHIẾN LƯỢC MỞ RỘNG NHIỀU PC & TĂNG TỐC BĂNG THÔNG

Khi mở rộng quy mô từ **2 đến 10+ PC** chạy đồng thời trên 1 địa điểm:

```text
[ Đường Cáp Quang Nhà Mạng 1 ] ──┐
                                 ├──> [ Router Chịu Tải MikroTik / OpenWrt ] (Gộp mạng Multi-WAN)
[ Đường Cáp Quang Nhà Mạng 2 ] ──┘                 │
                                                   ▼
                                  [ Switch Chia Mạng Gigabit 8-24 Ports ]
                                                   ├── PC 1 (Static IP: 192.168.1.10) ──> [ VM Linux 150 Nodes ]
                                                   ├── PC 2 (Static IP: 192.168.1.11) ──> [ VM Linux 150 Nodes ]
                                                   └── PC 3 (Static IP: 192.168.1.12) ──> [ VM Linux 150 Nodes ]
```

### 🥇 Giải pháp 1: Bridge Mode + Dùng Router Chịu Tải (Dành cho Farm từ 2 PC trở lên)
* **Cách làm:** Gọi tổng đài nhà mạng (Viettel 1800 8119) yêu cầu chuyển modem chính sang chế độ **Bridge Mode**.
* **Trang bị Router chuyên dụng:**
  * **Tầm trung (400k – 700k):** Mua **Newifi 3 D2** hoặc **Xiaomi AX3000** cài firmware OpenWrt.
  * **Chuyên nghiệp (1.2tr – 1.8tr):** Mua **MikroTik hEX (RB750Gr3)** hoặc **PC Router x86 (chạy pfSense / OpenWrt)**.
* **Hiệu quả:** Xử lý mượt mà **50.000 – 150.000 kết nối NAT đồng thời**, chạy liên tục 365 ngày không bao giờ bị đơ hay tụt băng thông.

### 🥈 Giải pháp 2: Gộp 2 Đường Mạng (Multi-WAN Load Balancing)
* **Cách làm:** Kéo 2 đường truyền (VD: 1 Line Viettel 200Mbps + 1 Line VNPT 200Mbps), cắm vào Router MikroTik / OpenWrt và bật tính năng **PCC Load Balancing**.
* **Hiệu quả:**
  * Băng thông gộp x2: `200Mbps + 200Mbps = 400Mbps`.
  * Sở hữu **2 IP Public dân cư độc lập** -> Nhân đôi số lượng node chạy IP Gốc.
  * Tự động chuyển vùng (Failover): Nếu một nhà mạng bảo trì, toàn bộ node tự chuyển sang đường còn lại, không gián đoạn thu nhập.

### 🥉 Giải pháp 3: Dùng Ổ Cắm Hẹn Giờ Thông Minh (Chi Phí ~70.000đ)
* Dành cho ai chạy 1 PC trên Modem nhà mạng: Dùng ổ cắm Wi-Fi (Tuya / Sonoff / Rạng Đông) cài lịch tự tắt nguồn modem lúc `04:00 AM` và bật lại lúc `04:01 AM` hàng ngày để tự động xả sạch 100% bảng NAT.

---

## 7. QUY TRÌNH KHỞI CHẠY & LỆNH QUẢN TRỊ TELEMETRY

### A. Khởi chạy trên Máy ảo Linux:
```bash
# 1. Cấp quyền thực thi
chmod +x setup_vm.sh

# 2. Khởi chạy Master Script
sudo bash setup_vm.sh

# (Tùy chọn) Hẹn giờ tắt VM an toàn mỗi đêm lúc 23:30 để bảo vệ SQLite Database
sudo bash setup_vm.sh --auto-off 23:30
```

### B. Bộ lệnh quản trị nhanh (Gõ trực tiếp vào Terminal):
* **`ii-status`** : Bảng điều khiển viễn trắc kiểm tra toàn diện RAM, ZRAM ZSTD, Conntrack và trạng thái 100% của từng nền tảng.
* **`check-proxy`** : Đo độ trễ, kiểm tra tính thông tuyến và chất lượng danh sách Proxy.
* **`ii-capacity`** : Đo đạc sức chịu tải tối đa của phần cứng PC xem có thể cắm thêm bao nhiêu Node.
* **`ii-sync`** : Cưỡng chế cân bằng bộ nhớ RAM động giữa các container.

---

## 8. CẨM NANG XỬ LÝ SỰ CỐ ĐỊNH KỲ (FAQ)

#### ❓ Sau 2-3 ngày cắm máy, lưu lượng có dấu hiệu chững lại?
* **Xử lý:** Đây là chu kỳ phân phối task tự nhiên của nền tảng (Platform Demand Cycle). Bạn chỉ cần truy cập `192.168.1.1` bấm nút **`Reboot`** để làm mới dải IP WAN từ nhà mạng, task sẽ được phân phối mạnh mẽ trở lại.

#### ❓ Làm sao biết máy ảo có bị lệch giờ khi Windows Sleep không?
* **Kiểm tra:** Script đã tích hợp sẵn `Time-Drift Guard (Chrony Service)` tự đồng bộ microsecond mỗi 30s. Bạn gõ lệnh `ii-status`, nếu thấy dòng `NTP Time Sync Status: ACTIVE` là hệ thống chuẩn xác 100%.

#### ❓ File Proxy copy từ Windows vào Linux bị lỗi kết nối?
* **Xử lý:** Script đã tích hợp bộ lọc tự động xóa ký tự xuống dòng ẩn `\r` (CRLF) của Windows trong toàn bộ file `.txt` / `.list`. Mọi proxy nạp vào đều được chuẩn hóa tuyệt đối.

# 🚀 HƯỚNG DẪN TỐI ƯU HÓA PHẦN CỨNG & MẠNG NGOÀI VM (WINDOWS HOST & ROUTER)
> **Dành cho:** Mô hình chạy Node Bandwidth Sharing & High-Density Proxy trên Linux VM (VMware / VirtualBox / Hyper-V) chạy 24/7 trên PC Windows.

---

## 📌 PHẦN 1: ĐỊNH MỨC & GIỚI HẠN AN TOÀN TRÊN MẠNG GIA ĐÌNH

Chạy chia sẻ băng thông trên đường truyền Internet gia đình (Viettel, FPT, VNPT) cần tuân thủ các ngưỡng an toàn sau để không bị nhà mạng bóp băng thông (DPI Traffic Shaping) hoặc làm sập Modem:

| Hạng mục | Ngưỡng an toàn khuyến nghị | Hậu quả nếu vượt ngưỡng |
| :--- | :--- | :--- |
| **Loại kết nối** | **Bắt buộc cắm cáp LAN (Cat5e / Cat6)** | Wi-Fi sẽ bị rớt gói tin (packet loss) và lag sau 24h. |
| **Số Node chạy IP Gốc** | **1 Node / 1 Nền tảng** (Honeygain, Pawns, EarnApp...) | Chạy trùng IP gốc sẽ bị nền tảng giảm điểm hoặc cấm tài khoản. |
| **Số Node chạy qua Proxy** | **50 – 150 Proxy Nodes** (trên Modem nhà mạng thường) | >200 Proxies mở quá nhiều socket làm tràn bảng NAT Modem. |
| **Tổng lưu lượng Upload** | **Dưới 3 TB – 5 TB / tháng** | Vượt mức này ISP sẽ đưa IP vào danh sách nghi vấn và bóp tốc độ quốc tế. |

---

## 🛠️ PHẦN 2: TỐI ƯU HÓA TRÊN WINDOWS HOST (BẮT BUỘC)

### 1. Cấu hình Nguồn điện (Power Options)
* Nhấn `Windows + R` -> gõ `control.exe powercfg.cpl,,3` (hoặc vào *Control Panel -> Power Options*).
* Chọn gói: **High performance** (hoặc chạy lệnh CMD Admin: `powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61` để mở gói **Ultimate Performance**).
* Trong mục **Change plan settings**:
  * **Put the computer to sleep:** Đặt thành **`Never`**.
* Bấm vào dòng xanh **`Change advanced power settings`**:
  * **Hard disk** -> *Turn off hard disk after* -> Đổi thành **`0`** (Never).
  * **PCI Express** -> *Link State Power Management* -> Đổi thành **`Off`** *(Chống hạ nguồn card mạng/SSD)*.

---

### 2. Tắt tiết kiệm điện trên Card Mạng (Device Manager)
* Nhấn `Windows + X` -> Chọn **Device Manager** -> Mở rộng mục **Network adapters**.
* Chuột phải vào **Card mạng LAN chính** (Intel / Realtek / Killer) -> Chọn **Properties**:
  * **Tab `Power Management`:** **BỎ TÍCH** ô *"Allow the computer to turn off this device to save power"*.
  * **Tab `Advanced`:** Chuyển tất cả các mục sau về **`Disabled`**:
    * `Energy Efficient Ethernet (EEE)` -> **Disabled**
    * `Green Ethernet` -> **Disabled**
    * `Power Saving Mode` / `Gigabit Lite` -> **Disabled**
* Bấm **OK** để lưu.

---

### 3. Chặn Windows Update tự ý Restart máy lúc nửa đêm
* Nhấn `Windows + R` -> gõ **`gpedit.msc`** -> Enter.
* Tìm theo đường dẫn:  
  `Computer Configuration` -> `Administrative Templates` -> `Windows Components` -> `Windows Update`
* Nhấp đúp vào: **`No auto-restart with logged on users for scheduled automatic updates installations`**.
* Tích chọn **`Enabled`** -> Bấm **OK**.

---

### 4. Loại trừ thư mục VM khỏi Windows Defender (Antivirus)
* Mở **Windows Security** -> Vào **Virus & threat protection**.
* Chọn **Manage settings** (dưới *Virus & threat protection settings*).
* Cuộn xuống mục **Exclusions** -> Bấm **Add or remove exclusions**.
* Bấm **Add an exclusion** -> Chọn **Folder** -> Trỏ đến thư mục lưu file máy ảo `.vmdk` / `.vdi` (hoặc thư mục cài VMware / VirtualBox).

---

## 🌐 PHẦN 3: CẤU HÌNH CARD MẠNG PHẦN MỀM MÁY ẢO (VMWARE / VIRTUALBOX)

* **Tuyệt đối không dùng chế độ NAT Mode** (tránh bị 2 lần NAT làm nghẽn cổ chai).
* **Bắt buộc chuyển sang `Bridged Adapter` (Cầu nối trực tiếp):**
  * **VMware:** Vào *VM Settings -> Network Adapter -> Chọn `Bridged: Connected directly to the physical network`*.
  * **VirtualBox:** Vào *Settings -> Network -> Attached to: `Bridged Adapter`* -> Chọn đúng tên Card mạng LAN vật lý.
* 👉 *Tác dụng:* Máy ảo Linux sẽ nhận trực tiếp một địa chỉ IP riêng từ Modem nhà mạng (như 1 PC độc lập), giảm 50% độ trễ và giải phóng hoàn toàn gánh nặng xử lý mạng cho Windows.

---

## 📡 PHẦN 4: VẬN HÀNH & BẢO TRÌ MODEM NHÀ MẠNG (ONT ROUTER)

### 1. Đăng nhập trang quản trị Modem
* Truy cập địa chỉ: `http://192.168.1.1`
* **Tài khoản:** `admin`
* **Mật khẩu:** Dòng chữ in hoa tại mục **GPON SN** ở tem đáy thiết bị (VD: `ZTEGDE291D38`).

### 2. Quy trình làm sạch bảng NAT Table định kỳ
* Các app chia sẻ băng thông mở ra hàng trăm ngàn kết nối ảo mỗi ngày khiến RAM của Modem bị đầy.
* **Cách xử lý:**
  * **Chủ động:** Định kỳ 2–3 ngày/lần, đăng nhập vào `192.168.1.1` -> *Management & Diagnosis* -> *System Management* -> Bấm nút **`Reboot`** (Modem khởi động lại trong 1-2 phút).
  * **Tự động hóa 100%:** Dùng 1 ổ cắm hẹn giờ điện tử / thông minh (Smart Plug 50k-90k), cài lịch ngắt điện modem lúc `04:00 AM` và bật lại lúc `04:01 AM` mỗi ngày.

---

## 💻 PHẦN 5: BẬT MÁY ẢO VÀ CHẠY SCRIPT CHUẨN

Sau khi khởi động máy ảo Linux đã cấu hình mạng Bridged, chỉ cần chạy lệnh sau trong Terminal:

```bash
# Cấp quyền và chạy Master Script
sudo bash setup_vm.sh

# (Tùy chọn) Hẹn giờ tắt máy an toàn lúc 23:30 mỗi đêm
sudo bash setup_vm.sh --auto-off 23:30

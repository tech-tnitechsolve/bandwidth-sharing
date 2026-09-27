# 🚀 HOMELAB BANDWIDTH SHARING — 24/7 STANDALONE SERVER MASTER PLAYBOOK
> **Tài liệu chuẩn triển khai tự động hóa 100% cho Mini PC / Thin Client (Dell Wyse 5070, Intel NUC, HP, ThinkCentre Tiny) chạy cụm node kiếm tiền chia sẻ băng thông 24/7/365 không cần màn hình.**

---

## 📋 MỤC LỤC
1. [Chuẩn bị & Cài đặt Hệ điều hành (Ubuntu Server 22.04 LTS)](#1-chuẩn-bị--cài-đặt-hệ-điều-hành-ubuntu-server-2204-lts)
2. [Thiết lập BIOS Phần Cứng (Chạy 24/7 Headless)](#2-thiết-lập-bios-phần-cứng-chạy-247-headless)
3. [Tối ưu hóa Toàn diện Modem / Router Wi-Fi Nhà Mạng](#3-tối-ưu-hóa-toàn-diện-modem--router-wi-fi-nhà-mạng)
4. [Kích hoạt Hệ thống bằng "1 Dòng Lệnh Duy Nhất" (Zero-Touch)](#4-kích-hoạt-hệ-thống-bằng-1-dòng-lệnh-duy-nhất-zero-touch)
5. [Quản lý Thư mục & Proxy qua WinSCP (Tự do tạo Folder)](#5-quản-lý-thư-mục--proxy-qua-winscp-tự-do-tạo-folder)
6. [Quản trị Mật khẩu & Cứu Hộ Khẩn Cấp](#6-quản-trị-mật-khẩu--cứu-hộ-khẩn-cấp)
7. [Bảng Tra Cứu Lệnh Vận Hành 24/7 (Cheat Sheet)](#7-bảng-tra-cứu-lệnh-vận-hành-247-cheat-sheet)
8. [Quy trình Di chuyển sang Căn Nhà Mới (Zero-Touch Checklist)](#8-quy-trình-di-chuyển-sang-căn-nhà-mới-zero-touch-checklist)

---

## 1. CHUẨN BỊ & CÀI ĐẶT HỆ ĐIỀU HÀNH (UBUNTU SERVER 22.04 LTS)

### 1.1. Tạo USB Cài đặt trên Windows bằng Rufus
1. Tải bản **Ubuntu Server 22.04.x LTS (ISO)** và phần mềm **Rufus**.
2. Cắm USB (hoặc Thẻ nhớ máy ảnh qua đầu đọc USB) vào PC Windows $\rightarrow$ Mở Rufus:
   * **Device:** Chọn đúng USB / Thẻ nhớ của bạn.
   * **Boot selection:** Bấm *SELECT* $\rightarrow$ Chọn file `ubuntu-22.04.5-live-server-amd64.iso`.
   * **Partition scheme:** Chọn **`GPT`** | **Target system:** **`UEFI (non CSM)`**.
   * Bấm **START** $\rightarrow$ Chọn *Write in ISO Image mode (Recommended)* $\rightarrow$ Bấm **OK**.

---

### 1.2. Thao tác Cài đặt trực quan trên máy Dell Wyse / Mini PC
1. Cắm USB cài đặt vào cổng USB máy Dell Wyse (ưu tiên cổng USB màu đen phía sau máy).
2. Cắm màn hình vào cổng **`1:DP`** (DisplayPort số 1 trên cùng qua đầu chuyển HDMI), cắm bàn phím và dây mạng LAN vào Router.
3. Bật nguồn máy $\rightarrow$ Nhấn liên tục phím **`F12`** để mở Boot Menu.
4. Chọn dòng: **`UEFI: Tên USB / Generic Flash-Disk...`** $\rightarrow$ Bấm **Enter**.
5. Chọn dòng đầu tiên: **`Try or Install Ubuntu Server`** $\rightarrow$ Bấm **Enter**.

#### 📝 Các bước bấm chọn trên màn hình cài đặt:
* **Language / Keyboard:** Chọn **English (US)** $\rightarrow$ Chọn **Continue without updating**.
* **Type of install / Network / Proxy / Mirror:** Đều chọn **Done** $\rightarrow$ Bấm Enter.
* **Storage configuration (CỰC KỲ QUAN TRỌNG ⚠️):**
  * Chọn cài vào ổ **SSD M.2 (`sda` dung lượng ~30GB - 32GB)**.
  * **BỎ DẤU TÍCH** ở dòng: `[ ] Set up this disk as an LVM group` *(bấm phím Space để bỏ chọn LVM, giúp tận dụng 100% dung lượng ổ SSD cho Docker)*.
  * Chọn **Done** $\rightarrow$ Bảng xác nhận hiện ra, chọn **`Continue`** $\rightarrow$ Bấm Enter.
* **Profile setup (Tạo tài khoản):**
  * *Your name:* `ubuntu`
  * *Your server's name:* `wyse-node`
  * *Pick a username:* `ubuntu`
  * *Choose a password:* `123456` *(Nên gõ bằng hàng phím số phía trên dưới phím F1-F12)*
  * *Confirm your password:* `123456`
  * Chọn **Done** $\rightarrow$ Bấm Enter.
* **Upgrade to Ubuntu Pro:** Chọn **Skip for now** $\rightarrow$ Chọn **Done**.
* **SSH Setup (BẮT BUỘC ⚠️):**
  * Bấm phím Space để tích chọn thành: **`[X] Install OpenSSH server`**.
  * Chọn **Done** $\rightarrow$ Bấm Enter.
* **Featured Server Snaps:** Để trống hoàn toàn $\rightarrow$ Chọn **Done**.
* Chờ 2 phút máy cài xong $\rightarrow$ Hiện nút **`[ Reboot Now ]`** $\rightarrow$ Bấm **Enter**.
* Khi màn hình hiện dòng chữ *`Please remove the installation medium, then press ENTER`*:
  👉 **RÚT USB RA KHỎI MÁY** $\rightarrow$ Bấm **Enter**.

---

## 2. THIẾT LẬP BIOS PHẦN CỨNG (CHẠY 24/7 HEADLESS)

*(Vì đang cắm sẵn màn hình và bàn phím, hãy thiết lập BIOS một lần duy nhất để máy chạy vĩnh viễn không cần màn hình)*:

1. Khởi động lại máy $\rightarrow$ Nhấn liên tục phím **`F2`** để vào giao diện **BIOS Setup**.
2. **Cấu hình 4 mục quan trọng:**
   * **Tự bật nguồn khi có điện lại (AC Recovery):**  
     Vào `Power Management` $\rightarrow$ `AC Recovery` $\rightarrow$ Chọn **`Power On`** *(để khi mất điện và có điện lại, máy tự khởi động chạy tiếp mà không cần ai bấm nút nguồn)*.
   * **Chống máy tự động ngủ (Block Sleep):**  
     Vào `Power Management` $\rightarrow$ `Block Sleep` $\rightarrow$ Tích chọn **`[X] Block Sleep`**.
   * **Không dừng lại khi thiếu Bàn phím / Nguồn:**  
     Vào `POST Behavior` $\rightarrow$ **BỎ DẤU TÍCH** ở cả 2 mục: `[ ] Keyboard Errors` và `[ ] Adapter Warnings`.
   * **Bật ảo hóa phần cứng cho Docker:**  
     Vào `Virtualization Support` $\rightarrow$ `Virtualization` $\rightarrow$ Đảm bảo ô **`[X] Enable Intel Virtualization Technology`** đã được chọn.
3. Bấm **`Apply`** $\rightarrow$ Bấm **`OK`** $\rightarrow$ Bấm **`Exit`**.

👉 **LÚC NÀY BẠN ĐÃ CÓ THỂ RÚT TOÀN BỘ MÀN HÌNH, BÀN PHÍM VÀ ĐẦU CHUYỂN RA CẤT ĐI VĨNH VIỄN!**  
*(Từ giờ máy Dell Wyse chỉ cần cắm đúng **1 Dây nguồn** và **1 Dây mạng LAN** cắm vào Router)*.

---

## 3. TỐI ƯU HÓA TOÀN DIỆN MODEM / ROUTER WI-FI NHÀ MẠNG

Chạy cụm 50–100+ proxy node tạo ra hàng ngàn kết nối TCP/UDP cùng lúc. Hãy đăng nhập vào trang quản trị Modem (`http://192.168.1.1` hoặc `192.168.0.1` với tài khoản/mật khẩu in dưới đít modem) và cấu hình 8 bước mở khóa công suất mạng:

### 3.1. Hạ mức Tường lửa của Modem (Set Firewall to Low)
* **Vị trí:** `Security` $\rightarrow$ `Firewall` $\rightarrow$ `Firewall Level`.
* **Thao tác:** Chuyển từ *High / Medium* sang **`Low`** (hoặc *Off* nếu là modem phụ).
* *Mục đích:* Ngăn modem tự động chặn và drop các gói tin SOCKS5/Proxy truyền tải với mật độ dày đặc.

### 3.2. TẮT BỎ tính năng Anti-DoS / Flood Attack Detection
* **Vị trí:** `Security` $\rightarrow$ `Firewall` $\rightarrow$ `Anti-DoS / Attack Protection / SPI Firewall`.
* **Thao tác:** Chuyển sang **`Disable / Off`** (Bỏ tích toàn bộ các ô SYN Flood, UDP Flood, ICMP Flood).
* *Mục đích:* Thuật toán Anti-DoS trên modem nhà mạng thường giới hạn 100 kết nối/3 giây. Khi chạy nhiều node, modem sẽ tưởng nhầm máy Dell Wyse đang tấn công mạng và tự động khóa IP của Dell Wyse!

### 3.3. MỞ KHÓA Giới hạn Session (Session Limit $\rightarrow$ Max/Off)
* **Vị trí:** `Security` $\rightarrow$ `NAT` $\rightarrow$ `Session Limit` (hoặc `Connection Limit`).
* **Thao tác:** Chuyển sang **`Disable / Off`** hoặc nâng số lượng Session tối đa lên **`16384`** (hoặc `65535`).
* *Mục đích:* Cho phép máy Dell Wyse duy trì hàng ngàn luồng socket kiếm tiền đồng thời mà không bị bóp nghẽn.

### 3.4. BẬT DMZ (Demilitarized Zone) trỏ vào IP của Dell Wyse
* **Vị trí:** `Forwarding` / `Advanced NAT` $\rightarrow$ `DMZ`.
* **Thao tác:** Gạt sang **`Enable`** $\rightarrow$ Điền địa chỉ IP mạng LAN của máy Dell Wyse (Ví dụ: **`192.168.1.50`** hoặc IP thực tế) $\rightarrow$ Bấm **Apply**.
* *Mục đích:* Mở thông toàn bộ các cổng mạng từ Internet vào Dell Wyse, giúp các node nhận task với tốc độ nhanh nhất.

### 3.5. Kích hoạt `Full Cone NAT` (Tăng thu nhập P2P +30% – 50%)
* **Vị trí:** `NAT` $\rightarrow$ `NAT Type` (hoặc `NAT Mode`).
* **Thao tác:** Chuyển từ *Symmetric* sang **`Full Cone NAT`** (hoặc *Restricted Cone*).
* *Mục đích:* Giúp các nền tảng P2P (Honeygain, Pawns, EarnApp, Mysterium...) giao tiếp ngang hàng trực tiếp, tối ưu hóa điểm số và gia tăng thu nhập tối đa.

### 3.6. Cố định địa chỉ IP cho Dell Wyse theo MAC (DHCP Static Binding)
* **Vị trí:** `Network` $\rightarrow$ `LAN` $\rightarrow$ `DHCP Server` $\rightarrow$ `Static Lease / IP & MAC Binding`.
* **Thao tác:** Bấm **Add (Thêm mới)**:
  * **MAC Address:** Điền MAC của card mạng Dell Wyse: **`c0:25:a5:10:b4:94`**
  * **IP Address:** Đặt IP cố định mong muốn (ví dụ: **`192.168.1.50`**).
* *Mục đích:* Giúp máy Dell Wyse luôn giữ đúng 1 địa chỉ IP duy nhất trong mạng nội bộ, không bị nhảy IP khi khởi động lại.

### 3.7. Bật UPnP & Tắt Client Isolation
* **UPnP:** Vào `Forwarding` $\rightarrow$ `UPnP` $\rightarrow$ Chọn **`Enable`** (Tự động ánh xạ cổng P2P).
* **Client Isolation:** Vào `Wireless / LAN` $\rightarrow$ `AP Isolation / Client Isolation` $\rightarrow$ Chọn **`Disable (Tắt)`** (Cho phép các máy trong mạng LAN giao tiếp nội bộ thông suốt).

### 3.8. Đặt lịch Tự động Khởi động lại Modem (Auto-Reboot Schedule)
* **Vị trí:** `System Tools` $\rightarrow$ `Reboot Schedule` (hoặc `Auto Maintenance`).
* **Thao tác:** Chọn tự động Reboot vào lúc **`04:00 AM Chủ Nhật hàng tuần`**.
* *Mục đích:* Tự động giải phóng RAM và xóa các session rác tồn đọng trên Modem nhà mạng định kỳ.

---

## 4. KÍCH HOẠT HỆ THỐNG BẰNG "1 DÒNG LỆNH DUY NHẤT" (ZERO-TOUCH)

Mở CMD / PowerShell trên máy tính Windows, SSH vào IP mạng LAN của máy (ví dụ: `ssh ubuntu@192.168.1.xxx` với mật khẩu `123456`) và dán **đúng 1 dòng lệnh duy nhất**:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/Server-Homelab/setup_serverhomelab.sh)"
```

---

### ⚙️ Toàn bộ quy trình hệ thống tự động xử lý:
1. **Tailscale:** Tự động cài đặt & kích hoạt mạng riêng ảo (hiển thị link xác nhận hoặc tự đăng nhập nếu dùng Auth-Key).
2. **Tản nhiệt CPU Fanless:** Tự động chuyển CPU Governor sang `schedutil/powersave`, giữ máy không quạt luôn mát ở **`36°C – 45°C`**.
3. **ZRAM ZSTD:** Tự động nén RAM tỉ lệ 1:1 (mở rộng 8GB thành ~14GB RAM ảo, chống tràn RAM OOM).
4. **Bảo vệ Ổ SSD 32GB:** Khóa cứng dung lượng log Docker tối đa **`2MB/container`** và systemd log **`10MB`**.
5. **DNS & Network Hardening:** Tự động khóa DNS Direct `1.1.1.1/8.8.8.8` chống lộ IP gốc và tối ưu TCP BBR, buffer 524.288 streams.
6. **Docker Engine:** Cài đặt Docker 29.x mới nhất và tự động phân quyền non-root cho user `ubuntu`.
7. **Tường lửa UFW:** Tự động mở cổng `22` cho card mạng ảo `tailscale0` và cổng mạng LAN.
8. **Bộ Watchdogs 24/7:** Tự động kích hoạt FlapGuard (chống ban IP), Repocket Doctor (tự cứu proxy sập), AutoSync RAM và Staggered Boot (khởi động tuần tự chống nghẽn CPU sau cúp điện).

---

### 🔒 CÀI ĐẶT TAILSCALE VĨNH VIỄN (KHÔNG BAO GIỜ HẾT HẠN):
1. Mở trình duyệt web vào: [https://login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines)
2. Tìm máy **`wyse-node`** $\rightarrow$ Bấm vào dấu **`...`** ở góc phải $\rightarrow$ Chọn **`Disable key expiry`**.
3. Lưu lại địa chỉ **`TAILSCALE IP : 100.x.y.z`** (Ví dụ: `100.95.126.50`) để dùng quản trị từ xa mãi mãi!

---

## 5. QUẢN LÝ THƯ MỤC & PROXY QUA WINSCP (TỰ DO TẠO FOLDER)

Hệ thống sử dụng cơ chế **Quét động (Dynamic Discovery)**. Bạn có thể tự do dùng WinSCP tạo bao nhiêu thư mục proxy tùy ý mà không bị gò bó cấu trúc:

1. **Kết nối WinSCP từ PC Windows:**
   * **File protocol:** `SFTP`
   * **Host name:** Điền **IP Tailscale `100.x.y.z`** *(ví dụ: `100.95.126.50`)*.
   * **User name:** `ubuntu` | **Password:** *(Mật khẩu của bạn)*.
   * Bấm **Login**.
2. **Tự do tạo thư mục & Cấu hình:**
   * Vào thư mục `/home/ubuntu` $\rightarrow$ Tự tạo các folder theo ý bạn (Ví dụ: `Proxy_VN_50`, `Proxy_US_100`, `Spide_Group`...).
   * Copy file `internetIncome.sh`, file cấu hình `properties.conf` và danh sách proxy `.txt` vào các thư mục đó.
   * Chỉnh sửa Token / Email trong `properties.conf` $\rightarrow$ Bấm `Ctrl + S` lưu lại.
3. **Khởi chạy cụm node kiếm tiền:**
   Mở CMD / Terminal gõ:
   ```bash
   cd /home/ubuntu/TÊN_FOLDER_CỦA_BẠN
   bash internetIncome.sh --start
   ```
   *(Toàn bộ các Watchdog và lịch Cronjob ngầm sẽ **tự động quét ra và tự động bảo vệ 24/7 cho tất cả các folder bạn tự tạo** mà không cần cấu hình thêm)*.

---

## 6. QUẢN TRỊ MẬT KHẨU & CỨU HỘ KHẨN CẤP

### 6.1. Đổi mật khẩu tài khoản đang dùng
```bash
passwd ubuntu
```
*(Nhập mật khẩu cũ $\rightarrow$ Nhập mật khẩu mới 2 lần)*.

### 6.2. Cứu hộ mật khẩu nếu lỡ quên (Khôi phục quyền Root qua GRUB trong 30 giây)
1. Cắm màn hình + bàn phím vào máy $\rightarrow$ Khởi động lại máy $\rightarrow$ Nhấn giữ phím **`Shift`** khi màn hình vừa bật sáng để hiện menu GRUB.
2. Tại dòng `*Ubuntu`, bấm phím chữ **`e`**.
3. Dùng phím mũi tên $\downarrow$ tìm dòng bắt đầu bằng chữ `linux /boot/vmlinuz...`, di chuyển con trỏ về cuối dòng đó, bấm dấu cách và gõ thêm:  
   `rw init=/bin/bash`
4. Bấm tổ hợp phím **`Ctrl + X`** (hoặc `F10`) để boot vào dòng lệnh Root:
   ```bash
   passwd ubuntu     # Nhập mật khẩu mới 2 lần
   reboot -f         # Khởi động lại máy
   ```

---

## 7. BẢNG TRA CỨU LỆNH VẬN HÀNH 24/7 (CHEAT SHEET)

Bất kể bạn ở đâu, chỉ cần mở CMD / PowerShell gõ `ssh ubuntu@100.x.y.z`:

| Tác vụ | Câu lệnh thực thi |
| :--- | :--- |
| **Bật cụm node kiếm tiền** | `cd /home/ubuntu/TÊN_FOLDER && bash internetIncome.sh --start` |
| **Dừng cụm node kiếm tiền** | `cd /home/ubuntu/TÊN_FOLDER && bash internetIncome.sh --stop` |
| **Khởi động lại tuần tự chống nghẽn CPU** | `ii-restart-all.sh` |
| **Xem các container đang chạy** | `docker ps` |
| **Xem mức tiêu hao RAM/CPU thời gian thực** | `docker stats` |
| **Xem log trực tiếp của 1 container** | `docker logs -f <tên_container>` *(Bấm Ctrl+C để thoát)* |
| **Bảng đo kiểm sức khỏe & ZRAM 24/7** | `ii-status` |
| **Chẩn đoán & Tự cứu lỗi Proxy / Repocket** | `ii-repocket-doctor` |
| **Kiểm tra lưu lượng 1 proxy cụ thể** | `ii-test-proxy <tên_container>` |
| **Đánh giá sức chứa phần cứng (Số node tối đa)** | `ii-capacity` |
| **Dọn rác Docker & Thu nhỏ Log khẩn cấp** | `ii-clean-logs` |
| **Khởi động lại máy từ xa** | `sudo reboot` |
| **Tắt máy an toàn từ xa** | `sudo shutdown -h now` |

---

## 8. QUY TRÌNH DI CHUYỂN SANG CĂN NHÀ MỚI (ZERO-TOUCH CHECKLIST)

Khi bạn muốn mang Mini PC sang đặt ở một căn nhà hoặc văn phòng khác:

1. **Tại nhà cũ:** Đứng ở SSH gõ lệnh tắt máy an toàn:
   ```bash
   sudo shutdown -h now
   ```
   *(Đợi đèn nút nguồn tắt hẳn $\rightarrow$ Rút phích cắm nguồn và dây LAN mang đi)*.
2. **Tại địa điểm mới (Chỉ mất 30 giây):**
   * Lắp chân đế đứng (Vertical Stand) cho máy, đặt ở nơi cao ráo, thông thoáng gió.
   * Cắm **dây mạng LAN từ Router nhà mới** vào đít máy Dell Wyse.
   * Cắm **dây nguồn** vào ổ điện *(Máy sẽ tự động bật nguồn nhờ tính năng AC Recovery)*.
3. **Kết nối & Vận hành từ xa:**
   * Ngồi ở bất kỳ đâu, mở PC / Laptop / Điện thoại bật Tailscale lên $\rightarrow$ Mở CMD `ssh ubuntu@100.x.y.z` hoặc mở WinSCP quản lý bình thường!
4. *(Tùy chọn)* **Cập nhật Whitelist (Nếu dùng Proxy IP-Auth):**
   * Trong SSH gõ: `curl ifconfig.me` để lấy IP Public của căn nhà mới.
   * Lấy IP này dán vào mục Whitelist trên trang web bán Proxy của bạn.

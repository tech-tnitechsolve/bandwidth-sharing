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
   * **Partition scheme:** Chọn **`GPT`**.
   * **Target system:** Chọn **`UEFI (non CSM)`**.
   * Bấm **START** $\rightarrow$ Chọn *Write in ISO Image mode (Recommended)* $\rightarrow$ Bấm **OK**.

---

### 1.2. Thao tác Cài đặt trực quan trên máy Dell Wyse / Mini PC
1. Cắm USB cài đặt vào cổng USB (ưu tiên cổng USB màu đen phía sau máy).
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

Chạy cụm 50–100+ proxy node tạo ra hàng ngàn kết nối TCP/UDP cùng lúc. Hãy đăng nhập vào trang quản trị Modem (`http://192.168.1.1` hoặc `192.168.0.1`) và tối ưu các mục sau để Modem không bị tràn bộ nhớ hay treo mạng gia đình:

1. **Bật `Full Cone NAT` (Tăng thu nhập P2P +30% – 50%):**
   * Vào mục `NAT` hoặc `Forwarding` $\rightarrow$ Chuyển chế độ từ *Symmetric* sang **`Full Cone NAT`** (giúp Honeygain, Pawns, EarnApp thông luồng dữ liệu tối đa).
2. **Cố định IP cục bộ cho Dell Wyse (DHCP Static Lease / Binding):**
   * Vào `DHCP Server` $\rightarrow$ `Static Lease` $\rightarrow$ Gán địa chỉ MAC của Dell Wyse (`c0:25:a5:10:b4:94`) cố định vào 1 IP (ví dụ: `192.168.1.50`).
3. **Đổi DNS Quốc tế trên Modem (Chống chặn tên miền):**
   * Vào mục `LAN/WAN DNS` $\rightarrow$ Đổi sang:
     * **Primary DNS:** `1.1.1.1` (Cloudflare)
     * **Secondary DNS:** `8.8.8.8` (Google)
4. **Mở khóa tường lửa Modem:**
   * Hạ mức `Firewall Level` của Modem xuống mức **`Low`** hoặc tắt tính năng `Anti-DoS / Flood Attack Detection` (để Modem không chặn nhầm các luồng proxy tốc độ cao).
5. **Bật UPnP & Tắt Client Isolation:**
   * Bật **`UPnP: Enable`** để container tự ánh xạ cổng P2P.
   * Tắt **`AP / Client Isolation: Disable`** để các thiết bị trong mạng LAN giao tiếp thông suốt.
6. **Đặt lịch Tự khởi động lại Modem (Auto-Reboot Schedule):**
   * Cài đặt Modem tự động khởi động lại vào lúc **`04:00 AM Chủ Nhật hàng tuần`** để xả sạch RAM và xóa session rác.

---

## 4. KÍCH HOẠT HỆ THỐNG BẰNG "1 DÒNG LỆNH DUY NHẤT" (ZERO-TOUCH)

Trên máy tính PC Windows, mở CMD / PowerShell gõ lệnh SSH vào IP mạng LAN của máy (ví dụ: `ssh ubuntu@192.168.1.xxx` với mật khẩu `123456`) và dán **đúng 1 dòng lệnh duy nhất**:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/Server-Homelab/setup_serverhomelab.sh)"

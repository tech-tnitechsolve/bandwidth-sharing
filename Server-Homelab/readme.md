### GIAI ĐOẠN 1: Cài Ubuntu Server lên máy mới (Mất 3 phút)

1. **Tạo USB Cài đặt (trên PC Windows bằng Rufus):**
   * Cắm USB/Thẻ nhớ $\rightarrow$ Mở Rufus chọn file `ubuntu-22.04.5-live-server-amd64.iso`.
   * **Partition scheme:** Chọn **`GPT`** | **Target system:** **`UEFI (non CSM)`** $\rightarrow$ Bấm **START** ghi xong.
2. **Cài vào máy mới:**
   * Cắm USB, màn hình (cổng `1:DP`), bàn phím và dây mạng LAN vào máy mới $\rightarrow$ Bật nguồn bấm **`F12`**.
   * Chọn boot từ USB $\rightarrow$ Chọn **`Try or Install Ubuntu Server`**.
   * **3 Lưu ý sống còn khi bấm Next:**
     * **Storage:** Chọn ổ **SSD (30GB - 32GB)** $\rightarrow$ **BỎ DẤU TÍCH** ở dòng `[ ] Set up this disk as an LVM group` $\rightarrow$ Chọn **Done** $\rightarrow$ **Continue**.
     * **Profile:** Đặt user `ubuntu`, pass `123456`.
     * **SSH Setup:** Tích chọn **`[X] Install OpenSSH server`**.
   * Cài xong bấm **`Reboot Now`** $\rightarrow$ **Rút USB ra** $\rightarrow$ Bấm **Enter**.

---

### GIAI ĐOẠN 2: Thiết lập BIOS để máy chạy 24/7 không cần màn hình (1 lần)

Khi máy khởi động lại $\rightarrow$ Nhấn liên tục phím **`F2`** vào BIOS chỉnh 3 mục:
1. **`Power Management`** $\rightarrow$ **`AC Recovery`** $\rightarrow$ Chọn **`Power On`** *(Tự bật khi có điện lại)*.
2. **`Power Management`** $\rightarrow$ **`Block Sleep`** $\rightarrow$ Tích chọn **`[X] Block Sleep`** *(Chống tự ngủ)*.
3. **`POST Behavior`** $\rightarrow$ Bỏ tích ở 2 mục: `[ ] Keyboard Errors` và `[ ] Adapter Warnings` *(Rút bàn phím/màn hình không báo lỗi)*.
4. Bấm **`Apply`** $\rightarrow$ Bấm **`Exit`**.

👉 **LÚC NÀY BẠN RÚT TOÀN BỘ MÀN HÌNH, BÀN PHÍM VÀ ĐẦU CHUYỂN RA CẤT ĐI VĨNH VIỄN!**

---

### GIAI ĐOẠN 3: Kích hoạt Toàn bộ Hệ thống bằng "1 Dòng Lệnh"

Mở CMD trên máy tính Windows, SSH vào IP mạng LAN của máy mới (ví dụ: `ssh ubuntu@192.168.1.xxx`) và dán **đúng 1 dòng lệnh duy nhất**:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/Server-Homelab/setup_serverhomelab.sh)"
```

---

#### 📋 Những gì diễn ra tiếp theo:
1. **Xác nhận Tailscale:** Màn hình Terminal hiện ra 1 link dạng `https://login.tailscale.com/a/...` $\rightarrow$ Bạn click vào link đó trên trình duyệt để xác nhận tài khoản Gmail.
2. **Tắt hết hạn khóa:** Mở [login.tailscale.com/admin/machines](https://login.tailscale.com/admin/machines) $\rightarrow$ Bấm dấu `...` cạnh máy mới $\rightarrow$ Chọn **`Disable key expiry`**.
3. Máy tự động cài Docker, nén ZRAM, mở tường lửa, hạ nhiệt CPU và in ra bảng tổng kết kèm theo **`TAILSCALE IP : 100.x.y.z`**.

---

### GIAI ĐOẠN 4: Quản trị & Kiếm tiền qua WinSCP (Tùy biến thư mục tự do)

1. Mở **WinSCP** trên PC Windows:
   * **Host name:** Điền IP Tailscale **`100.x.y.z`** *(ví dụ: `100.95.126.50`)*.
   * **User:** `ubuntu` | **Password:** `123456`.
2. **Tự do tạo thư mục theo ý muốn:**
   * Bạn vào `/home/ubuntu` $\rightarrow$ Tự tạo các folder theo ý bạn (Ví dụ: `Proxy_VN`, `Proxy_US_1`, `Spide_Node_2`...).
   * Copy file `internetIncome.sh`, `properties.conf` và danh sách proxy vào các folder đó.
3. **Bật chạy kiếm tiền:**
   * Mở CMD gõ:
     ```bash
     cd /home/ubuntu/TÊN_FOLDER_CỦA_BẠN
     bash internetIncome.sh --start
     ```
4. **Kiểm tra sức khỏe 24/7:**
   * Gõ `docker ps` để xem các container đang chạy.
   * Gõ `ii-status` để xem bảng nhiệt độ, RAM, ZRAM và số lượng node.

---

### 📦 KHI MANG MÁY SANG CĂN NHÀ KHÁC ĐẶT:
1. Tắt máy an toàn: `sudo shutdown -h now`.
2. Sang nhà mới: Đặt máy đứng thẳng bằng chân đế $\rightarrow$ Cắm **dây nguồn** + Cắm **dây mạng LAN vào Router nhà mới** $\rightarrow$ Bật nguồn.
3. Ở bất kỳ đâu: Mở PC Windows bật Tailscale $\rightarrow$ Mở CMD `ssh ubuntu@100.x.y.z` hoặc mở WinSCP quản lý bình thường!
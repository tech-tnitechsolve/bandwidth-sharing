## PHẦN 1: RÀ SOÁT CÁC LỖI NGUY HIỂM & XUNG ĐỘT TRỰC TIẾP

Qua phân tích mã nguồn `internetIncome.sh` (nhánh test) đối chiếu với hạ tầng của bạn:

### 1. Lỗi chí tử: Vòng lặp "Bắt xóa rồi lại thiếu file" (Nguyên nhân lỗi bạn vừa gặp)
*   **Hiện tượng:** Tác giả đưa `libgcc.apk`, `iptables.apk`, `libmnl.apk`, `libnftnl.apk`, `hickory-dns.apk`, `dnscrypt-proxy` vào mảng **`files_to_be_removed`**.
*   **Vòng lặp vô tận:**
    1. Khi tải thiếu file $\rightarrow$ Docker báo lỗi `bind source path does not exist: libgcc.apk`.
    2. Bạn tự tải file vào thư mục $\rightarrow$ Chạy `--start` thì script kiểm tra `files_to_be_removed` và **báo lỗi: file đã tồn tại, bắt bạn phải chạy `--delete`**.
    3. Chạy `--delete` $\rightarrow$ Script **xóa sạch các file vừa tải**.
    4. Chạy lại `--start` $\rightarrow$ Lại thiếu file $\rightarrow$ Bế tắc hoàn toàn.

### 2. Hardcode URL Alpine và Version gói APK không thực tế
*   Script gán cứng: `ALPINE_VERSION="3.24"` (bản này chưa ổn định/chưa phát hành chính thức) và hardcode tên file như `libgcc-15.2.0-r5.apk`, `iptables-1.8.13-r0.apk`.
*   Khi CDN Alpine xoay vòng version (lên `-r6` hoặc đổi sang mirror khác), link cũ lập tức bị **404 Not Found** hoặc bị chặn IP VPS do dùng `wget` mặc định không có `User-Agent`.

### 3. Lỗi bảo mật & làm méo mật khẩu khi đọc `properties.conf` (`eval`)
*   Đoạn đọc cấu hình dùng lệnh: `value=$(eval "echo $value")`.
*   **Hậu quả:** Nếu mật khẩu Honeygain, EarnFM, BitPing hoặc Proxy của bạn có chứa các ký tự đặc biệt (`$`, `!`, `&`, `*`, `"`), `eval` sẽ hiểu nhầm là câu lệnh bash hoặc biến hệ thống $\rightarrow$ **Mật khẩu bị cắt cụt/làm rỗng $\rightarrow$ Container chạy lên nhưng không đăng nhập được tài khoản**.

### 4. Lỗi DinD Docker Socket trên Ubuntu 22.04 / 24.04 (Ebesucher, Adnade, Proxylite)
*   Script bind mount: `--mount type=bind,source=$(which docker),target=/usr/bin/docker` vào image Alpine (`docker:cli`).
*   File thực thi `/usr/bin/docker` trên Host chạy `glibc`, trong khi Alpine chạy `musl libc`. Điều này gây ra lỗi crash ngầm: `cannot execute binary file: Exec format error` khiến các container restart liên tục.


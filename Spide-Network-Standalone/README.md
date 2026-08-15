# Spide Standalone — lệnh ngắn gọn

## Device name có cần không?

**Có khi thêm thiết bị trên dashboard**, nhưng Linux CLI không nhận Device Name.

- `Device name`: bạn tự đặt trên dashboard, ví dụ `spide-001`, `spide-002`…
- `Device key`: lấy từ lệnh `--keys`.
- Device name chỉ là nhãn quản lý; Machine ID và Device Key mới là định danh kỹ thuật.

## 1. Chuẩn bị bằng WinSCP

Sửa hai file:

```text
proxies.txt
properties.conf
```

Cấu hình mặc định nên giữ:

```bash
USE_PROXIES=true
USE_SOCKS5_DNS=false
USE_DNS_OVER_HTTPS=true
SPIDE_MAX_INSTANCES=0
```

## 2. Chạy

```bash
cd /root/Spide-Network-Standalone
chmod +x spideNetwork.sh
sudo bash spideNetwork.sh --start
```

## 3. Lấy Device Key

Sau khi `--start` hoàn tất, script tự tạo:

```text
spide-device-keys.txt
```

Mở file này bằng WinSCP để copy Device name và Device key. Muốn cập nhật lại file:

```bash
sudo bash spideNetwork.sh --keys
```

Thêm từng dòng vào dashboard:

```text
INDEX 1 → Device name: spide-001 → Device key: cột DEVICE_KEY
INDEX 2 → Device name: spide-002 → Device key: cột DEVICE_KEY
INDEX 3 → Device name: spide-003 → Device key: cột DEVICE_KEY
```

## 4. Sau khi thêm key

```bash
sudo bash spideNetwork.sh --restart
sleep 15
sudo bash spideNetwork.sh --status
```

Trạng thái đúng:

```text
TUN_STATE=running
PEER_STATE=running
STATUS=OK
```

## 5. Backup một lần

```bash
sudo bash spideNetwork.sh --backup
```

## 6. Xóa container

```bash
sudo bash spideNetwork.sh --delete
```

Lệnh này giữ nguyên `spide-data` và Device Key. Chạy lại:

```bash
sudo bash spideNetwork.sh --start
```

Không xóa `spide-data` sau khi đã đăng ký thiết bị.

## Toàn bộ lệnh cần nhớ

```bash
sudo bash spideNetwork.sh --start    # chạy
sudo bash spideNetwork.sh --keys     # lấy key
sudo bash spideNetwork.sh --status   # kiểm tra
sudo bash spideNetwork.sh --restart  # tạo lại, giữ key
sudo bash spideNetwork.sh --backup   # backup Machine ID
sudo bash spideNetwork.sh --delete   # xóa container, giữ key
```

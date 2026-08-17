# Spide Network — chỉ 4 lệnh

Script chạy **TUN proxy + Spide peer** bằng Docker.

> **An toàn proxy:** Script chỉ dùng proxy của bạn cho luồng Spide peer kết nối tới Spide platform. **Không** gọi `ipify`, `curl` check IP, hay bất kỳ dịch vụ ngoài nào qua proxy. Mọi thao tác build/pull/quản lý container đều đi bằng **IP của chính VPS**.

Máy đã cài `setup_vps.sh` hoặc `setup_vm.sh` trước đó thì **không chạy lại setup**.

## File cần biết

| File | Vai trò |
|---|---|
| `proxies.txt` | Danh sách proxy, mỗi dòng 1 proxy |
| `properties.conf` | Cấu hình (tự tạo mặc định ở lần chạy đầu) |
| `spide-device-keys.txt` | Device name + Device key để paste vào dashboard |
| `spide-data/` | Machine ID và state cục bộ (giữ để dùng lại key) |

Dùng WinSCP để sửa:

```text
proxies.txt
properties.conf
```

Định dạng proxy trong `proxies.txt`:

```text
protocol://user:pass@host:port
```

Hỗ trợ: `http`, `https`, `socks4`, `socks5`. Dòng bắt đầu bằng `#` hoặc dòng trống sẽ bị bỏ qua.

`DEVICE_PREFIX=auto` trong `properties.conf` sẽ lấy tên folder. Ví dụ folder `MKVN_Spide` tự xuất tên:

```text
MKVN_Spide-001
MKVN_Spide-002
...
```

## Trước khi chạy

Vào đúng folder chứa script:

```bash
cd /root/MKVN_Spide
chmod +x spideNetwork.sh
```

Yêu cầu:

- Đang chạy user `root` (hoặc dùng `sudo`).
- Docker đã cài và daemon đang chạy.
- VPS/VM đã bật TUN (`/dev/net/tun`).
- Kiến trúc `x86_64/amd64`.

## 1. Bắt đầu tạo

```bash
bash spideNetwork.sh --create
```

Script tự tạo TUN, Spide peer và file:

```text
spide-device-keys.txt
```

Mở file TXT bằng WinSCP, copy `Device name` và `Device key` vào dashboard. Giữ các node đang chạy trong lúc add key.

## 2. Add device xong → triển khai

```bash
bash spideNetwork.sh --deploy
```

Lệnh tự đảm bảo TUN chạy, restart các Spide peer, chờ xác thực, cập nhật file key và báo số node `Status=OK`.

Nếu chưa đủ `OK`, kiểm tra key trên dashboard rồi chạy lại cùng lệnh:

```bash
bash spideNetwork.sh --deploy
```

## 3. Cập nhật proxy

Dùng WinSCP sửa/thêm/xóa dòng trong `proxies.txt`, sau đó:

```bash
bash spideNetwork.sh --update
```

- Proxy không đổi: giữ Machine ID và Device Key cũ.
- Proxy mới hoặc dòng proxy bị thay đổi: tạo Device Key mới.
- Proxy bị xóa: container tương ứng bị xóa.

Mở lại `spide-device-keys.txt`, add những key mới rồi chạy:

```bash
bash spideNetwork.sh --deploy
```

## 4. Xóa hoàn toàn container

```bash
bash spideNetwork.sh --remove
```

Lệnh xóa toàn bộ container TUN + Spide của folder nhưng giữ:

```text
spide-data/
spide-device-keys.txt
properties.conf
```

Vì vậy chạy `--create` lại vẫn dùng key cũ cho proxy không đổi.

## Tóm tắt

```bash
bash spideNetwork.sh --create  # tạo node + file key
bash spideNetwork.sh --deploy  # sau khi add key
bash spideNetwork.sh --update  # sau khi sửa proxies.txt
bash spideNetwork.sh --remove  # xóa toàn bộ container
```

## Lệnh phụ (không bắt buộc)

```bash
bash spideNetwork.sh --keys       # in lại danh sách key
bash spideNetwork.sh --status     # xem trạng thái TUN/peer
bash spideNetwork.sh --logs 3     # xem log peer số 3 (Ctrl+C để thoát)
bash spideNetwork.sh --logs       # xem tóm tắt log tất cả peer
bash spideNetwork.sh --validate   # kiểm tra format proxy + TUN khởi động (không gửi traffic qua proxy)
bash spideNetwork.sh --backup     # sao lưu Machine ID + key
bash spideNetwork.sh --version    # xem phiên bản
```

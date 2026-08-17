# Spide Network — chỉ 4 lệnh

Script chạy **TUN proxy + Spide peer** bằng Docker, tối ưu cho cả **VPS datacenter** lẫn **VM ở nhà**.

> **An toàn proxy:** Script chỉ dùng proxy của bạn cho luồng Spide peer kết nối tới Spide platform. **Không** gọi `ipify`, `curl` check IP, hay bất kỳ dịch vụ ngoài nào qua proxy. Mọi thao tác build/pull/quản lý container đều đi bằng **IP của chính máy chạy script**.

Máy đã cài `setup_vps.sh` hoặc `setup_vm.sh` trước đó thì **không chạy lại setup**.

## File cần biết

| File | Vai trò |
|---|---|
| `proxies.txt` | Danh sách proxy, mỗi dòng 1 proxy |
| `properties.conf` | Cấu hình (tự tạo mặc định ở lần chạy đầu) |
| `spide-device-keys.txt` | Device name + Device key để paste vào dashboard |
| `spide-data/` | Machine ID và state cục bộ (giữ để dùng lại key) |

Dùng WinSCP để sửa `proxies.txt` và `properties.conf`.

Định dạng proxy:

```text
protocol://user:pass@host:port
```

Hỗ trợ: `http`, `https`, `socks4`, `socks5`. Dòng bắt đầu bằng `#` hoặc dòng trống sẽ bị bỏ qua.

`DEVICE_PREFIX=auto` lấy theo tên folder. Ví dụ folder `MKVN_Spide` tự xuất tên `MKVN_Spide-001`, `MKVN_Spide-002`...

## Tối ưu sẵn cho VPS/VM (không cần sửa)

Các tham số này đã đặt trong `properties.conf` mặc định:

| Tham số | Giá trị | Tác dụng |
|---|---|---|
| `TUN_MTU` | `1400` | Tránh treo session / "log OK mà dashboard offline" do PMTU blackhole (thường gặp trên VPS). |
| `TUN_TCP_MSS` | `1360` | Kìm gói lớn (TLS/keepalive) cho khớp MTU. |
| `TUN_TCP_TIMEOUT` | `300` | Dọn kết nối TCP treo sau 5 phút, buộc thiết lập lại sớm. |
| `TUN_VERBOSITY` | `warn` | Hiện cảnh báo/lỗi TUN trong log để debug. |
| `HEAL_STALE_SEC` | `300` | `--heal` restart node nếu quá 5 phút không có `Status: OK`. |
| `WATCH_INTERVAL` | `60` | `--watch` quét mỗi 60 giây. |

Nếu VPS/dashboard vẫn chập chờn, thử hạ dần `TUN_MTU=1380` rồi `1300` (đặt `TUN_TCP_MSS=auto` để script tự tính = MTU − 40), sau đó `bash spideNetwork.sh --update`.

## Trước khi chạy

```bash
cd /root/MKVN_Spide     # hoặc folder chua script cua ban
chmod +x spideNetwork.sh
```

Yêu cầu: `root`/`sudo`, Docker đang chạy, `/dev/net/tun` tồn tại, CPU `x86_64`.

## 1. Bắt đầu tạo

```bash
bash spideNetwork.sh --create
```

Script tự tạo TUN, Spide peer và file `spide-device-keys.txt`. Mở file bằng WinSCP, copy `Device name` + `Device key` vào dashboard. Giữ các node đang chạy trong lúc add key.

## 2. Add device xong → triển khai

```bash
bash spideNetwork.sh --deploy
```

Lệnh tự đảm bảo TUN chạy, restart các Spide peer, chờ xác thực, cập nhật key và báo số node `Status=OK`. Nếu chưa đủ OK, kiểm tra key trên dashboard rồi chạy lại.

## 3. Cập nhật proxy

Sửa/thêm/xóa dòng trong `proxies.txt` (WinSCP), sau đó:

```bash
bash spideNetwork.sh --update
```

- Proxy không đổi: giữ Machine ID và Device Key cũ.
- Proxy mới/thay đổi: tạo Device Key mới → add lên dashboard → `--deploy`.
- Proxy bị xóa: container tương ứng bị xóa.

## 4. Xóa hoàn toàn container

```bash
bash spideNetwork.sh --remove
```

Xóa toàn bộ container TUN + Spide của folder nhưng vẫn giữ `spide-data/`, `spide-device-keys.txt`, `properties.conf`. Chạy `--create` lại vẫn dùng key cũ cho proxy không đổi.

## Tóm tắt

```bash
bash spideNetwork.sh --create  # tao node + file key
bash spideNetwork.sh --deploy  # sau khi add key
bash spideNetwork.sh --update  # sau khi sua proxies.txt
bash spideNetwork.sh --remove  # xoa toan bo container
```

## Giữ online ổn định (khuyến nghị cho VPS)

Đôi khi Spide CLI "treo âm thầm" (vẫn chạy nhưng ngừng báo trạng thái), khiến dashboard báo offline. Dùng `--heal` để tự khôi phục:

```bash
bash spideNetwork.sh --heal     # quet 1 luot, restart node bi treo/TUN chet
```

Để canh 24/7, gắn cron (chạy mỗi 5 phút, không trùng nhau nhờ lock sẵn có):

```bash
( crontab -l 2>/dev/null; echo '*/5 * * * * cd /root/MKVN_Spide && /bin/bash spideNetwork.sh --heal >> spide-data/heal.log 2>&1' ) | crontab -
```

Hoặc chạy trực tiếp trong `tmux`/`screen`:

```bash
bash spideNetwork.sh --watch    # lap lai 60s/lan
```

> `--heal` chỉ đọc log nội bộ và restart container cục bộ — **không** gọi dịch vụ ngoài, **không** dùng proxy.

## Lệnh phụ

```bash
bash spideNetwork.sh --keys       # in lai danh sach key
bash spideNetwork.sh --status     # xem trang thai TUN/peer
bash spideNetwork.sh --logs 3     # xem log peer so 3 (Ctrl+C de thoat)
bash spideNetwork.sh --logs       # tom tat log tat ca peer
bash spideNetwork.sh --validate   # kiem tra format proxy + TUN khoi dong (khong gui traffic qua proxy)
bash spideNetwork.sh --backup     # sao luu Machine ID + key
bash spideNetwork.sh --version    # xem phien ban (>= 1.4.0)
```

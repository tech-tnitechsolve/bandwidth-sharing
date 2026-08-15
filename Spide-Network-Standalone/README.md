# Spide Network Standalone

Folder này chỉ chạy TUN proxy + Spide. Không cần và không chạy lại `setup_vps.sh` hoặc `setup_vm.sh`.

## Vì sao không xung đột setup cũ?

- Entry point tên `spideNetwork.sh`, không phải `internetIncome.sh`.
- State tên `spide-nodes.tsv`, không tạo `containernames.txt`.
- Container dùng prefix riêng `spn-<project>-...` và Docker label riêng.
- Không sửa sysctl, firewall, DNS host, Docker daemon, cron, swap hoặc ZRAM.
- Không chỉnh file/folder InternetIncome khác.
- `--stop` remove container thay vì để trạng thái exited, nên cron cũ không tự start lại.
- Machine ID chỉ nằm trong `spide-data/nodes/` của folder này.

## Yêu cầu có sẵn

- Docker đang hoạt động.
- `/dev/net/tun` tồn tại.
- Linux x86_64/amd64.

Hai setup cũ của bạn đã chuẩn bị các yêu cầu này, nhưng không cần chạy lại chúng.

## Proxy list, HTTP/SOCKS và DNS

Folder có cấu hình tương tự InternetIncome:

```bash
USE_PROXIES=true
USE_SOCKS5_DNS=false
USE_DNS_OVER_HTTPS=true
```

`proxies.txt` hỗ trợ mỗi dòng một proxy:

```text
http://user:pass@host:port
https://user:pass@host:port
socks4://host:port
socks5://user:pass@host:port
```

Mỗi dòng tạo một TUN riêng. Với cấu hình mặc định, DNS dùng chế độ `over-tcp` trong đường TUN/proxy; nếu tắt cả hai DNS option, script dùng DNS `virtual` của tun2proxy.

## Chạy

```bash
cd Spide-Network-Standalone
nano proxies.txt
nano properties.conf
sudo bash spideNetwork.sh --start
```

Lần đầu script sẽ:

1. Tự xác định tier RAM.
2. Tải/build Spide CLI chính thức có kiểm tra SHA-256.
3. Tạo một TUN riêng cho mỗi proxy.
4. Kiểm tra egress IP, bỏ proxy lỗi và IP trùng.
5. Tạo Machine ID bền vững theo hash proxy.
6. Tạo một Spide peer dùng network namespace của TUN tương ứng.
7. In Device Key.

## Lệnh

```bash
sudo bash spideNetwork.sh --keys
sudo bash spideNetwork.sh --status
sudo bash spideNetwork.sh --validate
sudo bash spideNetwork.sh --restart
sudo bash spideNetwork.sh --stop
sudo bash spideNetwork.sh --backup
```

Đăng ký cột `DEVICE_KEY` vào dashboard, sau đó:

```bash
sudo bash spideNetwork.sh --restart
sleep 15
sudo bash spideNetwork.sh --status
```

## Resource tự động

| RAM máy | Spide | Spide swap | TUN | TUN swap |
|---:|---:|---:|---:|---:|
| ≤2.5 GB | 96 MB | 192 MB | 64 MB | 128 MB |
| ≤5 GB | 128 MB | 256 MB | 96 MB | 192 MB |
| ≤9 GB | 160 MB | 320 MB | 128 MB | 256 MB |
| >9 GB | 192 MB | 384 MB | 160 MB | 320 MB |

Có thể ghi đè giá trị `auto` trong `properties.conf` nếu cần.

## Dữ liệu cần giữ

```text
spide-data/nodes/<proxy-hash>/machine-id
spide-data/spide-nodes.tsv
```

Không xóa `spide-data` sau khi đăng ký Device Key.

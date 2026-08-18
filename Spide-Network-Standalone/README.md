# Spide Network standalone — v1.5.0: thêm chế độ DIRECT (IP gốc VPS)

Script `spideNetwork.sh` giờ hỗ trợ **2 chế độ chạy**, đổi bằng đúng 1 biến trong
`properties.conf`:

| Chế độ | `USE_PROXIES=` | Hành vi |
|---|---|---|
| PROXY (mặc định) | `true` | Mỗi dòng trong `proxies.txt` = 1 container TUN (tun2proxy) + 1 Spide peer. Cần `/dev/net/tun` bật. |
| DIRECT (IP gốc VPS) | `false` | Spide peer chạy trực tiếp `--network host` → dùng đúng IP gốc của VPS. **Không cần** `proxies.txt`, **không cần** `/dev/net/tun`, không tạo TUN nào. |

## Cách dùng chế độ DIRECT

```bash
# 1. Sửa properties.conf: USE_PROXIES=false
#    (optional) SPIDE_MAX_INSTANCES=0  -> 1 peer; 3 -> 3 peer cùng IP VPS

# 2. Tạo node + lấy Device Key
bash spideNetwork.sh --create

# 3. Dán Device name + Device key vào Spide dashboard, sau đó:
bash spideNetwork.sh --deploy

# Theo dõi / tự phục hồi (như cũ)
bash spideNetwork.sh --status
bash spideNetwork.sh --watch        # hoặc đặt --heal vào cron
```

Khi nào muốn quay lại dùng proxy: sửa `USE_PROXIES=true`, đặt lại `proxies.txt`,
rồi `bash spideNetwork.sh --update` (proxy cũ giữ Machine ID, key không đổi).

## Thay đổi chính trong v1.5.0

- `load_config`: chấp nhận `USE_PROXIES=false` (trước đây bắt buộc `true`), in rõ
  chế độ đang chạy. `USE_PROXIES` được validate là `true`/`false`.
- `start_all`: rẽ nhánh —
  - DIRECT: tạo `count` peer với `--network host`, Machine ID cố định theo
    `direct-<index>` (bền vững qua `--update`, mỗi peer 1 key riêng).
  - PROXY: giữ nguyên luồng cũ (TUN + peer).
- `prereq`: chỉ kiểm tra `/dev/net/tun` khi `USE_PROXIES=true`.
- `deploy_all` / `__heal_body` / `show_status`: bỏ qua bước TUN trong chế độ
  DIRECT (cột TUN_STATE hiển thị `-`, NETWORK_MODE = `host`).
- `validate_only`: trong DIRECT chỉ xác nhận chế độ, không cần proxy.
- Không thêm bất kỳ lệnh gọi dịch vụ ngoài nào (vẫn không check IP qua ipify/curl).

## Lưu ý

- Nhiều peer DIRECT cùng chung 1 IP VPS — nếu Spide giới hạn số device/IP, hãy
  để `SPIDE_MAX_INSTANCES=0` (chỉ 1 peer) hoặc thử 2–3 peer xem dashboard.
- `USE_SOCKS5_DNS`, `USE_DNS_OVER_HTTPS`, `TUN_*` chỉ có tác dụng khi
  `USE_PROXIES=true`; ở DIRECT chúng bị bỏ qua.
- Docker peer dùng `--read-only` + bind machine-id như cũ — an toàn như bản gốc.

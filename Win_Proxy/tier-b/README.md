# Tier B — Windows THẬT (QEMU/KVM) cho nền tảng phát hiện Wine

`qemu-win.sh` chạy **Windows thật** trong VM (không phải Wine). Dùng khi app
Windows-only bị phát hiện Wine / crash (Electron, cần .NET, cần SMBIOS-WMI thật,
cần driver kernel). Fingerprint = 100% máy thật vì là Windows thật.

> ⚠️ Nặng hơn Wine rất nhiều — **chỉ dùng cho số ít nền tảng khó tính**.
> Mọi nền tảng còn lại nên chạy tier Wine (Win_Proxy) để VPS không ăn hết lợi nhuận.

## 1. Chuẩn bị base image (1 lần, làm trên máy có KVM)

1. Cài Windows 10/11 **LTSC / IoT Enterprise** (nhẹ nhất, ít telemetry, tắt được update).
2. Trong VM cài **driver virtio-win** (viostor, netkvm) — lấy từ
   https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/
3. Cài app cần chạy (để base image chứa sẵn app → overlay nhỏ).
4. `sysprep /generalize /oobe /shutdown` rồi tắt máy → copy file `.qcow2` ra làm base.

## 2. Kết nối mạng VM → proxy (KHÔNG được lộ IP VPS)

VM dùng `-netdev tap` → tap bridge trên host → đẩy qua **tun2socks/tun2proxy**
(chính công cụ bạn đang dùng trong List_Proxy/Spide, setup_vps.sh đã cài):

```bash
# 1) Tạo bridge chứa các tap VM
sudo ip link add br0 type bridge
sudo ip link set br0 up
sudo ip addr add 10.77.0.1/24 dev br0

# 2) Mỗi VM: thêm tap vào bridge (qemu-win.sh tự tạo tap tên tap<seed8>)
sudo ip link set tap<seed8> master br0
sudo ip link set tap<seed8> up

# 3) Tạo 1 TUN route toàn bộ 10.77.0.0/24 qua proxy (1 proxy = 1 TUN = 1 VM)
sudo ip tuntap add dev tunX mode tun
sudo ip link set tunX up
sudo ip route add 10.77.0.0/24 dev tunX
sudo tun2socks -device tunX -proxy socks5://user:pass@host:port -tcp-sndbuf 1M -tcp-rcvbuf 1M
```

Mỗi VM = 1 proxy = 1 TUN riêng. Như vậy mọi traffic của Windows đi qua proxy,
giống hệt kiến trúc `--network=container:tunN` của tier Wine — **TUN chết = VM mất
mạng = kill-switch tự nhiên, không rò rỉ IP VPS**.

## 3. Dùng

```bash
qemu-win.sh --create <seed> <proxy_ip> TR Istanbul Europe/Istanbul
qemu-win.sh --run <seed>
qemu-win.sh --list ; qemu-win.sh --stop <seed>
```

- `<seed>`: dùng chính dòng proxy (`socks5://...`) để danh tính khớp proxy như tier Wine.
- SMBIOS (manufacturer/product/serial/uuid/MAC) được lấy từ `identity.sh` → **đồng bộ
  hoàn toàn với tier Wine** (đổi tier không đổi danh tính).
- VNC `127.0.0.1:<port>` để login app lần đầu; xem port khi chạy `--run`.

## 4. Chi phí / VPS (tham khảo)

| Cấu hình VPS | Wine box (tier A) | QEMU VM (tier B) |
|---|---|---|
| RAM 4GB | ~5–7 máy | 1–2 VM |
| RAM 8GB | ~12–16 máy | 3–4 VM |
| RAM 16GB | ~28–32 máy | 7–8 VM |

Bật ZRAM (setup_vps.sh đã làm) để swap nén, giảm áp lực RAM.

# Spide Network — chỉ 4 lệnh

Máy đã cài `setup_vps.sh` hoặc `setup_vm.sh` trước đó thì **không chạy lại setup**.

Dùng WinSCP để sửa:

```text
proxies.txt
properties.conf
```

`DEVICE_PREFIX=auto` sẽ lấy tên folder. Ví dụ folder `Spide-Mkvn` tự xuất tên:

```text
Spide-Mkvn-001
Spide-Mkvn-002
...
```

## 1. Bắt đầu tạo

```bash
cd /home/antoine/Spide-Mkvn
sudo bash spideNetwork.sh --create
```

Script tự tạo TUN, Spide peer và file:

```text
spide-device-keys.txt
```

Mở file TXT bằng WinSCP, copy `Device name` và `Device key` vào dashboard. Giữ các node đang chạy trong lúc add key.

## 2. Add device xong → triển khai

```bash
sudo bash spideNetwork.sh --deploy
```

Lệnh tự restart các Spide peer, chờ xác thực, cập nhật file key và báo số node `Status=OK`.

Nếu chưa đủ `OK`, kiểm tra key trên dashboard rồi chạy lại cùng lệnh:

```bash
sudo bash spideNetwork.sh --deploy
```

## 3. Cập nhật proxy

Dùng WinSCP sửa/thêm/xóa dòng trong `proxies.txt`, sau đó:

```bash
sudo bash spideNetwork.sh --update
```

- Proxy không đổi: giữ Machine ID và Device Key cũ.
- Proxy mới hoặc dòng proxy bị thay đổi: tạo Device Key mới.
- Proxy bị xóa: container tương ứng bị xóa.

Mở lại `spide-device-keys.txt`, add những key mới rồi chạy:

```bash
sudo bash spideNetwork.sh --deploy
```

## 4. Xóa hoàn toàn container

```bash
sudo bash spideNetwork.sh --remove
```

Lệnh xóa toàn bộ container TUN + Spide của folder nhưng giữ:

```text
spide-data/
spide-device-keys.txt
```

Vì vậy chạy `--create` lại vẫn dùng key cũ cho proxy không đổi.

## Tóm tắt

```bash
sudo bash spideNetwork.sh --create  # tạo node + file key
sudo bash spideNetwork.sh --deploy  # sau khi add key
sudo bash spideNetwork.sh --update  # sau khi sửa proxies.txt
sudo bash spideNetwork.sh --remove  # xóa toàn bộ container
```

#### Chạy script cài đặt
```bash
sudo bash install-shield.sh
```

---

### CÁCH 2: CHẠY 1 LỆNH DUY NHẤT (NẾU MUỐN CHẠY NHANH KHÔNG CẦN TẠO FILE)

```bash
curl -fsSL https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/Fix-Pawnapp-Tool/install-shield.sh | sudo bash
```

*(Hoặc dùng lệnh `wget` nếu VPS chưa có curl:)*
```bash
wget -qO- https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/Fix-Pawnapp-Tool/install-shield.sh | sudo bash
```

---

### HƯỚNG DẪN KHI SETUP MÁY CHỦ VPS MỚI:

1. **Cài đặt tool cày tiền:** Chạy script cài đặt của bên bán như bình thường.
2. **Kích hoạt bộ lọc:** Chạy `sudo bash install-shield.sh` (chỉ mất 3 giây).
3. **Sử dụng:** Vào Web UI Pawns Manager (`:8787`), add proxy và tạo thiết bị cày tiền bình thường.

* *Khi nào muốn gỡ bỏ hoàn toàn trên VPS nào đó, chỉ cần gõ:*
  ```bash
  sudo bash install-shield.sh --uninstall
  ```

---

### LỆNH GỠ BỎ 1-DÒNG (NẾU CẦN GỠ SẠCH TRÊN VPS NÀO ĐÓ):
```bash
curl -fsSL https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/Fix-Pawnapp-Tool/install-shield.sh | sudo bash -s -- --uninstall
```

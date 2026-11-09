### HƯỚNG DẪN KHI SETUP MÁY CHỦ VPS MỚI:

1. **Cài đặt tool cày tiền:** Chạy script cài đặt của bên bán như bình thường.
2. **Kích hoạt bộ lọc:** Chạy `sudo bash install-shield.sh` (chỉ mất 3 giây).
3. **Sử dụng:** Vào Web UI Pawns Manager (`:8787`), add proxy và tạo thiết bị cày tiền bình thường.

---
### CHẠY 1 LỆNH DUY NHẤT (NẾU MUỐN CHẠY NHANH KHÔNG CẦN TẠO FILE)

```bash
curl -fsSL "https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/Fix-Pawnapp-Tool/install-shield.sh?v=$(date +%s)" | sudo bash
```
---

### LỆNH GỠ BỎ 1-DÒNG (NẾU CẦN GỠ SẠCH TRÊN VPS NÀO ĐÓ):
```bash
curl -fsSL https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/Fix-Pawnapp-Tool/install-shield.sh | sudo bash -s -- --uninstall
```




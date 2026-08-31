# Thư mục installers/ — installer Windows cho các nền tảng

Có **2 cách** đưa installer vào (chọn 1):

## Cách 1 (khuyến nghị): tải tự động từ link chính thức

```bash
cd Win_Proxy
sudo bash winIncome.sh --fetch
```

Script tự tải các installer theo `<KEY>_URL` đã khai báo trong `properties.conf`,
lưu vào thư mục này với tên `<KEY>_INSTALLER`, và ghi SHA256 vào `.sha256` (để đối
chiếu). Các link này **đã được xác minh từ trang chính thức**:

| Nền tảng | Link tải (chính thức) | Lưu thành |
|---|---|---|
| PassiveApp | https://cdn.passiveapp.com/passiveapp/desktop-app/PassiveApp%20Desktop%20Setup%201.0.15%20x64.exe | `PassiveApp-Setup.exe` |
| ByteBenefit | https://app.bytebenefit.io/ByteBenefit_Setup | `ByteBenefit-Setup.exe` |
| Trees App | https://downloads.trees.app/trees/latest/Trees-App-Setup.exe | `Trees-App-Setup.exe` |

## Cách 2: tải tay

Tải file từ link trên (bản **Windows x64**), bỏ vào thư mục này và đặt tên đúng
như `properties.conf`:

```
PassiveApp-Setup.exe
ByteBenefit-Setup.exe
Trees-App-Setup.exe
```

## Sau khi tải xong

```bash
sudo bash winIncome.sh --validate   # kiểm tra đủ installer chưa
sudo bash winIncome.sh --start      # cài tự động + chạy
```

## Lưu ý quan trọng

- **Đường dẫn `.exe` sau khi cài** (`<KEY>_LAUNCH`) cần đối chiếu thật. Nhiều app
  Electron cài vào `%LOCALAPPDATA%` (không phải `C:\Program Files`). Kiểm tra:
  ```bash
  ls instances/<hash>/prefix/drive_c/users/wineuser/AppData/Local/Programs/
  ```
  rồi sửa `<KEY>_LAUNCH` trong `properties.conf` cho khớp.
- **Cờ cài im lặng** mặc định `/S` (NSIS). Nếu installer dùng Inno Setup, đổi
  `<KEY>_INSTALL_FLAGS=/VERYSILENT`. Không rõ thì để trống và cài tay qua VNC
  (`WIN_VNC=true` rồi SSH tunnel).
- `Trees-App-Setup.exe` là link `latest` (tự cập nhật phiên bản) — sau lần tải đầu,
  `--fetch` **giữ nguyên bản đang có** để đảm bảo ổn định (không tự đổi phiên bản).

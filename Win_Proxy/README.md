# 🪟 Win_Proxy — Chạy nền tảng WINDOWS-ONLY trong Docker trên Linux VPS

> PassiveApp · ByteBenefit · Trees · (thêm nền tảng khác dễ dàng)

Bản nâng cấp cho `List_Proxy` của bạn: các nền tảng **chỉ có bản Windows** (không có
Linux) giờ chạy được trực tiếp trong **từng container Docker**, mỗi container = **1 máy
Windows ảo** gắn với **1 proxy** qua TUN — danh tính máy được sinh **thật sâu, khớp
proxy**, không rò rỉ IP VPS.

```
   proxies.txt (1 dòng = 1 proxy)
        │
        ├─► container "wintun-xxx"  : tun2proxy → proxy (DNS over-tcp, IPv6 tắt)
        └─► container "winapp-xxx"  : Windows-box (Wine + Xvfb) --network=container:TUN
                                       ├─ MachineGuid / tên máy / BIOS-OEM / MAC / tz / locale
                                       │   (sinh tự động, ổn định, KHỚP GEO proxy)
                                       └─ chạy app: PassiveApp + ByteBenefit + Trees ...
```

---

## 1. Vì sao chọn Wine (không phải Windows full)?

| Phương án | RAM/máy | Fingerprint | VPS 8GB chạy được | Dùng khi |
|---|---|---|---|---|
| **Wine box (mặc định)** | ~300–600MB | Rất sát (registry + WMI một phần) | **~12–16 máy** | Đa số app chỉ đọc `MachineGuid`, tên máy, IP |
| QEMU Windows thật (tier-b) | 1.5–2GB | 100% máy thật | 3–4 máy | App phát hiện Wine / Electron crash / cần .NET |

→ **Mặc định dùng Wine** để "VPS không ăn hết lợi nhuận". Chỉ chuyển sang
[`tier-b/`](tier-b/) cho nền tảng thực sự khó tính. Hai tier **dùng chung một bộ
sinh danh tính** (`image/identity.sh`) nên đổi tier không làm đổi danh tính máy.

---

## 2. Bắt đầu nhanh

## 1b. Cách hoạt động & cách setup (từng bước, dễ hiểu)

**Mô hình:** 1 dòng proxy trong `proxies.txt` = **1 "máy PC" ảo**. Mỗi PC ảo chạy
**NHIỀU nền tảng cùng lúc** (đúng như một người thật cài nhiều app trên 1 máy).

**Bạn chỉ cần làm 2 việc:**

```bash
cd Win_Proxy

# ① Tải installer .exe của từng nền tảng (TỰ ĐỘNG — từ link chính thức trong config)
sudo bash winIncome.sh --fetch
#    (hoặc tải tay rồi bỏ vào thư mục installers/)

# ② Dán danh sách proxy vào proxies.txt (1 dòng = 1 proxy, kèm hint geo tùy chọn)
vi proxies.txt

# ③ Chạy — script tự: build image -> cài từng .exe vào TỪNG container -> chạy app -> auto-login
sudo bash winIncome.sh --setup
```

**Script làm gì với từng .exe:** mỗi container "PC ảo" khởi động → Wine chạy installer
(`PASSIVEAPP_INSTALLER`, `BYTEBENEFIT_INSTALLER`, `TREES_INSTALLER`) → tự dò đường dẫn
`.exe` sau khi cài → chạy từng app trong `WIN_APPS`. **Đúng: 1 container chạy nhiều
platform miễn là .exe cài được và có trong `WIN_APPS`.**

**Kết nối mạng:** mỗi PC ảo gắn với 1 TUN riêng (`tun2proxy` → proxy của dòng tương ứng),
DNS qua proxy, IPv6 tắt → toàn bộ traffic của các app trong PC đó đi qua đúng 1 proxy.

---

## 2. Bắt đầu nhanh

```bash
cd Win_Proxy

# 1. (lần đầu) cài Docker
sudo bash winIncome.sh --install

# 2. Tải installer .exe (tự động từ link chính thức) + điền proxies.txt
sudo bash winIncome.sh --fetch

# 3. Tự động toàn bộ (1 lệnh: cài docker -> build -> tải installer -> validate -> start)
sudo bash winIncome.sh --setup

# Quản lý
sudo bash winIncome.sh --status          # bảng trạng thái từng máy
sudo bash winIncome.sh --checkproxy      # kiểm tra proxy bằng IP VPS (KHÔNG gọi qua proxy)
sudo bash winIncome.sh --probe 1         # (chẩn đoán tay) egress qua proxy == IP proxy
sudo bash winIncome.sh --leaktest 1      # (chẩn đoán tay) IP + ASN + DNS leak
sudo bash winIncome.sh --login 1         # tự đăng nhập app (xdotool, cần credentials)
sudo bash winIncome.sh --shot 1          # chụp ảnh màn hình để xác minh
sudo bash winIncome.sh --doctor          # chẩn đoán toàn diện 1 lệnh
sudo bash winIncome.sh --install-watch   # cài systemd tự heal 24/7
sudo bash winIncome.sh --logs 1
sudo bash winIncome.sh --restart | --stop | --delete | --deleteBackup
sudo bash winIncome.sh --heal            # sửa container chết (1 lượt)
sudo bash winIncome.sh --watch           # canh 24/7
```

**Link cài chính thức (đã xác minh 08/2026):**

| Nền tảng | Link | Ghi chú |
|---|---|---|
| PassiveApp | `cdn.passiveapp.com/passiveapp/desktop-app/PassiveApp Desktop Setup 1.0.15 x64.exe` | version pin 1.0.15 |
| ByteBenefit | `app.bytebenefit.io/ByteBenefit_Setup` | Infatica-powered |
| Trees | `downloads.trees.app/trees/latest/Trees-App-Setup.exe` | `latest` tự xoay bản |

**Đăng nhập app lần đầu — tự động (ít thao tác nhất):** điền
`<KEY>_LOGIN_EMAIL`/`<KEY>_LOGIN_PASSWORD` trong `properties.conf` → script tự login
bằng xdotool, chụp ảnh xác minh vào `instances/<hash>/prefix/apps/<KEY>.png`
(xem bằng `--shot N`). Nếu form login của app khác mặc định (email→Tab→pass→Enter),
dùng `<KEY>_LOGIN_SCRIPT` để chỉnh kịch bản phím. Không điền credentials = login tay
qua VNC (`WIN_VNC=true`, SSH tunnel `5900 + số thứ tự`). Phiên đăng nhập nằm trong
`instances/<hash>/prefix` — giữ vĩnh viễn, kể cả khi `--delete`.

---

## 3. Yêu cầu ① — Danh tính "giống real device" (sâu & chuẩn)

Mọi danh tính được sinh **từ seed = chính dòng proxy** → **1 proxy = 1 danh tính ổn
định**; đổi proxy = đổi máy (đúng luật "1 device / 1 IP" của mọi nền tảng). Không lưu
trùng lặp: proxy trùng tự bị bỏ.

| Hạng mục | Giá trị sinh | Cách app đọc |
|---|---|---|
| **MachineGuid** | GUID v4 ngẫu nhiên (đúng chuẩn version/variant bit) | Registry `HKLM\...\Cryptography\MachineGuid` |
| **Tên máy** | `DESKTOP-XXXXXXX` (chữ cái thật, không ký tự lạ) | `GetComputerName`, registry ComputerName + ActiveComputerName + `Tcpip\Parameters\Hostname` |
| **Windows SKU** | Win10/11 Pro·Home (build 19045/22631, DisplayVersion, ReleaseId, UBR, EditionID) | `GetVersionEx`, registry `Windows NT\CurrentVersion` |
| **ProductId / InstallDate** | 5 nhóm số chuẩn · epoch thật trong 1–4 năm | registry `ProductId`, `InstallDate` |
| **RegisteredOwner/Org** | tên người theo region | registry `RegisteredOwner` |
| **OEM/Model** | cặp khớp thật (Dell/HP/Lenovo/ASUS/Acer/MSI + model tương ứng) | registry `OEMInformation`, `SystemInformation` |
| **BIOS** | vendor (Dell/AMI/Insyde/Phoenix), version, release date | registry `HARDWARE\DESCRIPTION\System\BIOS` |
| **BaseBoard** | mã bo mạch thật (0K2RCD, LNVNB161216, ...) | registry BIOS\BaseBoard* |
| **CPU** | desktop thật (i5/i7/Ryzen 5/7 — KHÔNG phải Xeon/QEMU của VPS) | registry `HARDWARE\DESCRIPTION\System\CentralProcessor\0` + `SystemInformation` |
| **Build metadata** | BuildLabEx, BuildBranch, SystemRoot, CurrentType | registry `Windows NT\CurrentVersion` |
| **MAC** | OUI thật (Intel/Realtek/ASUS...) + 3 octet theo seed | `--mac-address` trên container TUN → app thấy qua `GetAdaptersInfo` |
| **Timezone** | khớp geo proxy, gồm **cả Bias chuẩn + ActiveTimeBias (DST)** | registry `TimeZoneInformation` + env `TZ` |
| **Locale/LCID/keyboard** | `LocaleName`, `sCountry`, `sLanguage`, `iCountry`, `Geo\Nation`, **Keyboard Layout Preload** theo quốc gia proxy | registry `International` + `Keyboard Layout` |
| **Màn hình** | độ phân giải laptop thật **riêng từng máy** (1920×1080/1366×768/2560×1440...) + DPI 96 | `WIN_SCREEN` từ identity → Xvfb (ảnh hưởng `screen.width/height` của Electron) |
| **Hostname (Linux)** | = tên máy Windows (không phải hex container-id) | `--hostname` |

> **Đồng bộ với proxy:** timezone + locale + OEM + tên người được chọn **theo country
> của proxy** (từ hint `#CC:City:TZ` trong `proxies.txt`, hoặc tự tra geo của IP proxy
> **phía host, direct** — không bao giờ gọi qua proxy để sinh identity).

### ⚠️ Giới hạn trung thực của Wine (phải biết để chọn tier)

| Tín hiệu | Wine | Windows thật (tier-b) |
|---|---|---|
| Registry (MachineGuid, SKU, tz, locale, **CPU**, BuildLab...) | ✅ giả được (đầy đủ) | ✅ thật |
| CPU model string | ✅ registry giả (i5/i7/Ryzen) · ⚠️ lệnh CPUID vẫn trả CPU VPS | ✅ thật (`-cpu host`) |
| SMBIOS/WMI đầy đủ (`Win32_BIOS`, `Win32_ComputerSystemProduct`) | ⚠️ một phần | ✅ thật (`-smbios type=0..3`) |
| Canvas/WebGL renderer (app Electron) | ⚠️ SwiftShader (không GPU) | ✅ GPU ảo |
| Driver/đồ họa/tray thật | ⚠️ Wine giả | ✅ thật |
| Electron/Chromium (Trees, ByteBenefit) | ⚠️ có thể crash — TEST TRƯỚC | ✅ chạy mượt |

→ **Quy trình khuyên dùng:** chạy Wine trước; nếu app crash liên tục / dashboard
không nhận device / bị ban, chuyển nền tảng đó sang `tier-b`.

---

## 4. Yêu cầu ② — Chống rò rỉ tuyệt đối (leak-proof)

| Véc-tơ rò rỉ | Biện pháp |
|---|---|
| **IP VPS lộ ra ngoài** | App chạy `--network=container:<TUN>` → **không có NIC nào khác**. TUN chết = app mất mạng = kill-switch tự nhiên. |
| **Proxy chết/hết hạn làm lộ IP VPS** | **Kill-switch chủ động** trong mỗi app container (`net_guard` đọc `/proc/net/route`): app **chỉ chạy khi default route đi qua `tun*`**; nếu route rơi về `eth0` (nguy cơ lộ IP VPS) → **giết wine ngay**. TUN chạy `--tun tun0 --exit-on-fatal-error` → proxy chết thì tự thoát → Docker tự nối lại; `--heal/--watch` tạo lại app để JOIN lại netns TUN mới. |
| **DNS query lộ** | tun2proxy `--dns over-tcp` → mọi DNS đi **qua proxy**. App container **pin `resolv.conf` = `WIN_DNS_SERVERS`** (entrypoint root) → query 8.8.8.8/1.1.1.1 đều bị route vào tun, không ra resolver VPS. |
| **IPv6 lộ** | `--sysctl net.ipv6.*.disable_ipv6=1` trên TUN. |
| **App đọc filesystem host** | Wine bỏ ổ `Z:` (mount gốc `/`); app chỉ thấy `/prefix` riêng. Không mount `docker.sock`, không mount `/etc`, `/root`, `/home`. |
| **Leak qua container metadata** | Hostname máy = tên máy Windows (đặt trong entrypoint — KHÔNG dùng cờ `--hostname` vì Docker cấm khi dùng `--network=container:`); MAC riêng mỗi máy (trên TUN container). |
| **Leak qua docker socket / privileged** | Không có `-v /var/run/docker.sock`, không `--privileged`, `--security-opt no-new-privileges`, cap-drop có chủ đích: **bỏ `NET_ADMIN`/`NET_RAW`/`SETPCAP`/`MKNOD`/`SYS_CHROOT`…** (app KHÔNG thể sửa route hay mở raw socket trong netns TUN), giữ `SETUID/SETGID/DAC_OVERRIDE` để entrypoint hạ quyền xuống `wineuser` + pin `resolv.conf`. (Chỉ `--cap-add SYS_ADMIN` nếu bật `WIN_SET_HOSTNAME`.) |
| **Probe lúc start** | `VALIDATE_PROXIES=false` — không gọi request nào qua proxy lúc tạo (bảo vệ proxy IP-auth). |
| **Time/NTP** | `TZ` khớp geo; Wine không tự đồng bộ NTP. |
| **Telemetry Wine** | `WINEDLLOVERRIDES="mscoree=d;mshtml=d"` — không tải mono/gecko, không traffic ngoài TUN. |

**Tự kiểm tra rò rỉ bất cứ lúc nào:**

```bash
sudo bash winIncome.sh --probe 1      # nhanh: chỉ IP egress
sudo bash winIncome.sh --leaktest 1   # sâu: IP + ASN/Org + DNS path

# PASS khi:
#  [1] IP egress = IP proxy
#  [2] Org = ISP residential (KHÔNG phải datacenter/cloud của VPS)
#  [3] remote_ip kết nối != IP VPS (DNS/HTTPS đều đi qua proxy)
```

---

## 4b. 🔑 Proxy IP-Authentication & IP VPS (cực kỳ quan trọng)

> **Quy tắc của bạn (đã áp dụng đúng):** proxy dạng `user:pass` nhưng bản chất vẫn là
> **IP-Authentication** (whitelist IP nguồn). Vì vậy **TẤT CẢ proxy đều là 1 loại** —
> kiểm tra thật kỹ bằng **CHÍNH IP VPS**, **KHÔNG gọi bất kỳ request nào QUA proxy**.

```bash
sudo bash winIncome.sh --myip         # in IP VPS — đem whitelist vào dashboard proxy
sudo bash winIncome.sh --checkproxy   # kiểm tra từng proxy bằng IP VPS (KHÔNG gọi qua proxy)
sudo bash winIncome.sh --validate     # kiểm tra config + proxy (0 bandwidth)
```

| Hành vi | Cách xử lý của script |
|---|---|
| **Dò IP VPS** | `get_vps_ip()`: direct (KHÔNG qua proxy), cache 24h, 4 endpoint HTTPS dự phòng. Nếu VPS chặn egress → gán cứng `VPS_IP=<ip>` trong `properties.conf`. |
| **`--checkproxy`** | TCP connect tới `host:port` proxy từ IP VPS + bắt tay auth SOCKS5 (nếu có user:pass). **KHÔNG gửi lệnh CONNECT** → proxy không tốn bandwidth, không bị "bẩn", không lỗi IP-Auth. |
| **MỌI proxy (kể cả user:pass)** | Đều có thể cần IP VPS được whitelist. Script không bao giờ phân biệt "user:pass thì khỏi whitelist". |
| **`--probe` / `--leaktest`** | Là **chẩn đoán THỦ CÔNG** (chỉ chạy khi bạn gõ lệnh): gửi request QUA proxy để xác minh egress. **Không nằm trong bất kỳ luồng tự động nào.** |
| **Luồng tự động (`--setup/--fetch/--validate/--checkproxy/--doctor/--heal/--watch`)** | **KHÔNG BAO GIỜ gọi ra ngoài qua proxy.** Mọi kết nối đi từ IP VPS. |
| **Nhiều NIC / sai IP nguồn** | `--doctor` đếm số default route → cảnh báo nếu >1 (egress có thể đi sai NIC → proxy thấy sai IP). Gán `VPS_IP` đúng. |
| **Nhiều thư mục trên cùng 1 VPS** | `PROJECT_ID` (hash đường dẫn) làm tên container + **cổng VNC trượt theo PROJECT_ID** → không đụng cổng/không đụng tên. |

---

## 5. Yêu cầu ③ — Ổn định cao + nhẹ (không ăn hết lợi nhuận)

| Cơ chế | Chi tiết |
|---|---|
| **RAM tự cân (vài trăm MB/máy)** | `*_MEMORY=auto` chia bậc theo RAM VPS. Mặc định **384–512MB/máy Wine + 64–96MB/TUN** (4GB VPS ≈ 7–9 máy). |
| **ZRAM** | `setup_vps.sh` của bạn đã bật ZRAM zstd → swap nén, chạy nhiều máy hơn RAM vật lý. |
| **Đẩy cache lên tmpfs** | `/winehome` + `%TEMP%` = tmpfs 128MB (không ghi disk, không phình ổ, giảm I/O). |
| **Wine tối giản** | Chỉ wine64 (không wine32 = tiết kiệm ~600MB image + RAM), tắt mono/gecko, bỏ winbind. |
| **Giới hạn chặt** | `--pids-limit`, `--memory`, `--memory-swap`, `--cpu-shares`, `--ulimit nofile` → 1 máy chết không kéo sập cả VPS. |
| **Tự phục hồi** | `--restart unless-stopped` + `--heal`/`--watch` (quét 60s, tự start container chết) + vòng restart app bên trong (`win-init.sh`). |
| **Khởi động tuần tự** | `DELAY_BETWEEN_CONTAINER` tránh sốc RAM/CPU lúc start hàng loạt. |
| **Log xoay vòng** | `--log-driver local --log-opt max-size=1m` → không phình disk. |
| **Pin version** | Image TUN + Windows-box pin cứng → không bị break khi upstream đổi bản. |

**Dự kiến RAM/CPU cho 1 máy (1 proxy):**

| Thành phần | RAM (idle) | CPU (idle) | Ghi chú |
|---|---|---|---|
| Wine + 1 app tray (vd PassiveApp) | ~280–350MB | 1–3% | wineserver + app |
| Mỗi app thêm (ByteBenefit, Trees...) | +60–150MB | +1–2% | app Electron nặng hơn app .NET |
| Xvfb (desktop ảo) | ~15–25MB | ~0.5% | bật VNC thêm ~10MB |
| TUN (tun2proxy) | ~30–50MB | ~1% | mỗi proxy 1 TUN |
| **Tổng 1 máy chạy 3 nền tảng** | **~500–700MB** | **~4–7%** | burst khi app gọi server |

**Sức chứa tham khảo (Wine tier, 3 nền tảng/máy):**

| VPS | Số máy (proxy) chạy ổn định | RAM/máy ước tính |
|---|---|---|
| 4GB | ~5–7 | ~550MB |
| 8GB | ~10–13 | ~600MB |
| 16GB | ~22–26 | ~650MB |

> Mẹo scale: (1) tắt `WIN_VNC` sau khi login xong (tiết kiệm RAM + CPU); (2) bật ZRAM
> (setup_vps.sh đã làm); (3) bắt đầu 1 nền tảng/máy, đo 72h rồi mới stack thêm;
> (4) giảm `DELAY_BETWEEN_CONTAINER` nếu muốn start nhanh hơn.

---

## 6. Hồ sơ nền tảng (đã xác minh 08/2026)

| Nền tảng | Client | Nhận diện thiết bị | Ghi chú khi ảo hóa |
|---|---|---|---|
| **PassiveApp** ([internet-sharing](https://www.passiveapp.com/internet-sharing)) | Windows installer .exe | account (email) + IP | Thân thiện nhất — app tray đơn giản. Wine chạy tốt. |
| **ByteBenefit** ([dashboard](https://dashboard.bytebenefit.io)) | Windows installer (Infatica-powered) + Android APK | account + IP | Hệ sinh thái Infatica — theo dõi kỹ uptime; nếu nghi ngờ hãy test tier-b. |
| **Trees** ([dashboard](https://dashboard.trees.app)) | Windows installer `Trees-App-Setup.exe` + macOS/Android | account + IP | Nhiều khả năng Electron → **test Wine trước**, crash thì tier-b. |

**Thêm nền tảng mới trong tương lai (không cần sửa script):**

1. Trong `properties.conf`: thêm `KEY` vào `WIN_APPS=...` và khai báo
   `<KEY>_INSTALLER`, `<KEY>_URL` (link chính thức), `<KEY>_LAUNCH`,
   `<KEY>_INSTALL_FLAGS`, `<KEY>_ARGS`.
2. `--fetch` để tải installer, rồi `--start` lại.

---

## 6b. 🔬 Các nền tảng THỰC SỰ check gì? (nghiên cứu từ EarnApp/Honeygain)

> Kết luận quan trọng nhất: **chúng KHÔNG check fingerprint phần cứng sâu** (MachineGuid,
> SMBIOS, canvas). Chúng check **IP + mẫu hình hành vi**. Dồn công sức đúng chỗ.

| Nền tảng | Cái THỰC SỰ bị check | Bằng chứng |
|---|---|---|
| **EarnApp** | IP residential (VPN/datacenter bị chặn qua dịch vụ IP-quality), **số device cùng dải /24,/16,/8**, mẫu hình tài khoản (ngày tạo, rút tiền, di chuyển device) | [thảo luận ban account](https://github.com/engageub/InternetIncome/discussions/375) · [tài liệu IP blocked](https://help.earnapp.com/hc/en-us/articles/10201052442897) |
| **Honeygain** | **1 device/IP**, IP datacenter, "network overused" | [Network overused](https://support.honeygain.com/hc/en-us/articles/360011078900) |
| **EarnApp (quy định)** | Cấm VM/Docker/cloud — nhưng phát hiện chủ yếu qua **IP + hành vi**, không phải sniff phần cứng | [help.earnapp.com](https://help.earnapp.com/hc/en-us/articles/10199416541969) |

### → Hệ quả thực dụng

1. **Đòn bẩy số 1 = chất lượng proxy/IP**: IP residential đúng geo, không bị dùng chung,
   không trùng dải /24 với quá nhiều account. **Đây là thứ quyết định lời/lỗ**, không phải
   fingerprint.
2. **Đòn bẩy số 2 = 1 device / 1 IP + device ID ổn định.** Bộ identity của Win_Proxy đã
   làm đúng: 1 proxy = 1 danh tính cố định (MachineGuid + tên máy), đổi proxy = đổi máy.
3. **Fingerprint sâu (CPU/SMBIOS/canvas) chỉ là phòng thủ thêm** — rẻ, giữ lại, nhưng đừng
   kỳ vọng nó "cứu" một IP datacenter. **Không có fingerprint nào che được IP datacenter.**
4. **Rủi ro thật sự với mô hình của bạn** = nhiều account dùng chung 1 proxy / 1 dải /24,
   hoặc IP proxy bị seller bán cho nhiều người. Giữ luật: **1 account = 1 proxy = 1 máy,
   không trùng dải IP** (trùng khớp với "seller share IP cho người khác" trong rủi ro mục 10
   của `Readme.md` gốc).

---

## 6c. 📊 Log thông minh & tự đánh giá online/earning (KHÔNG gọi qua proxy)

**Ghi log thông minh (trong container, tự dọn — không nghẽn ổ):**

| Cơ chế | Chi tiết |
|---|---|
| Log riêng từng app | `instances/<hash>/prefix/apps/logs/<KEY>.log` — mỗi dòng có timestamp UTC đầu dòng. |
| Xoay vòng | File quá `WIN_LOG_MAX_KB` (2MB) → giữ 1 bản `.log.1`, mở file mới. |
| Tự xóa theo tuổi | Log/ảnh cũ hơn `WIN_LOG_RETENTION_DAYS` (mặc định **4 ngày**) → tự xóa (nền 10 phút/lần). |
| Cắt dòng dài | Dòng log bị cắt `WIN_LOG_MAX_LINE` (400 ký tự) → app log "loạn" cũng không phình disk. |
| Heartbeat + netstate | `apps/.alive_<KEY>` (nhịp tim app), `apps/.netstate` (UP/LEAK/DOWN) — orchestrator đọc trực tiếp, **không cần request qua proxy**. |

**Đọc kết quả — 1 lệnh:**

```bash
sudo bash winIncome.sh --health        # toàn bộ máy
sudo bash winIncome.sh --health 1      # máy số 1
sudo bash winIncome.sh --logs 1        # docker log + log thông minh từng app
sudo bash winIncome.sh --cleanlogs     # dọn tay log/ảnh cũ (thêm 1 lớp chống nghẽn)
```

`--health` parse log trong `WIN_LOG_LOOKBACK_MIN` (60 phút) để phân loại từng app:

- **ONLINE** = log có tín hiệu online/earning (`LOG_ONLINE`)
- **WARN** = vừa có tín hiệu vừa có lỗi (vd: proxy timeout nhưng vẫn kết nối lại được)
- **ERROR** = log toàn lỗi (auth/proxy/mạng) → proxy hết hạn/chết là nguyên nhân hàng đầu
- **IDLE** = app chạy nhưng im · **NOLOG** = chưa ghi log (chưa khởi động xong)

Đồng thời báo: trạng thái TUN/app, **net=UP/LEAK/DOWN** (LEAK là nghiêm trọng), heartbeat,
số lần restart, và tầng TCP/auth của proxy (kiểm tra **chỉ từ IP VPS**). Từ khóa tùy chỉnh
được theo app qua `<KEY>_LOG_ONLINE` / `<KEY>_LOG_ERROR` trong `properties.conf`.

---

## 7. Phân tích bổ sung & khuyến nghị (yêu cầu ④)

1. **Đừng chạy nhiều nền tảng trên cùng 1 proxy ngay lập tức.** Nhiều nền tảng trả
   tiền theo device duy nhất/IP. Khởi động với 1 nền tảng/máy, đo 72h (giống protocol
   trong `Readme.md` gốc), rồi mới stack thêm app khác vào cùng máy nếu dashboard
   chấp nhận nhiều device/IP.

2. **Danh tính gắn với proxy = lợi thế ẩn.** Khi bạn thay proxy chết bằng proxy mới,
   danh tính máy tự đổi theo → tránh bị "1 device đăng nhập từ nhiều IP khác nhau" (dấu
   hiệu farm bị ban). Nhưng nếu cần **giữ** danh tính khi đổi proxy cùng geo, copy
   `instances/<hash_cũ>/identity/*` sang `instances/<hash_mới>/identity/` trước khi
   `--start`.

3. **Geo hint là bắt buộc nếu muốn chuẩn 100%.** `#CC:City:TZ` trong `proxies.txt` giúp
   timezone/locale/OEM khớp chính xác, và không phụ thuộc vào IP-geo bên thứ 3. Nên
   ghi hint cho mọi dòng proxy US/UK/TW (những nước bạn ưu tiên).

4. **Rủi ro ToS.** Các nền tảng bandwidth-sharing thường cấm VM/farm/multi-account
   (giống bảng rủi ro trong `Readme.md` gốc). Bản ảo hóa này giảm tối đa dấu hiệu máy
   ảo, nhưng **không loại bỏ hoàn toàn** (Wine vẫn khác Windows thật ở vài tín hiệu).
   Chạy đúng luật "1 device/1 IP", đừng cày quá số lượng.

5. **Residual risk lớn nhất của Wine = CPUID + SMBIOS sâu (WMI).** Registry
   `CentralProcessor` đã được giả (i5/i7/Ryzen) nhưng lệnh **CPUID** vẫn trả CPU VPS
   (Xeon/QEMU), và `Win32_Processor`/SMBIOS serial đầy đủ qua WMI thì Wine chỉ đáp ứng
   một phần. Nếu nền tảng đọc WMI sâu → chuyển sang `tier-b` (SMBIOS thật, CPU thật) —
   đừng cố "vá" bằng Wine.

6. **Tun2proxy `--dns over-tcp` đã là DoH tương đương** — đừng bật thêm dnscrypt/hickory
   như nhánh test cũ (đã gây lỗi vòng lặp trong `Fix_note.md`). Cấu hình DNS chuẩn duy
   nhất là: TUN over-tcp + host direct upstream (setup_vps.sh đã khóa `chattr +i`).

7. **Đo ROI thật trước khi scale.** Mỗi máy Wine tốn ~450MB RAM (384–512MB) + ~5% CPU.
   Với VPS giá $X, chỉ nên scale khi `$/máy/tháng` đo được > chi phí RAM/CPU chia theo
   máy (tính theo bảng mục 5). Đo bằng `--status` + dashboard từng nền tảng sau 72h.

8. **Kiến trúc "chạy được trên hầu hết VPS":** chỉ cần Docker + `/dev/net/tun` + CPU
   amd64 (tự kiểm tra bằng `--doctor`). Không dùng bridge/port host (tránh xung đột),
   cổng VNC bind `127.0.0.1` và trượt theo PROJECT_ID, tên container có PROJECT_ID
   (hash đường dẫn) → **nhiều thư mục / nhiều VPS không đụng nhau**.

---

## 8. Cấu trúc thư mục

```
Win_Proxy/
├── winIncome.sh            # orchestrator (--setup/--status/--probe/--leaktest/--login/--shot/--doctor/--heal/...)
├── Dockerfile.wine         # build image Windows-box (Wine + Xvfb + xdotool/scrot)
├── properties.conf         # cấu hình (app + URL tải + auto-login + tài nguyên)
├── proxies.txt             # 1 dòng = 1 proxy (kèm hint geo tùy chọn)
├── installers/             # installer .exe (tự tải bằng --fetch)
├── image/
│   ├── identity.sh         # bộ sinh danh tính Windows (gen/show/apply)
│   ├── win-init.sh         # entrypoint (boot/identity/install/auto-detect/app)
│   └── login.sh            # tự đăng nhập (xdotool) + chụp ảnh xác minh
└── tier-b/
    ├── README.md           # Windows thật (QEMU/KVM) cho nền tảng khó tính
    └── qemu-win.sh
```

## Tự động hóa — "ít thao tác nhất" (tóm tắt)

| Việc | Trước | Bây giờ |
|---|---|---|
| Cài Docker + build + installer + start | nhiều lệnh tay | **`--setup` (1 lệnh)** |
| Tải installer đúng bản | tải tay từ web | **`--fetch`** (link chính thức trong config) |
| Tìm đường dẫn `.exe` sau khi cài | đối chiếu tay | **`<KEY>_LAUNCH=auto` + `<KEY>_DETECT`** (tự dò) |
| Đăng nhập từng app | VNC tay từng máy | **auto-login xdotool kiểu người thật** (`<KEY>_LOGIN_EMAIL/PASSWORD`) — gõ phím tốc độ ngẫu nhiên, di chuột, nghỉ ngẫu nhiên |
| Xác minh app đã login | mở VNC nhìn | **`--shot N`** (ảnh PNG) |
| Kiểm tra môi trường | gõ từng lệnh | **`--doctor`** |
| Giữ app sống 24/7 | tay | **`--install-watch`** (systemd) + **kill-switch mạng** (proxy chết → không lộ IP, tự nối lại) |
| Kiểm tra proxy (KHÔNG gọi qua proxy) | tay | **`--checkproxy`** (TCP + bắt tay auth từ IP VPS) |
| Theo dõi online/earning từng app | mở dashboard tay | **`--health`** (parse log, KHÔNG gọi qua proxy) |
| Dọn log cũ (chống nghẽn ổ) | tay | **tự động** (giữ 4 ngày) + **`--cleanlogs`** |
| Kiểm tra rò rỉ (chẩn đoán tay) | tay | **`--leaktest`** (IP + ASN + DNS, có cảnh báo rõ) |
| IP VPS cho proxy IP-Auth | tự tra/đoán | **`--myip`** (auto-dò + cache 24h, hoặc `VPS_IP=` gán cứng) |

> **Lưu ý bảo trì:** `instances/<hash>/identity/` chứa danh tính + `identity.reg`,
> `instances/<hash>/prefix/` chứa Wine prefix (login app). `--delete` giữ lại;
> `--deleteBackup` mới xóa (mất login vĩnh viễn). Sao lưu `instances/` nếu đổi VPS.

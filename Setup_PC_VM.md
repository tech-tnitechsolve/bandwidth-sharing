# 🌐 MASTER PLAYBOOK: 24/7 BANDWIDTH SHARING & MULTI-PC HIGH-DENSITY FARM
> **Kiến trúc hạ tầng tối ưu toàn diện:** Tối ưu hóa Modem ISP -> Windows Host -> Virtualization Hypervisor -> Linux VM Kernel -> Tự động hóa Anti-Ban.

---

## 📑 MỤC LỤC
1. [Định Mức Giới Hạn Node & Băng Thông An Toàn](#1-định-mức-giới-hạn-node--băng-thông-an-toàn)
2. [Chiến Lược Mở Rộng Khi Chạy Nhiều PC (Multi-PC Farm)](#2-chiến-lược-mở-rộng-khi-chạy-nhiều-pc-multi-pc-farm)
3. [Giải Pháp Tăng Băng Thông & Chống Nghẽn Đường Truyền](#3-giải-pháp-tăng-băng-thông--chống-nghẽn-đường-truyền)
4. [Quy Trình Tối Ưu Hóa Modem Nhà Mạng (ONT Router)](#4-quy-trình-tối-ưu-hóa-modem-nhà-mạng-ont-router)
5. [Quy Trình Tối Ưu Hóa Máy Tính Windows Host](#5-quy-trình-tối-ưu-hóa-máy-tính-windows-host)
6. [Cấu Hình Mạng Máy Ảo (VMware / VirtualBox)](#6-cấu-hình-mạng-máy-ảo-vmware--virtualbox)
7. [Khởi Chạy & Lệnh Điều Khiển Telemetry (setup_vm.sh)](#7-khởi-chạy--lệnh-điều-khiển-telemetry-setup_vmsh)
8. [Cẩm Nang Xử Lý Sự Cố (Troubleshooting FAQ)](#8-cẩm-nang-xử-lý-sự-cố-troubleshooting-faq)

---

## 1. ĐỊNH MỨC GIỚI HẠN NODE & BĂNG THÔNG AN TOÀN

Khi chạy trên đường truyền mạng gia đình (Viettel, FPT, VNPT gói 150Mbps – 300Mbps), việc phân bổ node cần tuân thủ các mốc tải sau:

### A. Định mức theo loại IP:
* **IP Gốc Dân Cư (Direct Residential IP):**
  * **Quy tắc:** Chỉ chạy **1 Node duy nhất cho mỗi nền tảng** trên cùng 1 IP (1 Honeygain, 1 Pawns, 1 EarnApp, 1 Mysterium, 1 Spide, 1 Grass...).
  * *Lý do:* Chạy trùng tài khoản hoặc cắm nhiều máy chung 1 IP gốc sẽ bị nền tảng hạ điểm uy tín (Quality Score), giảm 70% thu nhập hoặc khóa tài khoản.
* **Chạy qua Proxy (Residential / Datacenter Proxies):**
  * **1 PC (4 Core / 8GB – 16GB RAM):** Gánh tối đa **50 – 150 Proxy Nodes**.
  * **1 PC (8 Core / 32GB RAM):** Gánh tối đa **200 – 350 Proxy Nodes**.

### B. Định mức tiêu thụ mạng trên 1 đường truyền:
* **Lưu lượng Upload khuyến nghị:** Dưới **3 TB – 5 TB / tháng / đường mạng**.
* *Lưu ý:* Vượt quá 5 TB/tháng trên gói cước cá nhân sẽ kích hoạt hệ thống DPI của nhà mạng, tự động bóp tốc độ luồng quốc tế.

---

## 2. CHIẾN LƯỢC MỞ RỘNG KHI CHẠY NHIỀU PC (MULTI-PC FARM)

Khi mở rộng quy mô từ **2 đến 10 PC** chạy đồng thời trên cùng một mạng gia đình, bạn bắt buộc phải áp dụng các giải pháp phần cứng sau:

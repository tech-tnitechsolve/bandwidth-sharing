# 1. Tạo Sheild bảo vệ cho proxy: chặn các cổng và Request nguy hiểm ảnh hưởng
```
sudo bash -c 'RAW_URL="https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/List_Proxy/webshare_shield.sh?v=$(date +%s)"; SHIELD_BIN="/usr/local/bin/webshare_shield.sh"; rm -f "$SHIELD_BIN" /tmp/shield.sh; curl -4 -sSL -H "Cache-Control: no-cache, no-store" -H "Pragma: no-cache" "$RAW_URL" -o "$SHIELD_BIN" && chmod +x "$SHIELD_BIN" && "$SHIELD_BIN"'
```
<img width="1108" height="421" alt="image" src="https://github.com/user-attachments/assets/1dfb17ef-a52f-4bbc-b62b-f64130a7424d" />

--------------------------------------------------------------------------
# 2. Chạy lại cho các Proxy cũ hết băng thông đã được Renew
```
curl -4 -sSL "https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/List_Proxy/fix_bandwidth.sh?v=$(date +%s)" -o fix_bandwidth.sh && chmod +x fix_bandwidth.sh && ./fix_bandwidth.sh
```

# LỆNH "QUÉT TOÀN BỘ VPS"
#### Cơ chế hoạt động của lệnh này:
1. **Tự động lùng sục:** Tìm tất cả các folder trên VPS đang chứa `containernames.txt`.
2. **Tự động tải về:** Tải bản mới nhất của `fix_bandwidth.sh` từ GitHub nạp thẳng vào đúng từng folder đó.
3. **Tự động phân quyền & chạy:** Lần lượt chui vào từng folder, kích hoạt chạy đo lường, gỡ FlapGuard, đánh thức các node ngất và nghiệm thu kết quả cho bạn.

```
sudo bash -c 'RAW_URL="https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/List_Proxy/fix_bandwidth.sh"; for f in $(find /home /root -maxdepth 5 -name "containernames.txt" -type f 2>/dev/null); do d=$(dirname "$f"); echo -e "\n\033[1;36m>>> ĐANG UPDATE VÀ CHẠY TẠI: $d <<<\033[0m"; curl -4 -sSL "$RAW_URL" -o "$d/fix_bandwidth.sh"; chmod +x "$d/fix_bandwidth.sh"; (cd "$d" && ./fix_bandwidth.sh); done'
```



<img width="1087" height="439" alt="image" src="https://github.com/user-attachments/assets/baee6f3e-7409-4d47-ab42-139aef54ab19" />

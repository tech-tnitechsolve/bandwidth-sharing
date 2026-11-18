# 1. Chạy lại cho các Proxy cũ hết băng thông đã được Renew
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
--------------------------------------------------------------------------

# 2. Tạo Sheild bảo vệ cho proxy: chặn các cổng và Request nguy hiểm ảnh hưởng
```
sudo bash -c 'RAW_URL="https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/List_Proxy/webshare_shield.sh?v=$(date +%s)"; SHIELD_BIN="/usr/local/bin/webshare_shield.sh"; curl -4 -sSL -H "Cache-Control: no-cache, no-store" -H "Pragma: no-cache" "$RAW_URL" -o "$SHIELD_BIN" && chmod +x "$SHIELD_BIN" && "$SHIELD_BIN" && systemctl restart webshare-watcher.service 2>/dev/null || true'
```

# Check tổng xem đã bảo vệ oke chưa

```
sudo bash -c 'RAW_URL="https://raw.githubusercontent.com/tech-tnitechsolve/bandwidth-sharing/main/List_Proxy/audit_system.sh?v=$(date +%s)"; AUDIT_BIN="/usr/local/bin/audit_system.sh"; curl -4 -sSL -H "Cache-Control: no-cache, no-store" -H "Pragma: no-cache" "$RAW_URL" -o "$AUDIT_BIN" && chmod +x "$AUDIT_BIN" && "$AUDIT_BIN"'
```
--------------------------------------------------------------------------

# Xóa Tool Shield khi không cần nữa
```
sudo bash -c '
SHIELD_KEY="webshare""_shield.sh"
AUDIT_KEY="audit""_system.sh"

# 1. Dừng và xóa systemd watcher + chỉ xóa dòng cron của shield (giữ nguyên cron setup_vps)
systemctl stop webshare-watcher.service 2>/dev/null || true
systemctl disable webshare-watcher.service 2>/dev/null || true
rm -f /etc/systemd/system/webshare-watcher.service
systemctl daemon-reload 2>/dev/null || true
sed -i "/${SHIELD_KEY}/d" /etc/cron.d/internetincome 2>/dev/null || true

# 2. Diệt tiến trình shield còn chạy ngầm (không tự kill bash -c)
for p in $(pgrep -f "$SHIELD_KEY" 2>/dev/null || true); do
  [[ "$p" != "$$" && "$p" != "$PPID" ]] && kill -9 "$p" 2>/dev/null || true
done

# 3. Gỡ sạch chain WEBSHARE_SHIELD trong mọi container đang chạy (giữ nguyên disable_ipv6 của internetIncome)
for pid in $(docker inspect --format "{{.State.Pid}}" $(docker ps -q 2>/dev/null) 2>/dev/null | sort -u); do
  if (( pid > 0 )); then
    while nsenter -t "$pid" -n iptables -D OUTPUT -j WEBSHARE_SHIELD 2>/dev/null; do :; done
    nsenter -t "$pid" -n iptables -F WEBSHARE_SHIELD 2>/dev/null || true
    nsenter -t "$pid" -n iptables -X WEBSHARE_SHIELD 2>/dev/null || true
  fi
done

# 4. Dọn sạch block domain trong file hosts của MỌI container (cả đang chạy & đã dừng)
for h in $(docker inspect --format "{{.HostsPath}}" $(docker ps -aq 2>/dev/null) 2>/dev/null); do
  if [[ -f "$h" ]] && grep -q "WEBSHARE COMPLIANCE FILTER" "$h" 2>/dev/null; then
    tmp_h=$(mktemp)
    awk "/# --- WEBSHARE COMPLIANCE FILTER/{exit} {print}" "$h" > "$tmp_h" && cat "$tmp_h" > "$h"
    rm -f "$tmp_h"
  fi
done

# 5. Xóa file script webshare_shield & audit_system
rm -f "/usr/local/bin/${SHIELD_KEY}" "/usr/local/bin/${AUDIT_KEY}"

echo -e "\n\033[1;32m[HOÀN TẤT] ĐÃ XÓA SẠCH CÁC SHIELD & GIỮ NGUYÊN CẤU HÌNH SETUP_VPS!\033[0m\n"
'
```

<img width="1108" height="421" alt="image" src="https://github.com/user-attachments/assets/1dfb17ef-a52f-4bbc-b62b-f64130a7424d" />

--------------------------------------------------------------------------



<img width="1087" height="439" alt="image" src="https://github.com/user-attachments/assets/baee6f3e-7409-4d47-ab42-139aef54ab19" />

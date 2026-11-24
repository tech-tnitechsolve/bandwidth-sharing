# 1. Chạy ĐÚNG 1 LỆNH NÀY (chỉ làm 1 lần sau khi up del_proxy.sh qua WinSCP)
```
sudo bash -c 'for p in "$PWD/del_proxy.sh" /home/ubuntu/del_proxy.sh /root/del_proxy.sh; do if [ -f "$p" ]; then sed -i "s/\r$//" "$p" && chmod +x "$p" && ln -sf "$p" /usr/local/bin/ii-del-proxy && echo "XONG: $p -> da tao lenh ii-del-proxy"; break; fi; done'
```

# 2. Sau này mỗi lần cần xóa Proxy, gõ ĐÚNG 1 LỆNH:
```
sudo ii-del-proxy
```
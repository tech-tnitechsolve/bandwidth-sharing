# Restart lại Traffmonetier khi thiếu device IP

echo "[*] Đang làm mới kết nối dàn Traffmonetizer..."
for c in $(docker ps --filter "name=traffmon" --format "{{.Names}}"); do
    docker restart "$c" >/dev/null 2>&1
    echo " -> Đã làm mới: $c"
    sleep 1
done
echo "[✓] Hoàn tất! Đã kéo đủ lại toàn bộ thiết bị!"

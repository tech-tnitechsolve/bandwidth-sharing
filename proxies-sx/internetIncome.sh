#!/usr/bin/env bash
#============================================================================
#  Proxies.sx Dedicated Fleet Runner (TCP Proxy Dispatcher Engine)
#  Commands: bash internetIncome.sh [--start | --delete | --status | --deleteBackup]
#============================================================================
set -Eeuo pipefail

CURRENT_DIR=$(pwd)
FOLDER_NAME=$(basename "$CURRENT_DIR")
CONTAINER_NAMES_FILE="containernames.txt"
CONFIG_FILE="properties.conf"
PROXY_FILE="proxies.txt"

GREEN="\e[32m"; RED="\e[31m"; YELLOW="\e[33m"; NC="\e[0m"

[[ -f "$CONFIG_FILE" ]] && sed -i 's/\r$//' "$CONFIG_FILE" 2>/dev/null || true
[[ -f "$PROXY_FILE" ]] && sed -i 's/\r$//' "$PROXY_FILE" 2>/dev/null || true

# ----------------- 1. HÀM DELETE -----------------
if [[ "${1:-}" == "--delete" ]]; then
    echo -e "${YELLOW}[*] Đang dừng và xóa container thuộc cụm: ${FOLDER_NAME}...${NC}"
    if [[ -f "$CONTAINER_NAMES_FILE" ]]; then
        while IFS= read -r container || [[ -n "$container" ]]; do
            [[ -z "$container" ]] && continue
            docker rm -f "$container" >/dev/null 2>&1 || true
            echo -e "    -> Đã xóa: $container"
        done < "$CONTAINER_NAMES_FILE"
        rm -f "$CONTAINER_NAMES_FILE"
    fi
    docker ps -aq --filter "name=-${FOLDER_NAME}-" | xargs -r docker rm -f >/dev/null 2>&1 || true
    echo -e "${GREEN}[✓] Đã dọn dẹp sạch toàn bộ container của ${FOLDER_NAME}!${NC}"
    exit 0
fi

# ----------------- 2. HÀM DELETE BACKUP -----------------
if [[ "${1:-}" == "--deleteBackup" ]]; then
    echo -e "${YELLOW}[*] Đang xóa sạch container và dữ liệu state của: ${FOLDER_NAME}...${NC}"
    bash "$0" --delete
    rm -rf data "$CONTAINER_NAMES_FILE"
    echo -e "${GREEN}[✓] Đã làm mới dữ liệu toàn bộ cụm.${NC}"
    exit 0
fi

# ----------------- 3. HÀM STATUS -----------------
if [[ "${1:-}" == "--status" ]]; then
    echo -e "${GREEN}=== TRẠNG THÁI PROXIES.SX: ${FOLDER_NAME} ===${NC}"
    if [[ ! -f "$CONTAINER_NAMES_FILE" ]]; then
        echo "Không có container nào đang chạy trong folder này."
        exit 0
    fi
    printf " %-30s %-12s %-10s %s\n" "CONTAINER" "STATUS" "RAM" "OUTBOUND IP (PROXY)"
    echo "----------------------------------------------------------------------------------"
    while IFS= read -r cname || [[ -n "$cname" ]]; do
        [[ -z "$cname" ]] && continue
        if [[ "$cname" == psx-* ]]; then
            STATUS=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "DEAD")
            MEM=$(docker stats "$cname" --no-stream --format "{{.MemUsage}}" 2>/dev/null | awk '{print $1}' || echo "N/A")
            # Kiểm tra IP thực tế qua đúng cổng Proxy
            IP=$(docker exec "$cname" curl -s4 -m 5 -x http://127.0.0.1:8080 https://api.ipify.org 2>/dev/null || echo "Connecting/Lag")
            printf " %-30s %-12s %-10s %s\n" "$cname" "$STATUS" "$MEM" "$IP"
        fi
    done < "$CONTAINER_NAMES_FILE"
    exit 0
fi

# ----------------- 4. HÀM START -----------------
if [[ "${1:-}" == "--start" ]]; then
    [[ -f "$CONFIG_FILE" ]] || { echo -e "${RED}[!] Thiếu file $CONFIG_FILE${NC}"; exit 1; }
    [[ -f "$PROXY_FILE" ]] || { echo -e "${RED}[!] Thiếu file $PROXY_FILE${NC}"; exit 1; }
    [[ -f "entrypoint.js" ]] || { echo -e "${RED}[!] Thiếu file entrypoint.js${NC}"; exit 1; }

    source "$CONFIG_FILE"

    [[ -n "${PROXIES_SX_API_KEY:-}" ]] || { echo -e "${RED}[!] Lỗi: PROXIES_SX_API_KEY đang để trống trong $CONFIG_FILE${NC}"; exit 1; }

    echo -e "${YELLOW}[*] Đang build Docker Image Proxies.sx...${NC}"
    docker build -t local/proxies-peer:official . >/dev/null

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}  KHỞI CHẠY PROXIES.SX (TCP PROXY DISPATCHER): ${FOLDER_NAME}${NC}"
    echo -e "${GREEN}================================================================${NC}"

    touch "$CONTAINER_NAMES_FILE"
    INDEX=1
    DELAY="${DELAY_BETWEEN_CONTAINER:-2}"

    while IFS= read -r PROXY_URL || [[ -n "$PROXY_URL" ]]; do
        PROXY_URL=$(echo "$PROXY_URL" | tr -d '\r' | xargs)
        [[ -z "$PROXY_URL" || "$PROXY_URL" =~ ^#.* ]] && continue

        TUNNEL_CONTAINER="tun-${FOLDER_NAME}-${INDEX}"
        WORKER_CONTAINER="psx-${FOLDER_NAME}-${INDEX}"
        STATE_DIR="./data/node-${INDEX}"
        mkdir -p "$STATE_DIR"

        docker rm -f "$WORKER_CONTAINER" "$TUNNEL_CONTAINER" >/dev/null 2>&1 || true

        # 1. Tunnel Container: Gost TCP Bridge (Hỗ trợ 100% SOCKS5/HTTP Proxy không cần UDP)
        docker run -d \
            --name "$TUNNEL_CONTAINER" \
            --restart unless-stopped \
            --dns=1.1.1.1 --dns=8.8.8.8 \
            ginuerzh/gost -L=http://:8080 -L=socks5://:1080 -F="$PROXY_URL" > /dev/null

        # 2. Worker Container: Nhúng Entrypoint Dispatcher ép toàn bộ traffic qua 127.0.0.1:8080
        docker run -d \
            --name "$WORKER_CONTAINER" \
            --network="container:$TUNNEL_CONTAINER" \
            --restart unless-stopped \
            -e API_KEY="$PROXIES_SX_API_KEY" \
            -e AGENT_NAME="${DEVICE_NAME}-${FOLDER_NAME}-${INDEX}" \
            -e HTTP_PROXY="http://127.0.0.1:8080" \
            -e HTTPS_PROXY="http://127.0.0.1:8080" \
            -e PEER_STATE_FILE="/state/id.json" \
            -v "$CURRENT_DIR/$STATE_DIR:/state" \
            local/proxies-peer:official > /dev/null

        echo "$TUNNEL_CONTAINER" >> "$CONTAINER_NAMES_FILE"
        echo "$WORKER_CONTAINER" >> "$CONTAINER_NAMES_FILE"

        echo -e "  [+] Node #${INDEX} ($WORKER_CONTAINER) -> Đã gán vào Proxy: $PROXY_URL"

        sleep "$DELAY"
        INDEX=$((INDEX + 1))
    done < "$PROXY_FILE"

    echo -e "${GREEN}================================================================${NC}"
    echo -e "${GREEN}[✓] Đã kích hoạt hoàn tất $((INDEX - 1)) nodes!${NC}"
    echo -e "    - Kiểm tra: bash internetIncome.sh --status"
    echo -e "    - Dừng cụm: bash internetIncome.sh --delete"
    echo -e "${GREEN}================================================================${NC}"
    exit 0
fi

echo -e "Cách dùng: bash internetIncome.sh [--start | --delete | --status | --deleteBackup]"
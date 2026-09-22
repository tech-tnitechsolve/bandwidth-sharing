FROM node:20-alpine
WORKDIR /app

# Cài đặt curl, ws, undici và https-proxy-agent chuẩn
RUN apk add --no-cache curl \
    && npm init -y \
    && npm install ws undici https-proxy-agent

# Tải SDK chính thức từ Proxies.sx và copy entrypoint
ADD https://agents.proxies.sx/peer/reference-sdk.js /app/reference-sdk.js
COPY entrypoint.js /app/entrypoint.js

ENV NODE_ENV=production
ENV PEER_STATE_FILE=/state/id.json
ENV AGENT_NAME=docker-peer

CMD ["node", "entrypoint.js"]
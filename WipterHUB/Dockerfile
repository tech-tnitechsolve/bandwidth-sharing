# Stage 1: Lấy binary wipter-tunnel gốc từ image official
FROM ghcr.io/techroy23/docker-wipter:latest AS wipter-source

# Stage 2: Build Go Master Engine
FROM golang:1.22-bookworm AS builder
WORKDIR /app
COPY go.mod ./
COPY main.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o wipter-engine main.go

# Stage 3: Runtime Debian-Slim chuẩn Glibc
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates procps net-tools && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=wipter-source /opt/Wipter/resources/wipter-tunnel/wipter-tunnel_0.1.0_linux/wipter-tunnel /usr/local/bin/wipter-tunnel
RUN chmod +x /usr/local/bin/wipter-tunnel
COPY --from=builder /app/wipter-engine /app/wipter-engine
ENV GOGC=25

ENTRYPOINT ["/app/wipter-engine"]
# ── Stage 1: Build ─────────────────────────────────────────
FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /build

# Зависимости отдельным слоем (кеш)
COPY go.mod go.sum ./
RUN go mod download

# Исходники
COPY . .

# Собрать бинарник (статическая линковка, stripped)
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w -extldflags=-static" \
    -trimpath \
    -o /build/darkvision-backend .

# ── Stage 2: Runtime ────────────────────────────────────────
FROM scratch

# Сертификаты и часовые пояса из builder
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

# Бинарник
COPY --from=builder /build/darkvision-backend /darkvision-backend

# Не запускаем от root
USER 1000:1000

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
    CMD ["/darkvision-backend", "-health"] || exit 1

ENTRYPOINT ["/darkvision-backend"]

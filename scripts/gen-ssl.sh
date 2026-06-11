#!/bin/bash
# Генерация self-signed SSL сертификата для DarkVision
set -e

DOMAIN="${1:-localhost}"
OUT_DIR="${2:-./nginx/ssl}"

mkdir -p "$OUT_DIR"

echo "→ Генерация SSL для: $DOMAIN"

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout "${OUT_DIR}/privkey.pem" \
    -out    "${OUT_DIR}/fullchain.pem" \
    -subj   "/CN=${DOMAIN}/O=DarkVision/C=RU" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN},IP:127.0.0.1" 2>/dev/null

echo "✓ Сертификат: ${OUT_DIR}/fullchain.pem"
echo "✓ Ключ:       ${OUT_DIR}/privkey.pem"
echo "✓ Срок:       10 лет"

#!/bin/bash
# ╔══════════════════════════════════════════════════════════╗
# ║           DarkVision VPN Panel Installer                 ║
# ║  bash <(curl -Ls https://raw.githubusercontent.com/      ║
# ║         d3adwatch3r/darkvision/main/install.sh)          ║
# ╚══════════════════════════════════════════════════════════╝

SCRIPT_VERSION="1.1.0"
PANEL_DIR="/opt/darkvision"
SCRIPT_DIR="/usr/local/darkvision"
BIN_LINK="/usr/local/bin/darkvision"
LOGFILE="${SCRIPT_DIR}/install.log"
REPO_URL="https://raw.githubusercontent.com/d3adwatch3r/darkvision/main"
SCRIPT_URL="${REPO_URL}/install.sh"

# ── Цвета ────────────────────────────────────────────────
R="\033[0m"; G="\033[1;32m"; Y="\033[1;33m"
W="\033[1;37m"; RED="\033[1;31m"; C="\033[1;36m"; GR="\033[0;90m"

info()    { echo -e "${G}[✓]${R} ${W}$*${R}"; }
warn()    { echo -e "${Y}[!]${R} ${Y}$*${R}"; }
error()   { echo -e "${RED}[✗]${R} ${RED}$*${R}"; exit 1; }
step()    { echo -e "${C}[→]${R} ${W}$*${R}"; }
hr()      { echo -e "${GR}──────────────────────────────────────────────────${R}"; }
reading() { read -rp "$(echo -e "${G}[?]${R} ${Y}$1${R} ")" "$2"; }

banner() {
    clear
    echo -e "${C}"
    echo "  ██████╗  █████╗ ██████╗ ██╗  ██╗    ██╗   ██╗██╗███████╗"
    echo "  ██╔══██╗██╔══██╗██╔══██╗██║ ██╔╝    ██║   ██║██║██╔════╝"
    echo "  ██║  ██║███████║██████╔╝█████╔╝     ██║   ██║██║███████╗"
    echo "  ██║  ██║██╔══██║██╔══██╗██╔═██╗     ╚██╗ ██╔╝██║╚════██║"
    echo "  ██████╔╝██║  ██║██║  ██║██║  ██╗     ╚████╔╝ ██║███████║"
    echo "  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝     ╚═══╝  ╚═╝╚══════╝"
    echo -e "${R}"
    echo -e "          ${W}VPN Panel${R} ${GR}v${SCRIPT_VERSION}${R}  —  ${GR}github.com/d3adwatch3r/darkvision${R}"
    hr
}

spinner() {
    local pid=$1 msg="${2:-Подождите...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${C}${frames[$i]}${R}  ${W}%s${R}   " "$msg"
        i=$(( (i+1) % 10 )); sleep 0.1
    done
    printf "\r${G}✓${R}  ${W}%s${R}   \n" "$msg"
}

# ── Проверки ─────────────────────────────────────────────
check_root() { [[ $EUID -ne 0 ]] && error "Нужен root: sudo bash install.sh"; }
check_os() {
    grep -qE "bullseye|bookworm|jammy|noble|focal|trixie" /etc/os-release 2>/dev/null || \
        error "Поддерживается: Ubuntu 20/22/24, Debian 11/12/13"
}

# ── Зависимости ──────────────────────────────────────────
install_deps() {
    step "Обновление пакетов..."
    apt-get update -qq &>/dev/null
    apt-get install -y -qq curl wget git openssl ufw ca-certificates \
        gnupg lsb-release jq socat cron &>/dev/null &
    spinner $! "Установка зависимостей..."
}

install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker уже установлен"; return
    fi
    step "Установка Docker..."
    curl -fsSL https://get.docker.com | sh &>/dev/null &
    spinner $! "Docker Engine..."
    systemctl enable --now docker &>/dev/null
    info "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
}

# ── Системные настройки ───────────────────────────────────
setup_bbr() {
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && \
        { info "BBR уже активен"; return; }
    step "Включение BBR..."
    cat >> /etc/sysctl.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.core.somaxconn=32768
EOF
    sysctl -p &>/dev/null
    info "BBR активирован"
}

disable_ipv6() {
    cat >> /etc/sysctl.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
    sysctl -p &>/dev/null
    info "IPv6 отключён"
}

setup_ufw() {
    local panel_port="${1:-9443}" vpn_port="${2:-2053}"
    step "Настройка UFW..."
    ufw --force reset &>/dev/null
    ufw default deny incoming &>/dev/null
    ufw default allow outgoing &>/dev/null
    local ssh_port; ssh_port=$(ss -tnlp | grep sshd | awk '{print $4}' | cut -d: -f2 | head -1)
    ufw allow "${ssh_port:-22}/tcp"    comment "SSH"              &>/dev/null
    ufw allow "${panel_port}/tcp"      comment "DarkVision Panel" &>/dev/null
    ufw allow "${vpn_port}/tcp"        comment "DarkVision VPN"   &>/dev/null
    ufw allow "${vpn_port}/udp"        comment "DarkVision VPN"   &>/dev/null
    ufw allow "80/tcp"                 comment "ACME/HTTP"        &>/dev/null
    ufw --force enable &>/dev/null
    info "UFW: SSH(${ssh_port:-22}), Panel(${panel_port}), VPN(${vpn_port})"
}

# ── Генераторы ────────────────────────────────────────────
gen_password() { tr -dc 'A-Za-z0-9@#%^&*_+=' < /dev/urandom | head -c "${1:-32}"; }
gen_jwt()      { openssl rand -base64 64 | tr -d '\n/+=' | head -c 80; }

# ╔══════════════════════════════════════════════════════════╗
# ║           SSL — ПРОВЕРКА И ПОЛУЧЕНИЕ СЕРТИФИКАТА        ║
# ╚══════════════════════════════════════════════════════════╝

# Проверить — есть ли рабочий SSL у домена
check_ssl_cert() {
    local domain="$1"
    local result
    result=$(echo | openssl s_client -connect "${domain}:443" \
        -servername "$domain" 2>/dev/null | \
        openssl x509 -noout -dates 2>/dev/null)

    if [[ -z "$result" ]]; then
        return 1   # нет сертификата
    fi

    # Проверить срок действия
    local expiry
    expiry=$(echo "$result" | grep "notAfter" | cut -d= -f2)
    local expiry_epoch; expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null)
    local now_epoch; now_epoch=$(date +%s)

    if [[ $expiry_epoch -gt $now_epoch ]]; then
        return 0   # сертификат есть и действующий
    fi
    return 1       # истёк
}

# Получить Let's Encrypt сертификат через acme.sh (standalone)
get_acme_cert() {
    local domain="$1" email="$2"
    local ssl_dir="${PANEL_DIR}/nginx/ssl"
    mkdir -p "$ssl_dir"

    step "Установка acme.sh..."
    if [[ ! -f ~/.acme.sh/acme.sh ]]; then
        curl -fsSL https://get.acme.sh | sh -s email="$email" &>/dev/null &
        spinner $! "Установка acme.sh..."
    fi

    # Использовать ~/.acme.sh/acme.sh
    local acme="$HOME/.acme.sh/acme.sh"
    [[ ! -f "$acme" ]] && { warn "acme.sh не установился"; return 1; }

    step "Получение сертификата для ${domain}..."

    # Если порт 80 занят другим nginx — временно остановим только если нужно
    local port80_busy=false
    ss -tlnp | grep -q ':80 ' && port80_busy=true

    if $port80_busy; then
        # Попробовать webroot если уже есть nginx
        warn "Порт 80 занят, пробую через webroot..."
        mkdir -p /var/www/acme
        # Добавить temporary location в nginx если он запущен
        $acme --issue -d "$domain" \
            --webroot /var/www/acme \
            --server letsencrypt \
            --force 2>&1 | tail -5
    else
        $acme --issue -d "$domain" \
            --standalone \
            --server letsencrypt \
            --force 2>&1 | tail -5
    fi

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        warn "Не удалось получить сертификат автоматически"
        return 1
    fi

    # Установить сертификат
    $acme --install-cert -d "$domain" \
        --key-file   "${ssl_dir}/privkey.pem" \
        --fullchain-file "${ssl_dir}/fullchain.pem" \
        --reloadcmd  "docker compose -f ${PANEL_DIR}/docker-compose.yml restart nginx 2>/dev/null" \
        2>/dev/null

    # Автопродление через cron
    (crontab -l 2>/dev/null | grep -v acme; \
     echo "0 3 * * * $acme --cron --home ~/.acme.sh > /dev/null 2>&1") | crontab -

    info "Сертификат получен и настроено автопродление (каждые 60 дней)"
    return 0
}

# Сгенерировать self-signed
make_selfsigned() {
    local domain="$1"
    local ssl_dir="${PANEL_DIR}/nginx/ssl"
    mkdir -p "$ssl_dir"
    step "Генерация self-signed SSL..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${ssl_dir}/privkey.pem" \
        -out    "${ssl_dir}/fullchain.pem" \
        -subj   "/CN=${domain}/O=DarkVision/C=RU" \
        -addext "subjectAltName=DNS:${domain},IP:127.0.0.1" 2>/dev/null
    info "Self-signed SSL создан (10 лет)"
}

# Главная функция настройки SSL — проверяет → спрашивает → получает
setup_ssl_auto() {
    local domain="$1"
    local ssl_dir="${PANEL_DIR}/nginx/ssl"

    echo ""
    step "Проверка SSL сертификата для ${C}${domain}${R}..."

    if check_ssl_cert "$domain"; then
        info "SSL сертификат для ${domain} уже существует и действителен"
        echo ""
        echo -e "  Использовать существующий? Или перевыпустить?"
        echo -e "  ${G}1.${R} Использовать существующий"
        echo -e "  ${G}2.${R} Получить новый через Let's Encrypt"
        echo -e "  ${G}3.${R} Self-signed (без домена)"
        reading "Выбор [1]:" ssl_choice
        ssl_choice="${ssl_choice:-1}"
    else
        warn "SSL сертификат не найден или истёк"
        echo ""
        echo -e "  Как получить сертификат?"
        echo -e "  ${G}1.${R} Let's Encrypt (автоматически через acme.sh) ${G}← рекомендуется${R}"
        echo -e "  ${G}2.${R} Self-signed (для тестов, браузер будет ругаться)"
        echo -e "  ${G}3.${R} Пропустить (настрою сам позже)"
        reading "Выбор [1]:" ssl_choice
        ssl_choice="${ssl_choice:-1}"
    fi

    case "$ssl_choice" in
        1)
            # Проверить что файлы уже есть (существующий)
            if [[ -f "${ssl_dir}/fullchain.pem" ]]; then
                info "Используем существующий сертификат"
            else
                # Значит выбрали Let's Encrypt при отсутствующем серте
                reading "Email для Let's Encrypt (для уведомлений):" LE_EMAIL
                LE_EMAIL="${LE_EMAIL:-admin@${domain}}"
                if ! get_acme_cert "$domain" "$LE_EMAIL"; then
                    warn "Автоматическое получение не удалось. Создаю self-signed..."
                    make_selfsigned "$domain"
                fi
            fi
            ;;
        2)
            reading "Email для Let's Encrypt:" LE_EMAIL
            LE_EMAIL="${LE_EMAIL:-admin@${domain}}"
            if ! get_acme_cert "$domain" "$LE_EMAIL"; then
                warn "Не удалось получить Let's Encrypt. Создаю self-signed..."
                make_selfsigned "$domain"
            fi
            ;;
        3)
            make_selfsigned "$domain"
            ;;
        *)
            warn "SSL пропущен — панель будет работать на HTTP"
            ;;
    esac
}

# ── Генерация конфигов ────────────────────────────────────
create_env() {
    local domain="$1" panel_port="$2" vpn_port="$3" sub_domain="$4"

    local db_pass; db_pass=$(gen_password 32)
    local jwt_secret; jwt_secret=$(gen_jwt)
    local redis_pass; redis_pass=$(gen_password 24)
    local tg_secret; tg_secret=$(openssl rand -hex 16)

    # Формат подписки: https://SUB_DOMAIN/TOKEN (без /sub/)
    local sub_base_url="https://${sub_domain}"

    cat > "${PANEL_DIR}/.env" << EOF
# Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')

POSTGRES_HOST=darkvision-postgres
POSTGRES_PORT=5432
POSTGRES_DB=darkvision
POSTGRES_USER=darkvision
POSTGRES_PASSWORD=${db_pass}

REDIS_HOST=darkvision-redis
REDIS_PORT=6379
REDIS_PASSWORD=${redis_pass}

JWT_SECRET=${jwt_secret}
JWT_ACCESS_TTL=15m
JWT_REFRESH_TTL=168h

APP_ENV=production
APP_PORT=8080
LOG_LEVEL=info
ALLOWED_ORIGINS=https://${domain}

XRAY_CONFIG_PATH=/xray-config/config.json
XRAY_API_HOST=darkvision-xray
XRAY_API_PORT=10085

PANEL_PORT=${panel_port}
PANEL_HTTP_PORT=9080
PANEL_DOMAIN=${domain}

# Ссылки подписок: https://${sub_domain}/TOKEN
SUB_BASE_URL=${sub_base_url}

VLESS_PORT=${vpn_port}

TELEGRAM_BOT_TOKEN=
TELEGRAM_WEBHOOK_SECRET=${tg_secret}

RATE_LIMIT_MAX=100
RATE_LIMIT_WINDOW=60

ADMIN_SETUP_DONE=false
EOF
    chmod 600 "${PANEL_DIR}/.env"
    info ".env создан"
}

create_xray_config() {
    step "Генерация Xray Reality ключей..."
    mkdir -p "${PANEL_DIR}/xray/config"

    local xray_keys; xray_keys=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null)
    local privkey; privkey=$(echo "$xray_keys" | grep "Private" | awk '{print $3}')
    local pubkey;  pubkey=$(echo  "$xray_keys" | grep "Public"  | awk '{print $3}')
    local shortid; shortid=$(openssl rand -hex 4)

    cat > "${PANEL_DIR}/xray/reality_keys.txt" << EOF
REALITY_PRIVATE_KEY=${privkey}
REALITY_PUBLIC_KEY=${pubkey}
REALITY_SHORT_ID=${shortid}
EOF
    chmod 600 "${PANEL_DIR}/xray/reality_keys.txt"

    cat > "${PANEL_DIR}/xray/config/config.json" << EOF
{
  "log": { "loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "api": { "tag": "api", "services": ["HandlerService","StatsService","LoggerService"] },
  "stats": {},
  "policy": {
    "levels": { "0": { "handshake": 4, "connIdle": 300, "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true, "statsOutboundUplink": true, "statsOutboundDownlink": true }
  },
  "inbounds": [
    { "tag": "api", "listen": "0.0.0.0", "port": 10085, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" } },
    {
      "tag": "vless-reality", "listen": "0.0.0.0", "port": 443, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none" },
      "streamSettings": {
        "network": "tcp", "security": "reality",
        "realitySettings": {
          "show": false, "dest": "microsoft.com:443", "xver": 0,
          "serverNames": ["microsoft.com","www.microsoft.com"],
          "privateKey": "${privkey}", "shortIds": ["${shortid}"]
        },
        "tcpSettings": { "header": { "type": "none" } }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls","quic"] }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [ { "type": "field", "inboundTag": ["api"], "outboundTag": "api" } ]
  }
}
EOF

    info "Xray конфиг создан"
    info "Public Key: ${C}${pubkey}${R}"
    info "Short ID:   ${C}${shortid}${R}"
}

create_nginx_config() {
    local panel_domain="$1" panel_port="$2" sub_domain="$3"
    mkdir -p "${PANEL_DIR}/nginx/conf.d" "${PANEL_DIR}/nginx/ssl"

    cat > "${PANEL_DIR}/nginx/Dockerfile" << 'EOF'
FROM nginx:1.27-alpine
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 80 443
CMD ["nginx", "-g", "daemon off;"]
EOF

    cat > "${PANEL_DIR}/nginx/nginx.conf" << 'EOF'
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;
events { worker_connections 4096; multi_accept on; use epoll; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    sendfile on; tcp_nopush on; tcp_nodelay on; keepalive_timeout 65;
    gzip on; gzip_vary on; gzip_types text/plain text/css application/json application/javascript;
    limit_req_zone $binary_remote_addr zone=api:10m   rate=30r/m;
    limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;
    log_format main '$remote_addr [$time_local] "$request" $status $body_bytes_sent rt=$request_time';
    access_log /var/log/nginx/access.log main;
    include /etc/nginx/conf.d/*.conf;
}
EOF

    # Виртуальный хост панели
    cat > "${PANEL_DIR}/nginx/conf.d/panel.conf" << EOF
server {
    listen 80;
    server_name ${panel_domain} ${sub_domain};
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://\$host\$request_uri; }
}

# ── Панель управления ─────────────────────────────────────
server {
    listen 443 ssl; http2 on;
    server_name ${panel_domain};
    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;

    location /sub/ {
        proxy_pass http://darkvision-backend:8080/sub/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        proxy_pass http://darkvision-backend:8080/api/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
    }
    location /api/v1/auth/login {
        limit_req zone=login burst=5 nodelay;
        proxy_pass http://darkvision-backend:8080/api/v1/auth/login;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location /health { proxy_pass http://darkvision-backend:8080/health; access_log off; }
    location / {
        proxy_pass http://darkvision-frontend:3000/;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

# ── CDN домен подписок ────────────────────────────────────
# Ссылки вида: https://${sub_domain}/TOKEN
server {
    listen 443 ssl; http2 on;
    server_name ${sub_domain};
    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    # Убрать лишние заголовки чтобы не деанонимизировать подписки
    server_tokens off;
    add_header X-Robots-Tag "noindex, nofollow" always;

    # /TOKEN → /sub/TOKEN на backend
    location ~* ^/([a-f0-9]{32})\$ {
        proxy_pass http://darkvision-backend:8080/sub/\$1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # Поддержка query string (?format=clash)
        proxy_pass_request_args on;
    }

    # Всё остальное — 404 (не светить панель)
    location / { return 404; }
}
EOF

    info "Nginx конфиг создан"
}

# ── Запуск стека ──────────────────────────────────────────
start_stack() {
    cd "${PANEL_DIR}" || error "Нет папки ${PANEL_DIR}"
    step "Скачиваю образы..."
    docker compose pull &>/dev/null &
    spinner $! "Docker pull..."
    step "Запуск контейнеров..."
    docker compose up -d --remove-orphans &>/dev/null &
    spinner $! "Старт DarkVision..."
    sleep 8

    echo ""
    echo -e "${W}Статус контейнеров:${R}"
    docker compose ps --format "  {{.Name}}\t{{.Status}}" 2>/dev/null | \
        awk '{printf "  %-35s %s\n", $1, $2}'

    # Итоговая проверка
    local ok=0
    for svc in postgres redis xray backend; do
        docker compose ps --status running 2>/dev/null | grep -q "darkvision-${svc}" && ((ok++))
    done
    echo ""
    if [[ $ok -ge 4 ]]; then
        info "Все основные сервисы запущены"
    else
        warn "Некоторые сервисы не запустились. Проверь: ${Y}dv logs${R}"
    fi
}

# ── Создание первого администратора ──────────────────────
create_first_admin() {
    echo ""
    echo -e "${C}━━━  Создание администратора  ━━━${R}"
    echo ""
    reading "Имя администратора (мин. 3 символа):" ADMIN_USER
    while [[ ${#ADMIN_USER} -lt 3 ]]; do
        warn "Минимум 3 символа"
        reading "Имя администратора:" ADMIN_USER
    done

    local gen_pass
    reading "Сгенерировать пароль автоматически? [Y/n]:" gen_pass
    if [[ "$gen_pass" =~ ^[Nn]$ ]]; then
        reading "Пароль (мин. 8 символов):" ADMIN_PASS
        while [[ ${#ADMIN_PASS} -lt 8 ]]; do
            warn "Минимум 8 символов"
            reading "Пароль:" ADMIN_PASS
        done
    else
        ADMIN_PASS=$(gen_password 20)
        info "Пароль: ${G}${ADMIN_PASS}${R}"
        echo ""
        warn "Сохрани пароль сейчас!"
        reading "Нажми Enter когда сохранишь..." _
    fi

    step "Ожидание API..."
    local retries=0
    until curl -sf "http://localhost:8080/health" &>/dev/null || [[ $retries -ge 30 ]]; do
        sleep 2; ((retries++))
        printf "\r  ${GR}Попытка %d/30...${R}" "$retries"
    done
    echo ""

    if [[ $retries -ge 30 ]]; then
        warn "Backend не ответил. Создай admin вручную:"
        warn "  curl -X POST https://ДОМЕН/api/v1/auth/setup \\"
        warn "    -H 'Content-Type: application/json' \\"
        warn "    -d '{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}'"
        return
    fi

    local resp
    resp=$(curl -sf -X POST "http://localhost:8080/api/v1/auth/setup" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" 2>&1)

    echo "$resp" | grep -q "access_token" && info "Администратор создан" || \
        warn "Ответ: $resp"
}

# ── Установка команды darkvision ─────────────────────────
install_script_command() {
    mkdir -p "${SCRIPT_DIR}"
    cp "$0" "${SCRIPT_DIR}/darkvision"
    chmod +x "${SCRIPT_DIR}/darkvision"
    ln -sf "${SCRIPT_DIR}/darkvision" "${BIN_LINK}"
    local bashrc="/etc/bash.bashrc"
    grep -q "alias dv='darkvision'" "$bashrc" 2>/dev/null || \
        echo "alias dv='darkvision'" >> "$bashrc"
    info "Команды: ${G}darkvision${R} и ${G}dv${R}"
}

# ── Самообновление ────────────────────────────────────────
self_update() {
    step "Проверка обновлений..."
    local remote_ver
    remote_ver=$(curl -fsSL "${SCRIPT_URL}" 2>/dev/null | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2)
    [[ -z "$remote_ver" ]] && { warn "Нет связи с репозиторием"; return; }
    [[ "$remote_ver" == "$SCRIPT_VERSION" ]] && { info "Актуальная версия: v${SCRIPT_VERSION}"; return; }

    echo -e "${Y}Доступно обновление:${R} ${G}v${remote_ver}${R} ${GR}(текущая: v${SCRIPT_VERSION})${R}"
    reading "Обновить? [Y/n]:" c
    [[ "$c" =~ ^[Nn]$ ]] && return
    curl -fsSL "${SCRIPT_URL}" -o "${SCRIPT_DIR}/darkvision.new" 2>/dev/null
    grep -q "SCRIPT_VERSION" "${SCRIPT_DIR}/darkvision.new" 2>/dev/null && {
        mv "${SCRIPT_DIR}/darkvision.new" "${SCRIPT_DIR}/darkvision"
        chmod +x "${SCRIPT_DIR}/darkvision"
        ln -sf "${SCRIPT_DIR}/darkvision" "${BIN_LINK}"
        info "Обновлено до v${remote_ver}. Перезапусти: darkvision"
        exit 0
    } || { warn "Ошибка скачивания"; rm -f "${SCRIPT_DIR}/darkvision.new"; }
}

# ── Управление панелью ────────────────────────────────────
panel_status() {
    echo ""; echo -e "${C}━━━  Статус DarkVision  ━━━${R}"; echo ""
    cd "${PANEL_DIR}" 2>/dev/null || { warn "Панель не установлена"; return; }
    docker compose ps --format "  {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null
    echo ""
    local domain; domain=$(grep PANEL_DOMAIN "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2)
    local port;   port=$(grep PANEL_PORT "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2)
    local sub;    sub=$(grep SUB_BASE_URL "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2)
    info "Панель:    ${C}https://${domain}${R}"
    info "Подписки:  ${C}${sub}/TOKEN${R}"
}

panel_logs() {
    cd "${PANEL_DIR}" 2>/dev/null || { warn "Панель не установлена"; return; }
    echo -e "${Y}Контейнер:${R} 1)backend 2)xray 3)nginx 4)postgres 5)redis 0)все"
    reading "Выбор:" c
    case $c in
        1) docker compose logs -f --tail=100 backend ;;
        2) docker compose logs -f --tail=100 xray ;;
        3) docker compose logs -f --tail=100 nginx ;;
        4) docker compose logs -f --tail=100 postgres ;;
        5) docker compose logs -f --tail=100 redis ;;
        *) docker compose logs -f --tail=50 ;;
    esac
}

restart_service() {
    cd "${PANEL_DIR}" 2>/dev/null || return
    echo ""
    echo -e "  ${G}1.${R} Всё  ${G}2.${R} Backend  ${G}3.${R} Frontend  ${G}4.${R} Nginx"
    echo -e "  ${G}5.${R} Xray ${Y}(соединения не рвутся!)${R}  ${G}6.${R} PostgreSQL  ${G}7.${R} Redis"
    reading "Выбор:" c
    case $c in
        1) docker compose restart & spinner $! "Перезапуск всего..." ;;
        2) docker compose restart backend & spinner $! "Backend..." ;;
        3) docker compose restart frontend & spinner $! "Frontend..." ;;
        4) docker compose restart nginx & spinner $! "Nginx..." ;;
        5) docker compose restart xray & spinner $! "Xray (горячий)..."
           info "Существующие VPN соединения не затронуты" ;;
        6) docker compose restart postgres & spinner $! "PostgreSQL..." ;;
        7) docker compose restart redis & spinner $! "Redis..." ;;
    esac
}

backup_db() {
    cd "${PANEL_DIR}" 2>/dev/null || return
    mkdir -p "${PANEL_DIR}/backups"
    local f="darkvision_$(date +%Y%m%d_%H%M%S).sql.gz"
    step "Создание дампа..."
    docker compose exec -T postgres pg_dump -U darkvision darkvision 2>/dev/null | \
        gzip > "${PANEL_DIR}/backups/${f}"
    [[ -s "${PANEL_DIR}/backups/${f}" ]] && \
        info "Дамп: ${G}${PANEL_DIR}/backups/${f}${R} ($(du -sh "${PANEL_DIR}/backups/${f}" | cut -f1))" || \
        warn "Ошибка создания дампа"
}

show_reality_keys() {
    local f="${PANEL_DIR}/xray/reality_keys.txt"
    [[ -f "$f" ]] && { echo ""; echo -e "${C}━━━  Reality Keys  ━━━${R}"; echo ""; cat "$f"; echo ""; } || \
        warn "Ключи не найдены: $f"
    reading "Enter..." _
}

configure_telegram() {
    echo ""; echo -e "${C}━━━  Telegram Bot  ━━━${R}"; echo ""
    reading "Токен бота (от @BotFather):" token
    [[ -z "$token" ]] && return
    sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=${token}|" "${PANEL_DIR}/.env"

    local domain; domain=$(grep PANEL_DOMAIN "${PANEL_DIR}/.env" | cut -d= -f2)
    local wsecret; wsecret=$(grep TELEGRAM_WEBHOOK_SECRET "${PANEL_DIR}/.env" | cut -d= -f2)

    echo ""; info "Токен сохранён"
    local resp; resp=$(curl -sf -X POST \
        "https://api.telegram.org/bot${token}/setWebhook" \
        -H "Content-Type: application/json" \
        -d "{\"url\":\"https://${domain}/api/v1/telegram/webhook\",\"secret_token\":\"${wsecret}\"}")
    echo "$resp" | grep -q '"ok":true' && info "Webhook зарегистрирован" || warn "Ответ: $resp"

    cd "${PANEL_DIR}" && docker compose restart backend & spinner $! "Перезапуск backend..."
    reading "Enter..." _
}

uninstall_panel() {
    echo ""; echo -e "${RED}━━━  УДАЛЕНИЕ  ━━━${R}"; echo ""
    echo -e "  ${G}1.${R} Только скрипт  ${G}2.${R} Контейнеры (данные остаются)  ${G}3.${R} ${RED}Всё полностью${R}  ${G}0.${R} Отмена"
    reading "Выбор:" c
    case $c in
        1) rm -f "${BIN_LINK}" "${SCRIPT_DIR}/darkvision"
           sed -i "/alias dv='darkvision'/d" /etc/bash.bashrc 2>/dev/null
           info "Скрипт удалён"; exit 0 ;;
        2) reading "Подтвердить? (yes/no):" ok
           [[ "$ok" != "yes" ]] && return
           cd "${PANEL_DIR}" && docker compose down --remove-orphans
           info "Контейнеры остановлены, данные сохранены" ;;
        3) reading "Напиши DELETE для подтверждения:" ok
           [[ "$ok" != "DELETE" ]] && return
           cd "${PANEL_DIR}" && docker compose down -v --remove-orphans --rmi all &>/dev/null &
           spinner $! "Удаление..."
           rm -rf "${PANEL_DIR}" "${SCRIPT_DIR}" "${BIN_LINK}"
           sed -i "/alias dv='darkvision'/d" /etc/bash.bashrc 2>/dev/null
           info "DarkVision удалён полностью"; exit 0 ;;
    esac
}

# ╔══════════════════════════════════════════════════════════╗
# ║                   ПОЛНАЯ УСТАНОВКА                      ║
# ╚══════════════════════════════════════════════════════════╝
full_install() {
    banner
    echo -e "${C}━━━  Полная установка DarkVision  ━━━${R}"; echo ""
    check_root; check_os

    # ── Параметры ─────────────────────────────────────────
    reading "Домен панели (напр. panel.example.com):" PANEL_DOMAIN
    [[ -z "$PANEL_DOMAIN" ]] && error "Домен обязателен"

    echo ""
    reading "CDN домен для подписок (напр. cdn.wedarkvpn.org или тот же домен):" SUB_DOMAIN
    SUB_DOMAIN="${SUB_DOMAIN:-$PANEL_DOMAIN}"

    echo ""
    reading "Порт панели (по умолчанию 9443):" PANEL_PORT
    PANEL_PORT="${PANEL_PORT:-9443}"

    reading "Порт VPN/Xray (по умолчанию 2053, не конфликтует с RemnaWave):" VPN_PORT
    VPN_PORT="${VPN_PORT:-2053}"

    # ── Подтверждение ─────────────────────────────────────
    echo ""
    echo -e "${C}Параметры:${R}"
    echo -e "  Панель:     ${W}https://${PANEL_DOMAIN}${R}"
    echo -e "  Подписки:   ${W}https://${SUB_DOMAIN}/TOKEN${R}"
    echo -e "  Порт панели:${W} ${PANEL_PORT}${R}"
    echo -e "  Порт VPN:   ${W} ${VPN_PORT}${R}"
    echo ""
    reading "Начать? [Y/n]:" go
    [[ "$go" =~ ^[Nn]$ ]] && return

    echo ""
    step "=== 1/8: Зависимости ==="
    install_deps; install_docker

    step "=== 2/8: Оптимизация системы ==="
    setup_bbr; disable_ipv6; setup_ufw "$PANEL_PORT" "$VPN_PORT"

    step "=== 3/8: Файлы проекта ==="
    mkdir -p "${PANEL_DIR}"
    # Скачать docker-compose.yml из репозитория
    curl -fsSL "${REPO_URL}/docker-compose.yml" -o "${PANEL_DIR}/docker-compose.yml" 2>/dev/null || \
        warn "Не удалось скачать docker-compose.yml — скопируй вручную"

    step "=== 4/8: Конфигурация ==="
    create_env "$PANEL_DOMAIN" "$PANEL_PORT" "$VPN_PORT" "$SUB_DOMAIN"
    create_nginx_config "$PANEL_DOMAIN" "$PANEL_PORT" "$SUB_DOMAIN"

    step "=== 5/8: Xray Reality ключи ==="
    create_xray_config

    step "=== 6/8: SSL сертификат ==="
    setup_ssl_auto "$PANEL_DOMAIN"

    step "=== 7/8: Запуск ==="
    start_stack

    step "=== 8/8: Администратор ==="
    create_first_admin

    install_script_command

    # ── Итог ──────────────────────────────────────────────
    echo ""; hr
    echo -e "${C}      ✦  DarkVision установлен!  ✦${R}"
    hr; echo ""
    echo -e "  ${W}Панель:${R}        ${C}https://${PANEL_DOMAIN}${R}"
    echo -e "  ${W}Подписки:${R}      ${C}https://${SUB_DOMAIN}/TOKEN${R}"
    echo -e "  ${W}Reality PubKey:${R} ${GR}cat ${PANEL_DIR}/xray/reality_keys.txt${R}"
    echo -e "  ${W}Команда:${R}       ${G}darkvision${R}  или  ${G}dv${R}"
    echo ""; hr; echo ""
    reading "Нажми Enter для возврата в меню..." _
    main_menu
}

# ── Изменить домен подписок ───────────────────────────────
# Каждый пользователь имеет уникальный sub_token (32 hex символа).
# SUB_BASE_URL определяет только домен — итоговый URL: ${SUB_BASE_URL}/${user.sub_token}
# Пример: https://cdn.wedarkvpn.org/a3f9b2c1d4e5f6789012345678901234
change_sub_domain() {
    echo ""; echo -e "${C}━━━  Домен подписок  ━━━${R}"; echo ""

    local current; current=$(grep SUB_BASE_URL "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2)
    info "Текущий: ${W}${current}${R}"
    echo ""
    echo -e "  Формат ссылок: ${C}\${SUB_BASE_URL}/\${user_token}${R}"
    echo -e "  Пример: ${GR}https://cdn.wedarkvpn.org/a3f9b2c1...${R}"
    echo -e "  ${Y}Каждый пользователь имеет свой уникальный токен${R}"
    echo ""
    reading "Новый домен (с https://, напр. https://cdn.wedarkvpn.org):" new_domain
    [[ -z "$new_domain" ]] && { warn "Не изменено"; return; }

    # Убрать trailing slash
    new_domain="${new_domain%/}"

    # Обновить .env
    sed -i "s|^SUB_BASE_URL=.*|SUB_BASE_URL=${new_domain}|" "${PANEL_DIR}/.env"

    # Извлечь hostname для nginx
    local hostname; hostname=$(echo "$new_domain" | sed 's|https://||;s|http://||;s|/.*||')

    # Обновить nginx конфиг — заменить server_name в блоке CDN
    local nginx_conf="${PANEL_DIR}/nginx/conf.d/panel.conf"
    if [[ -f "$nginx_conf" ]]; then
        # Обновить строку server_name в блоке CDN подписок
        # Блок CDN — второй server{} блок с server_name
        python3 - << PYEOF 2>/dev/null || \
        sed -i "0,/server_name.*;/{n; s/server_name .*/server_name ${hostname};/}" "$nginx_conf"
import re, sys

with open('${nginx_conf}', 'r') as f:
    content = f.read()

# Заменить server_name в блоке CDN (второй блок 443)
# Ищем комментарий "CDN домен подписок"
pattern = r'(# ── CDN домен подписок.*?\n.*?server_name\s+)([^\s;]+)(;)'
replacement = r'\g<1>${hostname}\g<3>'
new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

with open('${nginx_conf}', 'w') as f:
    f.write(new_content)

print('nginx conf updated')
PYEOF

        cd "${PANEL_DIR}" && docker compose restart nginx & spinner $! "Применение nginx конфига..."
    fi

    info "Домен подписок изменён: ${G}${new_domain}${R}"
    info "Ссылки теперь: ${C}${new_domain}/\${уникальный_токен_пользователя}${R}"
    reading "Enter..." _
}


main_menu() {
    while true; do
        banner
        if [[ -f "${PANEL_DIR}/.env" ]]; then
            local domain; domain=$(grep PANEL_DOMAIN "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2)
            local sub; sub=$(grep SUB_BASE_URL "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2)
            local running; running=$(docker compose -f "${PANEL_DIR}/docker-compose.yml" ps --status running 2>/dev/null | grep -c "running" || echo "0")
            echo -e "  ${GR}Панель:${R}    ${C}https://${domain}${R}"
            echo -e "  ${GR}Подписки:${R}  ${C}${sub}/TOKEN${R}"
            echo -e "  ${GR}Запущено:${R}  ${G}${running} контейнеров${R}"
        else
            echo -e "  ${Y}● Панель не установлена${R}"
        fi
        echo ""
        echo -e "  ${W}─── Установка ─────────────────────${R}"
        echo -e "  ${G}1.${R}  Полная установка"
        echo ""
        echo -e "  ${W}─── Управление ────────────────────${R}"
        echo -e "  ${G}2.${R}  Статус"
        echo -e "  ${G}3.${R}  Логи"
        echo -e "  ${G}4.${R}  Перезапустить сервис"
        echo -e "  ${G}5.${R}  Резервная копия БД"
        echo ""
        echo -e "  ${W}─── Конфигурация ──────────────────${R}"
        echo -e "  ${G}6.${R}  Обновить SSL сертификат"
        echo -e "  ${G}7.${R}  Reality ключи"
        echo -e "  ${G}8.${R}  Telegram бот"
        echo -e "  ${G}11.${R} Изменить домен подписок"
        echo ""
        echo -e "  ${W}─── Прочее ────────────────────────${R}"
        echo -e "  ${G}9.${R}  Обновить скрипт"
        echo -e "  ${G}10.${R} Удалить DarkVision"
        echo -e "  ${G}0.${R}  Выход"
        echo ""; hr
        reading "Выбор:" CHOICE
        case $CHOICE in
            1)  full_install ;;
            2)  panel_status; reading "Enter..." _ ;;
            3)  panel_logs ;;
            4)  restart_service ;;
            5)  backup_db; reading "Enter..." _ ;;
            6)  local d; d=$(grep PANEL_DOMAIN "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2)
                setup_ssl_auto "$d"
                cd "${PANEL_DIR}" && docker compose restart nginx & spinner $! "Nginx..." ;;
            7)  show_reality_keys ;;
            8)  configure_telegram ;;
            11) change_sub_domain ;;
            9)  self_update ;;
            10) uninstall_panel ;;
            0)  echo -e "\n${G}До свидания!${R}\n"; exit 0 ;;
        esac
    done
}

main() {
    mkdir -p "${SCRIPT_DIR}"
    exec > >(tee -a "${LOGFILE}") 2>&1
    case "${1:-}" in
        install)   check_root; full_install ;;
        status)    panel_status ;;
        logs)      panel_logs ;;
        restart)   restart_service ;;
        backup)    backup_db ;;
        update)    self_update ;;
        uninstall) uninstall_panel ;;
        *)         main_menu ;;
    esac
}

main "$@"

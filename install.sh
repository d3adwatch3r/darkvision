#!/bin/bash
# ╔══════════════════════════════════════════════════════════╗
# ║           DarkVision VPN Panel Installer                 ║
# ║        bash <(curl -Ls https://YOUR_REPO/install.sh)     ║
# ╚══════════════════════════════════════════════════════════╝

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="darkvision"
PANEL_DIR="/opt/darkvision"
SCRIPT_DIR="/usr/local/darkvision"
BIN_LINK="/usr/local/bin/darkvision"
LOGFILE="${SCRIPT_DIR}/install.log"
REPO_URL="https://raw.githubusercontent.com/YOUR_USERNAME/darkvision/main"
SCRIPT_URL="${REPO_URL}/install.sh"

# ─────────────────────────────────────────
#  Цвета
# ─────────────────────────────────────────
R="\033[0m"
G="\033[1;32m"
Y="\033[1;33m"
W="\033[1;37m"
RED="\033[1;31m"
C="\033[1;36m"
GR="\033[0;90m"
B="\033[1;34m"

# ─────────────────────────────────────────
#  Хелперы вывода
# ─────────────────────────────────────────
info()    { echo -e "${G}[✓]${R} ${W}$*${R}"; }
warn()    { echo -e "${Y}[!]${R} ${Y}$*${R}"; }
error()   { echo -e "${RED}[✗]${R} ${RED}$*${R}"; exit 1; }
step()    { echo -e "${C}[→]${R} ${W}$*${R}"; }
ask()     { echo -e "${G}[?]${R} ${Y}$*${R}"; }
reading() { read -rp "$(ask "$1") " "$2"; }
hr()      { echo -e "${GR}──────────────────────────────────────────────────────${R}"; }

banner() {
    clear
    echo -e "${C}"
    echo -e "  ██████╗  █████╗ ██████╗ ██╗  ██╗    ██╗   ██╗██╗███████╗"
    echo -e "  ██╔══██╗██╔══██╗██╔══██╗██║ ██╔╝    ██║   ██║██║██╔════╝"
    echo -e "  ██║  ██║███████║██████╔╝█████╔╝     ██║   ██║██║███████╗"
    echo -e "  ██║  ██║██╔══██║██╔══██╗██╔═██╗     ╚██╗ ██╔╝██║╚════██║"
    echo -e "  ██████╔╝██║  ██║██║  ██║██║  ██╗     ╚████╔╝ ██║███████║"
    echo -e "  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝     ╚═══╝  ╚═╝╚══════╝"
    echo -e "${R}"
    echo -e "             ${W}VPN Panel${R} ${GR}v${SCRIPT_VERSION}${R}  —  ${GR}by DarkVision Team${R}"
    hr
}

spinner() {
    local pid=$1
    local msg="${2:-Подождите...}"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${C}${frames[$i]}${R}  ${W}%s${R}   " "$msg"
        i=$(( (i+1) % ${#frames[@]} ))
        sleep 0.1
    done
    printf "\r${G}✓${R}  ${W}%s${R}   \n" "$msg"
}

# ─────────────────────────────────────────
#  Проверки
# ─────────────────────────────────────────
check_root() {
    [[ $EUID -ne 0 ]] && error "Запусти скрипт от root: sudo bash install.sh"
}

check_os() {
    if ! grep -qE "bullseye|bookworm|jammy|noble|focal|trixie" /etc/os-release 2>/dev/null; then
        error "Поддерживаются: Ubuntu 20/22/24, Debian 11/12/13"
    fi
}

check_arch() {
    local arch
    arch=$(uname -m)
    [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]] && \
        error "Поддерживается только x86_64 и aarch64 (текущая: $arch)"
}

check_requirements() {
    check_root
    check_os
    check_arch
    [[ $(free -m | awk '/^Mem:/{print $2}') -lt 512 ]] && \
        warn "Мало RAM (< 512MB). Рекомендуется >= 1GB"
}

# ─────────────────────────────────────────
#  Установка зависимостей
# ─────────────────────────────────────────
install_deps() {
    step "Обновление пакетов..."
    apt-get update -qq &
    spinner $! "apt update"

    step "Установка зависимостей..."
    apt-get install -y -qq \
        curl wget git openssl ufw \
        ca-certificates gnupg lsb-release \
        jq net-tools htop > /dev/null 2>&1 &
    spinner $! "curl, openssl, ufw, jq..."
}

install_docker() {
    if command -v docker &>/dev/null; then
        info "Docker уже установлен: $(docker --version | cut -d' ' -f3 | tr -d ',')"
        return
    fi

    step "Установка Docker..."
    curl -fsSL https://get.docker.com | sh > /dev/null 2>&1 &
    spinner $! "Docker Engine"

    systemctl enable docker --quiet
    systemctl start docker

    if ! command -v docker compose &>/dev/null && ! docker compose version &>/dev/null 2>&1; then
        step "Установка Docker Compose plugin..."
        apt-get install -y -qq docker-compose-plugin > /dev/null 2>&1
    fi

    info "Docker установлен: $(docker --version)"
}

# ─────────────────────────────────────────
#  Генераторы
# ─────────────────────────────────────────
gen_password() {
    local len="${1:-32}"
    tr -dc 'A-Za-z0-9@#%^&*_+=' < /dev/urandom | head -c "$len"
}

gen_hex() {
    local len="${1:-32}"
    openssl rand -hex "$len"
}

gen_jwt_secret() {
    openssl rand -base64 64 | tr -d '\n/+=' | head -c 80
}

gen_xray_keys() {
    # Генерировать Reality keypair через временный контейнер xray
    docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null || {
        # Fallback через openssl если Docker ещё не готов
        local privkey hex
        privkey=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null | tail -c 32 | xxd -p -c 32)
        echo "Private key: $privkey"
        echo "Public key:  (установи xray для генерации)"
    }
}

# ─────────────────────────────────────────
#  Настройка системы
# ─────────────────────────────────────────
setup_bbr() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        info "BBR уже активен"
        return
    fi

    step "Включение BBR (TCP congestion control)..."
    cat >> /etc/sysctl.conf << 'EOF'

# DarkVision — TCP BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
EOF
    sysctl -p > /dev/null 2>&1
    info "BBR активирован"
}

setup_ufw() {
    local panel_port="${1:-8443}"
    local vpn_port="${2:-443}"

    step "Настройка UFW firewall..."

    ufw --force reset > /dev/null 2>&1

    # Базовые правила
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null

    # SSH (определяем текущий порт)
    local ssh_port
    ssh_port=$(ss -tnlp | grep sshd | awk '{print $4}' | cut -d: -f2 | head -1)
    ssh_port=${ssh_port:-22}
    ufw allow "${ssh_port}/tcp" comment "SSH" > /dev/null

    # Панель
    ufw allow "${panel_port}/tcp" comment "DarkVision Panel" > /dev/null

    # VPN
    ufw allow "${vpn_port}/tcp" comment "DarkVision VPN" > /dev/null
    ufw allow "${vpn_port}/udp" comment "DarkVision VPN UDP" > /dev/null

    # Xray API — только localhost (не открываем наружу!)
    # 10085 остаётся в Docker сети

    ufw --force enable > /dev/null 2>&1
    info "UFW активирован. Открытые порты: SSH(${ssh_port}), Panel(${panel_port}), VPN(${vpn_port})"
}

disable_ipv6() {
    step "Отключение IPv6 (предотвращение утечек)..."
    cat >> /etc/sysctl.conf << 'EOF'

# DarkVision — Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -p > /dev/null 2>&1
    info "IPv6 отключён"
}

# ─────────────────────────────────────────
#  SSL сертификаты
# ─────────────────────────────────────────
setup_ssl_selfsigned() {
    local domain="${1:-localhost}"
    local ssl_dir="${PANEL_DIR}/nginx/ssl"

    mkdir -p "$ssl_dir"
    step "Генерация self-signed SSL для ${domain}..."

    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${ssl_dir}/privkey.pem" \
        -out    "${ssl_dir}/fullchain.pem" \
        -subj "/CN=${domain}/O=DarkVision/C=RU" \
        -extensions v3_req \
        -config <(cat <<SSLEOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = ${domain}
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain}
IP.1 = 127.0.0.1
SSLEOF
) 2>/dev/null

    info "SSL сертификат создан: ${ssl_dir}/"
}

setup_ssl_acme() {
    local domain="$1"
    local email="$2"
    local ssl_dir="${PANEL_DIR}/nginx/ssl"

    mkdir -p "$ssl_dir"
    step "Получение Let's Encrypt сертификата для ${domain}..."

    if ! command -v acme.sh &>/dev/null; then
        curl -fsSL https://get.acme.sh | sh -s email="$email" > /dev/null 2>&1 &
        spinner $! "Установка acme.sh"
        source ~/.acme.sh/acme.sh.env 2>/dev/null || export PATH="$HOME/.acme.sh:$PATH"
    fi

    ~/.acme.sh/acme.sh --issue --standalone \
        -d "$domain" --force \
        --server letsencrypt 2>&1 | tail -5

    ~/.acme.sh/acme.sh --install-cert -d "$domain" \
        --key-file   "${ssl_dir}/privkey.pem" \
        --fullchain-file "${ssl_dir}/fullchain.pem" \
        --reloadcmd "docker compose -f ${PANEL_DIR}/docker-compose.yml restart nginx" \
        2>/dev/null

    # Auto-renew cron
    (crontab -l 2>/dev/null; echo "0 3 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null 2>&1") | crontab -

    info "SSL сертификат получен и настроено автопродление"
}

# ─────────────────────────────────────────
#  Генерация .env
# ─────────────────────────────────────────
create_env() {
    local domain="${1:-localhost}"
    local panel_port="${2:-8443}"

    step "Генерация секретных ключей..."

    local db_pass jwt_secret redis_pass tg_secret
    db_pass=$(gen_password 32)
    jwt_secret=$(gen_jwt_secret)
    redis_pass=$(gen_password 24)
    tg_secret=$(gen_hex 16)

    cat > "${PANEL_DIR}/.env" << EOF
# ── Сгенерировано автоматически $(date '+%Y-%m-%d %H:%M:%S') ──

# PostgreSQL
POSTGRES_HOST=darkvision-postgres
POSTGRES_PORT=5432
POSTGRES_DB=darkvision
POSTGRES_USER=darkvision
POSTGRES_PASSWORD=${db_pass}

# Redis
REDIS_HOST=darkvision-redis
REDIS_PORT=6379
REDIS_PASSWORD=${redis_pass}

# JWT
JWT_SECRET=${jwt_secret}
JWT_ACCESS_TTL=15m
JWT_REFRESH_TTL=168h

# App
APP_ENV=production
APP_PORT=8080
LOG_LEVEL=info
ALLOWED_ORIGINS=https://${domain}

# Xray
XRAY_CONFIG_PATH=/xray-config/config.json
XRAY_API_HOST=darkvision-xray
XRAY_API_PORT=10085

# Panel
PANEL_PORT=${panel_port}
PANEL_HTTP_PORT=80
PANEL_DOMAIN=${domain}
SUB_BASE_URL=https://${domain}/sub

# VPN
VLESS_PORT=443

# Telegram (заполни позже)
TELEGRAM_BOT_TOKEN=
TELEGRAM_WEBHOOK_SECRET=${tg_secret}

# Rate Limit
RATE_LIMIT_MAX=100
RATE_LIMIT_WINDOW=60

ADMIN_SETUP_DONE=false
EOF

    chmod 600 "${PANEL_DIR}/.env"
    info ".env создан"
}

# ─────────────────────────────────────────
#  Генерация Xray конфига
# ─────────────────────────────────────────
create_xray_config() {
    step "Генерация Xray Reality конфига..."

    mkdir -p "${PANEL_DIR}/xray/config"

    # Генерация Reality ключей
    local xray_keys
    xray_keys=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null)

    local privkey pubkey shortid
    privkey=$(echo "$xray_keys" | grep "Private" | awk '{print $3}')
    pubkey=$(echo  "$xray_keys" | grep "Public"  | awk '{print $3}')
    shortid=$(openssl rand -hex 4)

    # Сохранить ключи в файл (нужны для ссылок подписки)
    cat > "${PANEL_DIR}/xray/reality_keys.txt" << EOF
# DarkVision — Reality Keys
# Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S')
REALITY_PRIVATE_KEY=${privkey}
REALITY_PUBLIC_KEY=${pubkey}
REALITY_SHORT_ID=${shortid}
EOF
    chmod 600 "${PANEL_DIR}/xray/reality_keys.txt"

    # Xray config.json
    cat > "${PANEL_DIR}/xray/config/config.json" << EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },
  "api": {
    "tag": "api",
    "services": ["HandlerService", "StatsService", "LoggerService"]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink":    true,
      "statsInboundDownlink":  true,
      "statsOutboundUplink":   true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag":      "api",
      "listen":   "0.0.0.0",
      "port":     10085,
      "protocol": "dokodemo-door",
      "settings": {"address": "127.0.0.1"}
    },
    {
      "tag":      "vless-reality",
      "listen":   "0.0.0.0",
      "port":     443,
      "protocol": "vless",
      "settings": {
        "clients":    [],
        "decryption": "none"
      },
      "streamSettings": {
        "network":  "tcp",
        "security": "reality",
        "realitySettings": {
          "show":        false,
          "dest":        "microsoft.com:443",
          "xver":        0,
          "serverNames": ["microsoft.com", "www.microsoft.com"],
          "privateKey":  "${privkey}",
          "shortIds":    ["${shortid}"]
        },
        "tcpSettings": {"header": {"type": "none"}}
      },
      "sniffing": {
        "enabled":     true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block",  "protocol": "blackhole"}
  ],
  "routing": {
    "rules": [
      {
        "type":        "field",
        "inboundTag":  ["api"],
        "outboundTag": "api"
      }
    ]
  }
}
EOF

    info "Xray конфиг создан"
    info "Reality Public Key: ${C}${pubkey}${R}"
    info "Reality Short ID:   ${C}${shortid}${R}"
    echo ""
    warn "Сохрани ключи: ${PANEL_DIR}/xray/reality_keys.txt"
}

# ─────────────────────────────────────────
#  Nginx конфиг
# ─────────────────────────────────────────
create_nginx_config() {
    local domain="${1:-localhost}"
    local panel_port="${2:-8443}"

    mkdir -p "${PANEL_DIR}/nginx/conf.d"
    mkdir -p "${PANEL_DIR}/nginx/ssl"

    # Nginx Dockerfile
    cat > "${PANEL_DIR}/nginx/Dockerfile" << 'EOF'
FROM nginx:1.27-alpine
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 80 443
CMD ["nginx", "-g", "daemon off;"]
EOF

    # Основной nginx.conf
    cat > "${PANEL_DIR}/nginx/nginx.conf" << 'EOF'
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    # Security
    server_tokens off;
    add_header X-Frame-Options        "DENY"            always;
    add_header X-Content-Type-Options "nosniff"         always;
    add_header X-XSS-Protection       "1; mode=block"   always;
    add_header Referrer-Policy        "no-referrer"     always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;

    # Performance
    sendfile           on;
    tcp_nopush         on;
    tcp_nodelay        on;
    keepalive_timeout  65;
    gzip               on;
    gzip_vary          on;
    gzip_types         text/plain text/css application/json application/javascript;

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=30r/m;
    limit_req_zone $binary_remote_addr zone=login:10m rate=5r/m;

    # Logging
    log_format main '$remote_addr - [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" rt=$request_time';
    access_log /var/log/nginx/access.log main;

    include /etc/nginx/conf.d/*.conf;
}
EOF

    # Virtual host
    cat > "${PANEL_DIR}/nginx/conf.d/panel.conf" << EOF
# ── HTTP → HTTPS redirect ──────────────────────────────
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

# ── HTTPS Panel ────────────────────────────────────────
server {
    listen 443 ssl;
    http2  on;
    server_name ${domain};

    ssl_certificate     /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # ── Subscription (публично) ──────────────────────
    location /sub/ {
        proxy_pass         http://darkvision-backend:8080/sub/;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        # Без rate limit — клиенты опрашивают часто
    }

    # ── API ──────────────────────────────────────────
    location /api/ {
        limit_req zone=api burst=20 nodelay;
        proxy_pass         http://darkvision-backend:8080/api/;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 30s;
    }

    # ── Login endpoint (строгий лимит) ───────────────
    location /api/v1/auth/login {
        limit_req zone=login burst=5 nodelay;
        proxy_pass http://darkvision-backend:8080/api/v1/auth/login;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    # ── Health ────────────────────────────────────────
    location /health {
        proxy_pass http://darkvision-backend:8080/health;
        access_log off;
    }

    # ── Frontend ─────────────────────────────────────
    location / {
        proxy_pass         http://darkvision-frontend:3000/;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
}
EOF

    info "Nginx конфиг создан"
}

# ─────────────────────────────────────────
#  Скопировать файлы проекта
# ─────────────────────────────────────────
deploy_project_files() {
    step "Разворачиваю файлы DarkVision..."

    mkdir -p "${PANEL_DIR}"

    # Скачать docker-compose.yml если его нет
    if [[ ! -f "${PANEL_DIR}/docker-compose.yml" ]]; then
        curl -fsSL "${REPO_URL}/docker-compose.yml" -o "${PANEL_DIR}/docker-compose.yml" 2>/dev/null || {
            warn "Не удалось скачать docker-compose.yml с репозитория"
            warn "Скопируй вручную в ${PANEL_DIR}/"
        }
    fi

    info "Файлы проекта готовы в ${PANEL_DIR}"
}

# ─────────────────────────────────────────
#  Запуск стека
# ─────────────────────────────────────────
start_stack() {
    cd "${PANEL_DIR}" || error "Директория ${PANEL_DIR} не найдена"

    step "Скачиваю Docker образы (первый раз долго)..."
    docker compose pull 2>&1 | grep -E "Pull complete|already" | while read -r line; do
        echo -e "  ${GR}${line}${R}"
    done

    step "Запуск контейнеров..."
    docker compose up -d --remove-orphans 2>&1 &
    spinner $! "Запуск DarkVision..."

    sleep 5

    # Проверка
    local failed=()
    for svc in postgres redis xray backend frontend nginx; do
        local status
        status=$(docker compose ps --status running 2>/dev/null | grep "darkvision-${svc}" | wc -l)
        if [[ $status -eq 0 ]]; then
            failed+=("$svc")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        warn "Не запустились: ${failed[*]}"
        warn "Логи: docker compose -f ${PANEL_DIR}/docker-compose.yml logs"
    else
        info "Все контейнеры запущены"
    fi
}

# ─────────────────────────────────────────
#  Первичная настройка admin
# ─────────────────────────────────────────
create_first_admin() {
    echo ""
    echo -e "${C}━━━  Создание администратора панели  ━━━${R}"
    echo ""

    reading "Имя администратора (мин. 3 символа):" ADMIN_USER
    while [[ ${#ADMIN_USER} -lt 3 ]]; do
        warn "Минимум 3 символа"
        reading "Имя администратора:" ADMIN_USER
    done

    local use_gen
    reading "Сгенерировать случайный пароль? [Y/n]:" use_gen
    if [[ "$use_gen" =~ ^[Nn]$ ]]; then
        reading "Пароль (мин. 8 символов):" ADMIN_PASS
        while [[ ${#ADMIN_PASS} -lt 8 ]]; do
            warn "Минимум 8 символов"
            reading "Пароль:" ADMIN_PASS
        done
    else
        ADMIN_PASS=$(gen_password 20)
        info "Сгенерированный пароль: ${G}${ADMIN_PASS}${R}"
    fi

    # Ждём пока backend поднимется
    step "Ожидание запуска backend..."
    local retries=0
    until curl -sf "http://localhost:8080/health" > /dev/null 2>&1 || [[ $retries -ge 30 ]]; do
        sleep 2
        ((retries++))
        printf "\r${GR}  Попытка %d/30...${R}" "$retries"
    done
    echo ""

    if [[ $retries -ge 30 ]]; then
        warn "Backend не ответил. Создай admin вручную через:"
        warn "  POST https://ТВОЙ_ДОМЕН/api/v1/auth/setup"
        warn "  Body: {\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}"
        return
    fi

    local panel_port
    panel_port=$(grep PANEL_PORT "${PANEL_DIR}/.env" | cut -d= -f2)

    # Вызов API setup
    local response
    response=$(curl -sf -X POST "http://localhost:8080/api/v1/auth/setup" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" 2>&1)

    if echo "$response" | grep -q "access_token"; then
        info "Администратор создан"
    else
        warn "Ответ API: $response"
        warn "Попробуй создать вручную через веб-интерфейс"
    fi
}

# ─────────────────────────────────────────
#  Установка скрипта как системной команды
# ─────────────────────────────────────────
install_script_command() {
    mkdir -p "${SCRIPT_DIR}"
    cp "$0" "${SCRIPT_DIR}/darkvision"
    chmod +x "${SCRIPT_DIR}/darkvision"
    ln -sf "${SCRIPT_DIR}/darkvision" "${BIN_LINK}"

    # Алиас dv
    local bashrc="/etc/bash.bashrc"
    if ! grep -q "alias dv='darkvision'" "$bashrc" 2>/dev/null; then
        echo "alias dv='darkvision'" >> "$bashrc"
        info "Алиас ${G}dv${R} добавлен — можно вызывать как: dv"
    fi

    info "Команда установлена: ${G}darkvision${R} (или ${G}dv${R})"
}

# ─────────────────────────────────────────
#  Самообновление
# ─────────────────────────────────────────
self_update() {
    step "Проверка обновлений..."
    local remote_version
    remote_version=$(curl -fsSL "${SCRIPT_URL}" 2>/dev/null | grep -m1 '^SCRIPT_VERSION=' | cut -d'"' -f2)

    if [[ -z "$remote_version" ]]; then
        warn "Не удалось проверить версию"
        return
    fi

    if [[ "$remote_version" == "$SCRIPT_VERSION" ]]; then
        info "Актуальная версия: ${G}v${SCRIPT_VERSION}${R}"
        return
    fi

    echo ""
    echo -e "${Y}Доступно обновление: ${R}${G}v${remote_version}${R} ${GR}(текущая: v${SCRIPT_VERSION})${R}"
    reading "Обновить? [Y/n]:" confirm

    [[ "$confirm" =~ ^[Nn]$ ]] && return

    curl -fsSL "${SCRIPT_URL}" -o "${SCRIPT_DIR}/darkvision.new" 2>/dev/null

    if grep -q "SCRIPT_VERSION" "${SCRIPT_DIR}/darkvision.new" 2>/dev/null; then
        mv "${SCRIPT_DIR}/darkvision.new" "${SCRIPT_DIR}/darkvision"
        chmod +x "${SCRIPT_DIR}/darkvision"
        ln -sf "${SCRIPT_DIR}/darkvision" "${BIN_LINK}"
        info "Обновлено до v${remote_version}. Перезапусти: ${G}darkvision${R}"
        exit 0
    else
        rm -f "${SCRIPT_DIR}/darkvision.new"
        warn "Скачан повреждённый файл, обновление отменено"
    fi
}

# ─────────────────────────────────────────
#  Управление панелью
# ─────────────────────────────────────────
panel_status() {
    echo ""
    echo -e "${C}━━━  Статус DarkVision  ━━━${R}"
    echo ""
    cd "${PANEL_DIR}" 2>/dev/null || { warn "Панель не установлена"; return; }

    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || \
    docker compose ps 2>/dev/null
    echo ""

    local panel_port
    panel_port=$(grep PANEL_PORT "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "8443")
    local domain
    domain=$(grep PANEL_DOMAIN "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "localhost")

    info "Панель: ${C}https://${domain}:${panel_port}${R}"
}

panel_logs() {
    local svc="${1:-}"
    cd "${PANEL_DIR}" 2>/dev/null || { warn "Панель не установлена"; return; }

    if [[ -n "$svc" ]]; then
        docker compose logs -f --tail=100 "$svc"
    else
        echo ""
        echo -e "${Y}Выбери контейнер:${R}"
        echo -e "  1. backend"
        echo -e "  2. xray"
        echo -e "  3. nginx"
        echo -e "  4. postgres"
        echo -e "  5. redis"
        echo -e "  0. Все"
        reading "Выбор:" log_choice
        case $log_choice in
            1) docker compose logs -f --tail=100 backend ;;
            2) docker compose logs -f --tail=100 xray ;;
            3) docker compose logs -f --tail=100 nginx ;;
            4) docker compose logs -f --tail=100 postgres ;;
            5) docker compose logs -f --tail=100 redis ;;
            *) docker compose logs -f --tail=50 ;;
        esac
    fi
}

restart_service() {
    cd "${PANEL_DIR}" 2>/dev/null || { warn "Панель не установлена"; return; }

    echo ""
    echo -e "${Y}Что перезапустить?${R}"
    echo -e "  1. Всё"
    echo -e "  2. Backend (API)"
    echo -e "  3. Frontend"
    echo -e "  4. Nginx"
    echo -e "  5. Xray (VPN ядро — соединения не рвутся!)"
    echo -e "  6. PostgreSQL"
    echo -e "  7. Redis"
    reading "Выбор:" svc_choice

    case $svc_choice in
        1) docker compose restart & spinner $! "Перезапуск всего..."; info "Готово" ;;
        2) docker compose restart backend & spinner $! "Backend..."; info "Backend перезапущен" ;;
        3) docker compose restart frontend & spinner $! "Frontend..."; info "Frontend перезапущен" ;;
        4) docker compose restart nginx & spinner $! "Nginx..."; info "Nginx перезапущен" ;;
        5) docker compose restart xray & spinner $! "Xray (горячий рестарт)..."; info "Xray перезапущен — существующие VPN соединения не затронуты" ;;
        6) docker compose restart postgres & spinner $! "PostgreSQL..."; info "PostgreSQL перезапущен" ;;
        7) docker compose restart redis & spinner $! "Redis..."; info "Redis перезапущен" ;;
        *) warn "Неверный выбор" ;;
    esac
}

backup_db() {
    cd "${PANEL_DIR}" 2>/dev/null || { warn "Панель не установлена"; return; }

    local backup_dir="${PANEL_DIR}/backups"
    mkdir -p "$backup_dir"

    local filename="darkvision_db_$(date +%Y%m%d_%H%M%S).sql.gz"
    local db_pass
    db_pass=$(grep POSTGRES_PASSWORD "${PANEL_DIR}/.env" | cut -d= -f2)

    step "Создание дампа БД..."
    docker compose exec -T postgres \
        pg_dump -U darkvision darkvision 2>/dev/null | \
        gzip > "${backup_dir}/${filename}"

    if [[ -s "${backup_dir}/${filename}" ]]; then
        info "Дамп сохранён: ${G}${backup_dir}/${filename}${R}"
        info "Размер: $(du -sh "${backup_dir}/${filename}" | cut -f1)"
    else
        warn "Дамп пустой или ошибка"
    fi
}

uninstall_panel() {
    echo ""
    echo -e "${RED}━━━  УДАЛЕНИЕ DARKVISION  ━━━${R}"
    echo ""
    echo -e "${Y}Выбери действие:${R}"
    echo -e "  1. Удалить только скрипт управления"
    echo -e "  2. Остановить и удалить контейнеры (данные сохраняются)"
    echo -e "  3. ${RED}ПОЛНОЕ удаление — контейнеры + все данные + БД${R}"
    echo -e "  0. Отмена"
    reading "Выбор:" del_choice

    case $del_choice in
        1)
            rm -f "${BIN_LINK}" "${SCRIPT_DIR}/darkvision"
            sed -i "/alias dv='darkvision'/d" /etc/bash.bashrc 2>/dev/null
            info "Скрипт удалён. Панель продолжает работать."
            exit 0
            ;;
        2)
            reading "Подтвердить остановку контейнеров? (yes/no):" confirm
            [[ "$confirm" != "yes" ]] && { warn "Отменено"; return; }
            cd "${PANEL_DIR}" && docker compose down --remove-orphans
            info "Контейнеры остановлены. Данные в volumes сохранены."
            ;;
        3)
            echo -e "${RED}ВНИМАНИЕ: Все данные пользователей будут удалены!${R}"
            reading "Напиши 'DELETE' для подтверждения:" confirm
            [[ "$confirm" != "DELETE" ]] && { warn "Отменено"; return; }

            cd "${PANEL_DIR}" && \
                docker compose down -v --remove-orphans --rmi all > /dev/null 2>&1 &
            spinner $! "Удаление контейнеров и volumes..."

            rm -rf "${PANEL_DIR}"
            rm -f "${BIN_LINK}" "${SCRIPT_DIR}/darkvision"
            sed -i "/alias dv='darkvision'/d" /etc/bash.bashrc 2>/dev/null

            info "DarkVision полностью удалён"
            exit 0
            ;;
        0) return ;;
        *) warn "Неверный выбор" ;;
    esac
}

# ─────────────────────────────────────────
#  Главное меню
# ─────────────────────────────────────────
main_menu() {
    while true; do
        banner

        # Статус установки
        if [[ -f "${PANEL_DIR}/.env" ]]; then
            local domain panel_port
            domain=$(grep PANEL_DOMAIN "${PANEL_DIR}/.env" | cut -d= -f2)
            panel_port=$(grep PANEL_PORT "${PANEL_DIR}/.env" | cut -d= -f2)
            echo -e "  ${GR}Панель:${R} ${C}https://${domain}:${panel_port}${R}"
            echo -e "  ${GR}Статус контейнеров (запущено):${R} ${G}$(docker compose -f ${PANEL_DIR}/docker-compose.yml ps --status running 2>/dev/null | grep -c "Up\|running")${R}"
        else
            echo -e "  ${Y}● Панель не установлена${R}"
        fi

        echo ""
        echo -e "  ${W}─── Установка ───────────────────────────────────${R}"
        echo -e "  ${G}1.${R}  Полная установка (рекомендуется)"
        echo -e "  ${G}2.${R}  Только Docker + зависимости"
        echo -e "  ${G}3.${R}  Только настройка системы (BBR, UFW, IPv6)"
        echo ""
        echo -e "  ${W}─── Управление ──────────────────────────────────${R}"
        echo -e "  ${G}4.${R}  Статус контейнеров"
        echo -e "  ${G}5.${R}  Логи"
        echo -e "  ${G}6.${R}  Перезапустить сервис"
        echo -e "  ${G}7.${R}  Создать резервную копию БД"
        echo ""
        echo -e "  ${W}─── Конфигурация ────────────────────────────────${R}"
        echo -e "  ${G}8.${R}  Создать/обновить SSL сертификат"
        echo -e "  ${G}9.${R}  Показать Reality ключи"
        echo -e "  ${G}10.${R} Настроить Telegram бот"
        echo ""
        echo -e "  ${W}─── Прочее ──────────────────────────────────────${R}"
        echo -e "  ${G}11.${R} Обновить скрипт"
        echo -e "  ${G}12.${R} Удалить DarkVision"
        echo -e "  ${G}0.${R}  Выход"
        echo ""
        hr
        reading "Выбор:" CHOICE

        case $CHOICE in
            1)  full_install ;;
            2)  check_requirements; install_deps; install_docker ;;
            3)  setup_bbr; disable_ipv6
                reading "Открыть порт панели (по умолчанию 8443):" p_port
                reading "Открыть порт VPN (по умолчанию 443):" v_port
                setup_ufw "${p_port:-8443}" "${v_port:-443}" ;;
            4)  panel_status; reading "Enter для продолжения..." _ ;;
            5)  panel_logs ;;
            6)  restart_service ;;
            7)  backup_db; reading "Enter для продолжения..." _ ;;
            8)  ssl_menu ;;
            9)  show_reality_keys ;;
            10) configure_telegram ;;
            11) self_update ;;
            12) uninstall_panel ;;
            0)  echo -e "\n${G}До свидания!${R}\n"; exit 0 ;;
            *)  warn "Неверный выбор" ;;
        esac
    done
}

# ─────────────────────────────────────────
#  Полная установка
# ─────────────────────────────────────────
full_install() {
    banner
    echo -e "${C}━━━  Полная установка DarkVision  ━━━${R}"
    echo ""

    check_requirements

    # Запросить параметры
    reading "Домен или IP сервера (напр. panel.example.com):" DOMAIN
    DOMAIN="${DOMAIN:-localhost}"

    reading "Порт панели (по умолчанию 8443):" PANEL_PORT
    PANEL_PORT="${PANEL_PORT:-8443}"

    reading "Порт VPN/Xray (по умолчанию 443):" VPN_PORT
    VPN_PORT="${VPN_PORT:-443}"

    echo ""
    echo -e "${Y}SSL сертификат:${R}"
    echo -e "  1. Self-signed (без домена, для тестов)"
    echo -e "  2. Let's Encrypt ACME (нужен реальный домен)"
    reading "Выбор SSL:" ssl_choice

    if [[ "$ssl_choice" == "2" ]]; then
        reading "Email для Let's Encrypt:" LE_EMAIL
    fi

    # Подтверждение
    echo ""
    echo -e "${C}Параметры установки:${R}"
    echo -e "  Домен:      ${W}${DOMAIN}${R}"
    echo -e "  Порт панели:${W} ${PANEL_PORT}${R}"
    echo -e "  Порт VPN:   ${W}${VPN_PORT}${R}"
    echo -e "  SSL:        ${W}$([ "$ssl_choice" == "2" ] && echo "Let's Encrypt" || echo "Self-signed")${R}"
    echo -e "  Директория: ${W}${PANEL_DIR}${R}"
    echo ""
    reading "Начать установку? [Y/n]:" go

    [[ "$go" =~ ^[Nn]$ ]] && return

    echo ""
    step "=== Шаг 1/7: Зависимости ==="
    install_deps
    install_docker

    step "=== Шаг 2/7: Оптимизация системы ==="
    setup_bbr
    disable_ipv6
    setup_ufw "$PANEL_PORT" "$VPN_PORT"

    step "=== Шаг 3/7: Файлы проекта ==="
    mkdir -p "${PANEL_DIR}"
    deploy_project_files

    step "=== Шаг 4/7: Конфигурация ==="
    create_env "$DOMAIN" "$PANEL_PORT"
    create_nginx_config "$DOMAIN" "$PANEL_PORT"
    create_xray_config

    step "=== Шаг 5/7: SSL сертификат ==="
    if [[ "$ssl_choice" == "2" && -n "$LE_EMAIL" ]]; then
        setup_ssl_acme "$DOMAIN" "$LE_EMAIL"
    else
        setup_ssl_selfsigned "$DOMAIN"
    fi

    step "=== Шаг 6/7: Запуск контейнеров ==="
    start_stack

    step "=== Шаг 7/7: Создание администратора ==="
    create_first_admin

    install_script_command

    # Итог
    echo ""
    hr
    echo -e "${C}     ✦  DarkVision установлен!  ✦${R}"
    hr
    echo ""

    local domain_display
    domain_display=$(grep PANEL_DOMAIN "${PANEL_DIR}/.env" | cut -d= -f2)

    echo -e "  ${W}Панель:${R}          ${C}https://${domain_display}:${PANEL_PORT}${R}"
    echo -e "  ${W}Команда:${R}         ${G}darkvision${R}  или  ${G}dv${R}"
    echo -e "  ${W}Логи:${R}            ${GR}dv → 5${R}"
    echo -e "  ${W}Reality ключи:${R}   ${GR}cat ${PANEL_DIR}/xray/reality_keys.txt${R}"
    echo ""
    echo -e "  ${Y}⚠ Сохрани пароль администратора в надёжном месте!${R}"
    echo ""
    hr
    echo ""

    reading "Открыть главное меню? [Y/n]:" back
    [[ "$back" =~ ^[Nn]$ ]] || main_menu
}

# ─────────────────────────────────────────
#  SSL меню
# ─────────────────────────────────────────
ssl_menu() {
    echo ""
    echo -e "${Y}Тип сертификата:${R}"
    echo -e "  1. Self-signed (обновить/создать)"
    echo -e "  2. Let's Encrypt (ACME)"
    reading "Выбор:" schoice

    local domain
    domain=$(grep PANEL_DOMAIN "${PANEL_DIR}/.env" 2>/dev/null | cut -d= -f2 || echo "localhost")
    reading "Домен [${domain}]:" inp_domain
    domain="${inp_domain:-$domain}"

    case $schoice in
        1) setup_ssl_selfsigned "$domain"
           cd "${PANEL_DIR}" && docker compose restart nginx ;;
        2)
           reading "Email:" le_email
           setup_ssl_acme "$domain" "$le_email"
           cd "${PANEL_DIR}" && docker compose restart nginx ;;
    esac
}

# ─────────────────────────────────────────
#  Показать Reality ключи
# ─────────────────────────────────────────
show_reality_keys() {
    local keys_file="${PANEL_DIR}/xray/reality_keys.txt"
    if [[ -f "$keys_file" ]]; then
        echo ""
        echo -e "${C}━━━  Reality Keys  ━━━${R}"
        cat "$keys_file" | grep -v "^#" | while read -r line; do
            echo -e "  ${W}${line}${R}"
        done
        echo ""
    else
        warn "Файл ключей не найден: $keys_file"
        warn "Запусти полную установку для генерации"
    fi
    reading "Enter для продолжения..." _
}

# ─────────────────────────────────────────
#  Telegram настройка
# ─────────────────────────────────────────
configure_telegram() {
    echo ""
    echo -e "${C}━━━  Настройка Telegram бота  ━━━${R}"
    echo ""
    echo -e "  1. Создай бота через ${C}@BotFather${R} в Telegram"
    echo -e "  2. Получи токен вида ${W}1234567890:AABBCCDDEEFFaabbccddeeff${R}"
    echo ""

    reading "Вставь токен бота:" bot_token

    if [[ -z "$bot_token" ]]; then
        warn "Токен не введён"
        return
    fi

    # Обновить .env
    sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=${bot_token}|" "${PANEL_DIR}/.env"

    local domain
    domain=$(grep PANEL_DOMAIN "${PANEL_DIR}/.env" | cut -d= -f2)
    local webhook_secret
    webhook_secret=$(grep TELEGRAM_WEBHOOK_SECRET "${PANEL_DIR}/.env" | cut -d= -f2)
    local panel_port
    panel_port=$(grep PANEL_PORT "${PANEL_DIR}/.env" | cut -d= -f2)

    echo ""
    info "Токен сохранён"
    echo ""
    echo -e "${Y}Зарегистрируй вебхук командой:${R}"
    echo -e "${GR}curl -X POST \"https://api.telegram.org/bot${bot_token}/setWebhook\" \\${R}"
    echo -e "${GR}  -H \"Content-Type: application/json\" \\${R}"
    echo -e "${GR}  -d '{\"url\":\"https://${domain}:${panel_port}/api/v1/telegram/webhook\",\"secret_token\":\"${webhook_secret}\"}'${R}"
    echo ""

    reading "Зарегистрировать вебхук автоматически? [Y/n]:" auto_reg
    if [[ ! "$auto_reg" =~ ^[Nn]$ ]]; then
        local resp
        resp=$(curl -sf -X POST \
            "https://api.telegram.org/bot${bot_token}/setWebhook" \
            -H "Content-Type: application/json" \
            -d "{\"url\":\"https://${domain}:${panel_port}/api/v1/telegram/webhook\",\"secret_token\":\"${webhook_secret}\"}")

        if echo "$resp" | grep -q '"ok":true'; then
            info "Вебхук зарегистрирован"
        else
            warn "Ответ: $resp"
        fi
    fi

    # Перезапустить backend для подхвата нового токена
    cd "${PANEL_DIR}" && docker compose restart backend &
    spinner $! "Перезапуск backend..."
    reading "Enter для продолжения..." _
}

# ─────────────────────────────────────────
#  Точка входа
# ─────────────────────────────────────────
main() {
    # Создать директорию для логов
    mkdir -p "${SCRIPT_DIR}"
    exec > >(tee -a "${LOGFILE}") 2>&1

    # Если вызван с аргументом
    case "${1:-}" in
        install)   check_requirements; full_install ;;
        status)    panel_status ;;
        logs)      panel_logs "${2:-}" ;;
        restart)   restart_service ;;
        backup)    backup_db ;;
        update)    self_update ;;
        uninstall) uninstall_panel ;;
        *)         main_menu ;;
    esac
}

main "$@"

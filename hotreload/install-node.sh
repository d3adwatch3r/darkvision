#!/bin/bash
# ╔══════════════════════════════════════════════════════════╗
# ║      DarkVision Hot-Reload — установка на ноду           ║
# ║                                                          ║
# ║  Финский сервер (панель + нода):                         ║
# ║    bash <(curl -Ls https://raw.githubusercontent.com/    ║
# ║    d3adwatch3r/darkvision/main/hotreload/install-node.sh)║
# ║    --local                                               ║
# ║                                                          ║
# ║  Удалённая нода:                                         ║
# ║    bash <(curl -Ls ...install-node.sh)                   ║
# ╚══════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Цвета ─────────────────────────────────────────────────
R="\033[0m"; G="\033[1;32m"; Y="\033[1;33m"
W="\033[1;37m"; C="\033[1;36m"; RED="\033[1;31m"; GR="\033[0;90m"
info()    { echo -e "${G}[✓]${R} ${W}$*${R}"; }
warn()    { echo -e "${Y}[!]${R} ${Y}$*${R}"; }
error()   { echo -e "${RED}[✗]${R} ${RED}$*${R}"; exit 1; }
step()    { echo -e "${C}[→]${R} ${W}$*${R}"; }
hr()      { echo -e "${GR}──────────────────────────────────────────${R}"; }
reading() { read -rp "$(echo -e "${G}[?]${R} ${Y}$1${R} ")" "$2"; }

# ── Аргументы ─────────────────────────────────────────────
IS_LOCAL=false
[[ "${1:-}" == "--local" ]] && IS_LOCAL=true

INSTALL_DIR="/opt/darkvision-hotreload"

# ── Баннер ────────────────────────────────────────────────
echo ""
echo -e "${C}  ██████╗ ██╗   ██╗"
echo -e "  ██╔══██╗██║   ██║   DarkVision Hot-Reload v1.0"
echo -e "  ██║  ██║╚██╗ ██╔╝   Горячая перезагрузка нод"
echo -e "  ██║  ██║ ╚████╔╝    Без обрыва соединений"
echo -e "  ██████╔╝  ╚██╔╝ "
echo -e "  ╚═════╝    ╚═╝  ${R}"
hr

# ── Проверки ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Нужен root: sudo bash install-node.sh"
command -v docker &>/dev/null || error "Docker не найден. Установи Docker и повтори."

step "Проверка remnanode..."
if ! docker ps --format '{{.Names}}' | grep -q "^remnanode$"; then
    error "Контейнер 'remnanode' не запущен! Сначала установи RemnaWave node."
fi
info "remnanode запущен"

# Определяем порт Xray gRPC из контейнера (обычно 61000)
XRAY_PORT=61000
INTERNAL=$(docker inspect remnanode 2>/dev/null \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)[0]
    env = d.get('Config',{}).get('Env',[])
    for e in env:
        if e.startswith('XRAY_API_PORT=') or e.startswith('INTERNAL_PORT='):
            print(e.split('=',1)[1])
            break
except: pass
" 2>/dev/null || echo "")
[[ -n "$INTERNAL" ]] && XRAY_PORT="$INTERNAL"
info "Xray gRPC порт: ${XRAY_PORT}"

# ── Параметры ─────────────────────────────────────────────
echo ""
reading "Порт sidecar (по умолчанию 2224):" INPUT_PORT
SIDECAR_PORT="${INPUT_PORT:-2224}"

echo ""
echo -e "${C}Параметры:${R}"
echo -e "  Sidecar слушает:  ${W}0.0.0.0:${SIDECAR_PORT}${R}"
echo -e "  Реальная нода:    ${W}127.0.0.1:2222${R}"
echo -e "  Xray gRPC:        ${W}127.0.0.1:${XRAY_PORT}${R}"
echo -e "  Режим:            ${W}$( $IS_LOCAL && echo 'локальный (панель+нода)' || echo 'удалённая нода')${R}"
echo ""
reading "Начать установку? [Y/n]:" GO
[[ "${GO:-Y}" =~ ^[Nn]$ ]] && exit 0

# ── Создать директорию ────────────────────────────────────
step "Создание директории ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/src"

# ── Создать package.json ──────────────────────────────────
cat > "${INSTALL_DIR}/package.json" << 'PKGEOF'
{
  "name": "darkvision-hotreload",
  "version": "1.0.0",
  "description": "Hot-reload sidecar — no connection drops on user changes",
  "main": "src/index.js",
  "scripts": { "start": "node src/index.js" },
  "dependencies": {
    "@mongodb-js/zstd": "^1.2.0",
    "@remnawave/xtls-sdk": "latest",
    "http-proxy": "^1.18.1"
  }
}
PKGEOF

# ── Создать src/index.js (встроен в скрипт) ───────────────
step "Создание sidecar..."
cat > "${INSTALL_DIR}/src/index.js" << 'JSEOF'
/**
 * DarkVision Hot-Reload Sidecar v1.0.0
 *
 * Перехватывает START XRAY команды от RemnaWave панели.
 * Если изменились только пользователи → AlterInbound gRPC (мгновенно, соединения живут).
 * Если изменилась структура inbound → полный рестарт (неизбежно, но редко).
 */
'use strict';

const http      = require('http');
const httpProxy = require('http-proxy');
const crypto    = require('crypto');

const cfg = {
    listenPort:   parseInt(process.env.DV_LISTEN_PORT)    || 2224,
    realNodeHost: process.env.DV_REAL_NODE_HOST           || '127.0.0.1',
    realNodePort: parseInt(process.env.DV_REAL_NODE_PORT) || 2222,
    xrayHost:     process.env.DV_XRAY_GRPC_HOST           || '127.0.0.1',
    xrayPort:     parseInt(process.env.DV_XRAY_GRPC_PORT) || 61000,
    debug:        process.env.DV_DEBUG === 'true',
};

// ── Логгер ───────────────────────────────────────────────
const ts  = () => new Date().toISOString().slice(11, 23);
const log = {
    info:  (...a) => console.log (`[${ts()}] [INFO]  `, ...a),
    warn:  (...a) => console.warn(`[${ts()}] [WARN]  `, ...a),
    error: (...a) => console.error(`[${ts()}] [ERROR] `, ...a),
    debug: (...a) => cfg.debug && console.log(`[${ts()}] [DEBUG] `, ...a),
    hot:   (...a) => console.log (`[${ts()}] [\x1b[32m♻ HOT\x1b[0m]  `, ...a),
    cold:  (...a) => console.log (`[${ts()}] [\x1b[33m↺ COLD\x1b[0m] `, ...a),
};

// ── Xray gRPC через xtls-sdk ─────────────────────────────
let xray = null;

async function initXray() {
    try {
        const { XtlsApiClient } = require('@remnawave/xtls-sdk');
        const client = new XtlsApiClient({ ip: cfg.xrayHost, port: cfg.xrayPort });
        await client.statsService.getSysStats();
        xray = client;
        log.info(`Xray gRPC OK → ${cfg.xrayHost}:${cfg.xrayPort}`);
    } catch (e) {
        log.warn(`Xray gRPC недоступен: ${e.message} — hot reload отключён`);
        xray = null;
    }
}

// ── Диффинг конфигов ─────────────────────────────────────

function structureHash(config) {
    if (!config?.inbounds) return '';
    const s = config.inbounds.map(ib => JSON.stringify({
        tag: ib.tag, protocol: ib.protocol, port: ib.port,
        net: ib.streamSettings?.network,
        sec: ib.streamSettings?.security,
        pbk: ib.streamSettings?.realitySettings?.privateKey,
    })).sort().join('|');
    return crypto.createHash('md5').update(s).digest('hex');
}

function extractUsers(config) {
    const users = new Map();
    if (!config?.inbounds) return users;
    for (const ib of config.inbounds) {
        for (const c of (ib.settings?.clients ?? [])) {
            const email = c.email ?? c.id ?? '';
            users.set(`${ib.tag}::${email}`, { tag: ib.tag, id: c.id, email, flow: c.flow ?? '', level: c.level ?? 0 });
        }
    }
    return users;
}

let lastConfig     = null;
let lastStructHash = null;

async function applyDiff(newConfig) {
    if (!lastConfig) {
        lastConfig = newConfig;
        lastStructHash = structureHash(newConfig);
        log.info('Первый конфиг получен → пропускаем на ноду');
        return 'first';
    }

    const newStructHash = structureHash(newConfig);
    if (newStructHash !== lastStructHash) {
        log.cold('Структура inbound изменилась → полный рестарт (порт/протокол/ключи)');
        lastConfig = newConfig;
        lastStructHash = newStructHash;
        return 'cold';
    }

    const oldUsers = extractUsers(lastConfig);
    const newUsers = extractUsers(newConfig);
    const added    = [...newUsers.values()].filter(u => !oldUsers.has(`${u.tag}::${u.email}`));
    const removed  = [...oldUsers.values()].filter(u => !newUsers.has(`${u.tag}::${u.email}`));

    if (added.length === 0 && removed.length === 0) {
        log.debug('Нет изменений → пропускаем');
        return 'skip';
    }

    log.info(`Изменения пользователей: +${added.length} -${removed.length}`);

    if (!xray) {
        log.warn('Xray gRPC недоступен → холодный рестарт');
        lastConfig = newConfig;
        return 'cold';
    }

    try {
        for (const u of added) {
            await xray.handlerService.addUser(u.tag, { id: u.id, email: u.email, flow: u.flow, level: u.level });
            log.hot(`+ пользователь ${u.email} → [${u.tag}]`);
        }
        for (const u of removed) {
            await xray.handlerService.removeUser(u.tag, u.email);
            log.hot(`- пользователь ${u.email} ← [${u.tag}]`);
        }
        lastConfig = newConfig;
        log.hot(`Применено ${added.length + removed.length} изменений — соединения НЕ прерваны ✓`);
        return 'hot';
    } catch (e) {
        log.error('Ошибка hot reload:', e.message, '→ fallback на холодный рестарт');
        lastConfig = newConfig;
        return 'cold';
    }
}

// ── Парсинг тела запроса с ZSTD ──────────────────────────

async function readBody(req) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        req.on('data', c => chunks.push(c));
        req.on('end',  () => resolve(Buffer.concat(chunks)));
        req.on('error', reject);
    });
}

async function parseXrayConfig(buf) {
    // RemnaWave отправляет конфиг сжатый через ZSTD
    const attempts = [
        async () => { const z = require('@mongodb-js/zstd'); return JSON.parse((await z.decompress(buf)).toString()); },
        async () => { const z = require('@mongodb-js/zstd'); return JSON.parse((await z.decompress(Buffer.from(buf.toString(), 'base64'))).toString()); },
        async () => JSON.parse(buf.toString()),
    ];
    for (const fn of attempts) {
        try { return await fn(); } catch {}
    }
    return null;
}

// ── Форвард на реальную ноду ─────────────────────────────

function forward(req, res, body) {
    const opts = {
        hostname: cfg.realNodeHost, port: cfg.realNodePort,
        path: req.url, method: req.method,
        headers: { ...req.headers, host: `${cfg.realNodeHost}:${cfg.realNodePort}` },
    };
    const pr = http.request(opts, ps => {
        res.writeHead(ps.statusCode, ps.headers);
        ps.pipe(res, { end: true });
    });
    pr.on('error', e => {
        log.error('Ошибка форварда на ноду:', e.message);
        if (!res.headersSent) { res.writeHead(502); res.end('node unreachable'); }
    });
    if (body?.length) pr.write(body);
    pr.end();
}

// ── HTTP сервер ──────────────────────────────────────────

const server = http.createServer(async (req, res) => {
    log.debug(`${req.method} ${req.url}`);

    // Health check
    if (req.url === '/dv-health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ status: 'ok', xrayConnected: !!xray, hasConfig: !!lastConfig }));
        return;
    }

    const body = await readBody(req);

    // Перехватываем START XRAY (RemnaWave отправляет POST с конфигом)
    const isStartXray = req.method === 'POST' &&
        (req.url?.toLowerCase().includes('start') ||
         req.headers['x-command']?.toLowerCase() === 'start_xray' ||
         (body.length > 100 && body.length < 50000)); // конфиг обычно 1-30KB

    if (isStartXray) {
        try {
            const config = await parseXrayConfig(body);
            if (config?.inbounds) {
                const action = await applyDiff(config);
                if (action === 'hot' || action === 'skip') {
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ ok: true, action, hotReload: true }));
                    return;
                }
            }
        } catch (e) {
            log.error('Ошибка обработки конфига:', e.message);
        }
    }

    forward(req, res, body);
});

// ── Запуск ───────────────────────────────────────────────

async function main() {
    await initXray();
    setInterval(async () => { if (!xray) await initXray(); }, 30_000);

    server.listen(cfg.listenPort, '0.0.0.0', () => {
        console.log(`
╔══════════════════════════════════════════════════════╗
║     DarkVision Hot-Reload Sidecar v1.0.0             ║
╠══════════════════════════════════════════════════════╣
║  Порт:        :${String(cfg.listenPort).padEnd(5)} (панель стучится сюда)   ║
║  Реальная нода: ${cfg.realNodeHost}:${cfg.realNodePort}                    ║
║  Xray gRPC:   ${cfg.xrayHost}:${cfg.xrayPort}                   ║
╚══════════════════════════════════════════════════════╝`);
    });
}

main().catch(e => { console.error('FATAL:', e); process.exit(1); });
JSEOF

info "src/index.js создан"

# ── Создать .env ──────────────────────────────────────────
cat > "${INSTALL_DIR}/.env" << EOF
DV_LISTEN_PORT=${SIDECAR_PORT}
DV_REAL_NODE_HOST=127.0.0.1
DV_REAL_NODE_PORT=2222
DV_XRAY_GRPC_HOST=127.0.0.1
DV_XRAY_GRPC_PORT=${XRAY_PORT}
DV_DEBUG=false
EOF
chmod 600 "${INSTALL_DIR}/.env"
info ".env создан"

# ── Создать docker-compose.yml ────────────────────────────
cat > "${INSTALL_DIR}/docker-compose.yml" << EOF
version: '3.9'
services:
  darkvision-hotreload:
    image: node:22-alpine
    container_name: darkvision-hotreload
    restart: unless-stopped
    working_dir: /app
    command: sh -c "npm install --omit=dev --silent 2>&1 | tail -1 && node src/index.js"
    env_file: .env
    volumes:
      - ${INSTALL_DIR}:/app
    network_mode: host
    healthcheck:
      test: ["CMD","wget","-qO-","http://127.0.0.1:${SIDECAR_PORT}/dv-health"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 45s
EOF
info "docker-compose.yml создан"

# ── UFW ───────────────────────────────────────────────────
if command -v ufw &>/dev/null; then
    step "Открываю порт ${SIDECAR_PORT} в UFW..."
    ufw allow "${SIDECAR_PORT}/tcp" comment "DarkVision HotReload" &>/dev/null
    ufw reload &>/dev/null
    info "UFW: порт ${SIDECAR_PORT} открыт"
fi

# ── Запуск ────────────────────────────────────────────────
step "Запуск sidecar..."
cd "${INSTALL_DIR}"
docker compose up -d 2>&1

echo ""
step "Ожидание запуска (30 сек)..."
local_health_ok=false
for i in $(seq 1 10); do
    sleep 3
    printf "\r  ${GR}Попытка %d/10...${R}" "$i"
    if curl -sf "http://127.0.0.1:${SIDECAR_PORT}/dv-health" &>/dev/null; then
        local_health_ok=true
        break
    fi
done
echo ""

# ── Итог ─────────────────────────────────────────────────
SERVER_IP=$(curl -4 -sf --max-time 3 https://api.ipify.org 2>/dev/null || \
           curl -4 -sf --max-time 3 https://ipinfo.io/ip 2>/dev/null || echo "SERVER_IP")
echo ""
hr
if $local_health_ok; then
    echo -e "${G}  ✓ DarkVision Hot-Reload запущен!${R}"
else
    echo -e "${Y}  ! Запустился, но healthcheck ещё не прошёл (это нормально, npm install ~30 сек)${R}"
    echo -e "  ${GR}Проверь через: docker logs darkvision-hotreload${R}"
fi
hr
echo ""
if $IS_LOCAL; then
    echo -e "  ${W}Это финский сервер (панель + нода).${R}"
    echo -e "  В RemnaWave → Nodes → локальная нода:"
    echo -e "  Порт: ${RED}2222${R} → ${G}${SIDECAR_PORT}${R}"
else
    echo -e "  ${W}Это удалённая нода.${R}"
    echo -e "  В RemnaWave → Nodes → эта нода (${C}${SERVER_IP}${R}):"
    echo -e "  Порт: ${RED}2222${R} → ${G}${SIDECAR_PORT}${R}"
fi
echo ""
echo -e "  ${GR}Логи: docker logs darkvision-hotreload -f${R}"
echo -e "  ${GR}♻ HOT = горячо (без обрыва)  |  ↺ COLD = рестарт${R}"
echo ""
hr

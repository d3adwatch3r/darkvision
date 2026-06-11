/**
 * DarkVision Hot-Reload Sidecar v1.1.0
 * HTTPS — использует тот же сертификат что и remnanode
 *
 * Перехватывает START XRAY от RemnaWave панели:
 *   Только пользователи → AlterInbound gRPC (0ms, соединения живут ✓)
 *   Структура inbound   → форвард на remnanode (обычный рестарт, неизбежно)
 */
'use strict';

const fs     = require('fs');
const http   = require('http');
const https  = require('https');
const crypto = require('crypto');

const cfg = {
    listenPort:   parseInt(process.env.DV_LISTEN_PORT)    || 2224,
    realNodeHost: process.env.DV_REAL_NODE_HOST           || '127.0.0.1',
    realNodePort: parseInt(process.env.DV_REAL_NODE_PORT) || 2222,
    xrayHost:     process.env.DV_XRAY_GRPC_HOST           || '127.0.0.1',
    xrayPort:     parseInt(process.env.DV_XRAY_GRPC_PORT) || 61000,
    certFile:     process.env.DV_CERT_FILE                || '/app/server.crt',
    keyFile:      process.env.DV_KEY_FILE                 || '/app/server.key',
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
        log.warn(`Xray gRPC недоступен: ${e.message} — hot reload выключен`);
        xray = null;
    }
}

// ── Диффинг конфигов ─────────────────────────────────────

function structureHash(config) {
    if (!config?.inbounds) return '';
    const s = config.inbounds.map(ib => JSON.stringify({
        tag:  ib.tag,
        proto: ib.protocol,
        port:  ib.port,
        net:   ib.streamSettings?.network,
        sec:   ib.streamSettings?.security,
        pbk:   ib.streamSettings?.realitySettings?.privateKey,
    })).sort().join('|');
    return crypto.createHash('md5').update(s).digest('hex');
}

function extractUsers(config) {
    const users = new Map();
    if (!config?.inbounds) return users;
    for (const ib of config.inbounds) {
        for (const c of (ib.settings?.clients ?? [])) {
            const email = c.email ?? c.id ?? '';
            users.set(`${ib.tag}::${email}`, {
                tag: ib.tag, id: c.id, email,
                flow: c.flow ?? '', level: c.level ?? 0,
            });
        }
    }
    return users;
}

let lastConfig = null;
let lastStructHash = null;

async function applyDiff(newConfig) {
    // Первый запуск — сохраняем базовый конфиг и пропускаем на ноду
    if (!lastConfig) {
        lastConfig     = newConfig;
        lastStructHash = structureHash(newConfig);
        log.info('Первый конфиг получен → пропускаем на ноду (baseline)');
        return 'first';
    }

    const newH = structureHash(newConfig);

    // Структура изменилась — нужен полный рестарт (порт, протокол, Reality ключи)
    if (newH !== lastStructHash) {
        log.cold('Структура inbound изменилась → полный рестарт');
        lastConfig     = newConfig;
        lastStructHash = newH;
        return 'cold';
    }

    // Считаем diff только по пользователям
    const oldUsers = extractUsers(lastConfig);
    const newUsers = extractUsers(newConfig);
    const added    = [...newUsers.values()].filter(u => !oldUsers.has(`${u.tag}::${u.email}`));
    const removed  = [...oldUsers.values()].filter(u => !newUsers.has(`${u.tag}::${u.email}`));

    if (added.length === 0 && removed.length === 0) {
        log.debug('Нет изменений пользователей → пропускаем');
        return 'skip';
    }

    log.info(`Изменения: +${added.length} добавлено, -${removed.length} удалено`);

    if (!xray) {
        log.warn('Xray gRPC недоступен → холодный рестарт');
        lastConfig = newConfig;
        return 'cold';
    }

    // Применяем горячо — без рестарта Xray
    try {
        for (const u of added) {
            await xray.handlerService.addUser(u.tag, {
                id: u.id, email: u.email, flow: u.flow, level: u.level,
            });
            log.hot(`+ ${u.email} → inbound [${u.tag}]`);
        }
        for (const u of removed) {
            await xray.handlerService.removeUser(u.tag, u.email);
            log.hot(`- ${u.email} ← inbound [${u.tag}]`);
        }
        lastConfig = newConfig;
        log.hot(`Готово — соединения клиентов НЕ прерваны ✓`);
        return 'hot';
    } catch (e) {
        log.error('Hot reload ошибка:', e.message, '→ fallback на рестарт');
        lastConfig = newConfig;
        return 'cold';
    }
}

// ── Парсинг ZSTD-сжатого конфига от RemnaWave ────────────

async function parseConfig(buf) {
    const tries = [
        // Бинарный ZSTD
        async () => {
            const z = require('@mongodb-js/zstd');
            return JSON.parse((await z.decompress(buf)).toString());
        },
        // Base64 → ZSTD
        async () => {
            const z = require('@mongodb-js/zstd');
            return JSON.parse((await z.decompress(Buffer.from(buf.toString(), 'base64'))).toString());
        },
        // Обычный JSON
        async () => JSON.parse(buf.toString()),
    ];
    for (const fn of tries) {
        try { return await fn(); } catch {}
    }
    return null;
}

// ── Форвард на remnanode (HTTPS) ─────────────────────────

function forwardToNode(req, res, body) {
    const opts = {
        hostname: cfg.realNodeHost,
        port:     cfg.realNodePort,
        path:     req.url,
        method:   req.method,
        headers:  { ...req.headers, host: `${cfg.realNodeHost}:${cfg.realNodePort}` },
        // remnanode на localhost — self-signed cert, отключаем проверку
        rejectUnauthorized: false,
    };

    const pr = https.request(opts, ps => {
        res.writeHead(ps.statusCode, ps.headers);
        ps.pipe(res, { end: true });
    });

    pr.on('error', e => {
        log.error('Ошибка форварда на remnanode:', e.message);
        if (!res.headersSent) {
            res.writeHead(502, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'node unreachable', message: e.message }));
        }
    });

    if (body?.length) pr.write(body);
    pr.end();
}

// ── Обработчик запросов ───────────────────────────────────

async function requestHandler(req, res) {
    log.debug(`${req.method} ${req.url} (${req.headers['content-length'] ?? 0} bytes)`);

    // Health check самого sidecar
    if (req.url === '/dv-health') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            status:       'ok',
            version:      '1.1.0',
            xray:         !!xray,
            hasBaseline:  !!lastConfig,
            listenPort:   cfg.listenPort,
        }));
        return;
    }

    // Читаем тело
    const body = await new Promise((resolve, reject) => {
        const chunks = [];
        req.on('data',  c => chunks.push(c));
        req.on('end',   () => resolve(Buffer.concat(chunks)));
        req.on('error', reject);
    });

    // Пробуем перехватить как START XRAY
    // RemnaWave отправляет POST с ZSTD-сжатым конфигом
    const mightBeConfig = req.method === 'POST' &&
        body.length > 50 && body.length < 200_000;

    if (mightBeConfig) {
        try {
            const config = await parseConfig(body);

            if (config?.inbounds && Array.isArray(config.inbounds)) {
                log.debug(`Конфиг распознан: ${config.inbounds.length} inbounds`);
                const action = await applyDiff(config);

                if (action === 'hot' || action === 'skip') {
                    // Горячо применили — не беспокоим ноду
                    res.writeHead(200, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ ok: true, action }));
                    return;
                }
                // 'first' | 'cold' → проксируем на ноду
            }
        } catch (e) {
            log.debug('Не xray конфиг:', e.message);
        }
    }

    // Всё остальное — на реальную ноду
    forwardToNode(req, res, body);
}

// ── Запуск ───────────────────────────────────────────────

async function main() {
    // TLS сертификат (тот же что у remnanode, чтобы панель не ругалась)
    let tlsOptions;
    try {
        tlsOptions = {
            cert: fs.readFileSync(cfg.certFile),
            key:  fs.readFileSync(cfg.keyFile),
        };
        log.info(`TLS загружен: ${cfg.certFile}`);
    } catch (e) {
        log.error(`Не удалось загрузить TLS сертификат: ${e.message}`);
        log.error(`Путь cert: ${cfg.certFile}`);
        log.error(`Путь key:  ${cfg.keyFile}`);
        process.exit(1);
    }

    // Подключение к Xray gRPC
    await initXray();
    // Переподключение каждые 30 сек
    setInterval(async () => { if (!xray) await initXray(); }, 30_000);

    // HTTPS сервер
    const server = https.createServer(tlsOptions, requestHandler);

    server.on('error', e => {
        log.error('Сервер упал:', e.message);
        if (e.code === 'EADDRINUSE') {
            log.error(`Порт ${cfg.listenPort} уже занят!`);
            process.exit(1);
        }
    });

    server.listen(cfg.listenPort, '0.0.0.0', () => {
        const cert = tlsOptions.cert.toString();
        const cn   = cert.match(/CN\s*=\s*([^\n,/]+)/)?.[1]?.trim() ?? '?';
        console.log(`
╔══════════════════════════════════════════════════════════╗
║     DarkVision Hot-Reload Sidecar v1.1.0 (HTTPS)         ║
╠══════════════════════════════════════════════════════════╣
║  Слушаю HTTPS :${String(cfg.listenPort).padEnd(5)}                              ║
║  Реальная нода: HTTPS ${cfg.realNodeHost}:${cfg.realNodePort}                  ║
║  Xray gRPC:     ${cfg.xrayHost}:${cfg.xrayPort}                     ║
║  TLS cert CN:   ${cn.padEnd(38)}  ║
╠══════════════════════════════════════════════════════════╣
║  ♻ HOT  — пользователь добавлен/удалён без рестарта      ║
║  ↺ COLD — структурное изменение, рестарт неизбежен        ║
╚══════════════════════════════════════════════════════════╝`);
    });
}

main().catch(e => { console.error('FATAL:', e); process.exit(1); });
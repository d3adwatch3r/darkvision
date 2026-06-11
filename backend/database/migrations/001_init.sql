-- DarkVision Panel — Initial Schema
-- Runs once when postgres container first starts

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────
--  Admins (учётные записи панели)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS admins (
    id            SERIAL PRIMARY KEY,
    username      VARCHAR(50)  UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    is_super      BOOLEAN      DEFAULT FALSE,
    created_at    TIMESTAMPTZ  DEFAULT NOW(),
    last_login    TIMESTAMPTZ
);

-- ─────────────────────────────────────────
--  Sessions (refresh-token whitelist)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sessions (
    id            SERIAL PRIMARY KEY,
    admin_id      INTEGER      REFERENCES admins(id) ON DELETE CASCADE,
    refresh_token VARCHAR(512) UNIQUE NOT NULL,
    ip_address    INET,
    user_agent    TEXT,
    expires_at    TIMESTAMPTZ  NOT NULL,
    created_at    TIMESTAMPTZ  DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_sessions_admin ON sessions(admin_id);
CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions(refresh_token);

-- ─────────────────────────────────────────
--  Nodes (VPN серверы)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS nodes (
    id             SERIAL PRIMARY KEY,
    name           VARCHAR(100) NOT NULL,
    host           VARCHAR(255) NOT NULL,
    port           INTEGER      NOT NULL DEFAULT 443,
    agent_port     INTEGER      NOT NULL DEFAULT 2095,
    agent_secret   VARCHAR(255) NOT NULL,
    status         VARCHAR(20)  DEFAULT 'offline',  -- online, offline, error
    xray_version   VARCHAR(50),
    uptime_seconds BIGINT       DEFAULT 0,
    load_1m        FLOAT        DEFAULT 0,
    traffic_up     BIGINT       DEFAULT 0,
    traffic_down   BIGINT       DEFAULT 0,
    created_at     TIMESTAMPTZ  DEFAULT NOW(),
    updated_at     TIMESTAMPTZ  DEFAULT NOW()
);

-- ─────────────────────────────────────────
--  Inbounds (протоколы на нодах)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS inbounds (
    id              SERIAL PRIMARY KEY,
    node_id         INTEGER     REFERENCES nodes(id) ON DELETE CASCADE,
    tag             VARCHAR(100) NOT NULL,
    protocol        VARCHAR(50)  NOT NULL,  -- vless, vmess, trojan
    port            INTEGER      NOT NULL,
    network         VARCHAR(50)  DEFAULT 'tcp',
    security        VARCHAR(50)  DEFAULT 'reality',
    reality_pbk     VARCHAR(255),
    reality_sid     VARCHAR(100),
    sni             VARCHAR(255),
    fingerprint     VARCHAR(50)  DEFAULT 'chrome',
    flow            VARCHAR(100) DEFAULT 'xtls-rprx-vision',
    settings        JSONB        NOT NULL DEFAULT '{}',
    stream_settings JSONB        NOT NULL DEFAULT '{}',
    enabled         BOOLEAN      DEFAULT TRUE,
    created_at      TIMESTAMPTZ  DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_inbounds_node ON inbounds(node_id);

-- ─────────────────────────────────────────
--  VPN Users
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS vpn_users (
    id              SERIAL PRIMARY KEY,
    uuid            UUID         UNIQUE NOT NULL DEFAULT gen_random_uuid(),
    username        VARCHAR(100) UNIQUE NOT NULL,
    email           VARCHAR(255),
    sub_token       VARCHAR(64)  UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(32), 'hex'),
    status          VARCHAR(20)  DEFAULT 'active',   -- active, disabled, expired
    traffic_limit   BIGINT       DEFAULT 0,           -- байт, 0 = unlimited
    traffic_used    BIGINT       DEFAULT 0,
    expire_at       TIMESTAMPTZ,
    telegram_id     BIGINT,
    note            TEXT,
    created_at      TIMESTAMPTZ  DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_vpnusers_status    ON vpn_users(status);
CREATE INDEX IF NOT EXISTS idx_vpnusers_telegram  ON vpn_users(telegram_id);
CREATE INDEX IF NOT EXISTS idx_vpnusers_sub_token ON vpn_users(sub_token);
CREATE INDEX IF NOT EXISTS idx_vpnusers_expire    ON vpn_users(expire_at);

-- ─────────────────────────────────────────
--  User ↔ Inbound mapping
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS user_inbounds (
    user_id    INTEGER REFERENCES vpn_users(id) ON DELETE CASCADE,
    inbound_id INTEGER REFERENCES inbounds(id)  ON DELETE CASCADE,
    PRIMARY KEY (user_id, inbound_id)
);

-- ─────────────────────────────────────────
--  Traffic logs (почасовая агрегация)
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS traffic_logs (
    id         BIGSERIAL PRIMARY KEY,
    user_id    INTEGER     REFERENCES vpn_users(id) ON DELETE SET NULL,
    node_id    INTEGER     REFERENCES nodes(id)     ON DELETE SET NULL,
    upload     BIGINT      NOT NULL DEFAULT 0,
    download   BIGINT      NOT NULL DEFAULT 0,
    logged_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_traffic_user    ON traffic_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_traffic_node    ON traffic_logs(node_id);
CREATE INDEX IF NOT EXISTS idx_traffic_time    ON traffic_logs(logged_at DESC);

-- ─────────────────────────────────────────
--  Audit log
-- ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS audit_logs (
    id          BIGSERIAL PRIMARY KEY,
    admin_id    INTEGER     REFERENCES admins(id) ON DELETE SET NULL,
    action      VARCHAR(100) NOT NULL,
    target_type VARCHAR(50),
    target_id   INTEGER,
    details     JSONB,
    ip_address  INET,
    created_at  TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_audit_admin ON audit_logs(admin_id);
CREATE INDEX IF NOT EXISTS idx_audit_time  ON audit_logs(created_at DESC);

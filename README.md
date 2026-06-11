# DarkVision VPN Panel

Высокопроизводительная VPN панель на Go + React в Docker.

## Быстрый старт

```bash
bash <(curl -Ls https://raw.githubusercontent.com/d3adwatch3r/darkvision/main/install.sh)
```

## Архитектура

```
nginx (8443) → frontend (React)
             → backend  (Go + Fiber)
                 ↓ gRPC hot-reload
backend ←→ xray-core (VLESS Reality)
backend ←→ postgres
backend ←→ redis
```

## Горячая перезагрузка

Пользователи добавляются/удаляются через `HandlerService.AlterInbound` gRPC API Xray.  
Существующие VPN соединения **не прерываются**.

## Команды после установки

```bash
darkvision          # меню управления
dv                  # алиас

dv status           # статус
dv logs             # логи
dv restart          # перезапустить
dv backup           # резервная копия БД
dv update           # обновить скрипт
```

## API

```
POST /api/v1/auth/setup     # первый запуск
POST /api/v1/auth/login
POST /api/v1/auth/refresh
GET  /api/v1/users
POST /api/v1/users
GET  /api/v1/nodes
GET  /sub/:token            # ссылка подписки (v2ray/clash/singbox)
```

## Форматы подписки

```
https://panel.example.com/sub/TOKEN           # V2Ray base64
https://panel.example.com/sub/TOKEN?format=clash
https://panel.example.com/sub/TOKEN?format=singbox
```

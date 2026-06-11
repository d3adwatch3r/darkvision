.PHONY: up down restart logs build ps setup help

COMPOSE=docker compose -f docker-compose.yml
PANEL_DIR=/opt/darkvision

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "};{printf "\033[36m%-22s\033[0m %s\n",$$1,$$2}'

up: ## Запустить все сервисы
	$(COMPOSE) up -d

down: ## Остановить
	$(COMPOSE) down

restart: ## Перезапустить всё
	$(COMPOSE) restart

restart-backend: ## Только backend
	$(COMPOSE) restart backend

restart-xray: ## Только xray (горячий, без сброса клиентов)
	$(COMPOSE) restart xray

restart-nginx: ## Только nginx
	$(COMPOSE) restart nginx

build: ## Пересобрать образы
	$(COMPOSE) build --no-cache

logs: ## Все логи
	$(COMPOSE) logs -f

logs-backend: ## Логи backend
	$(COMPOSE) logs -f --tail=100 backend

logs-xray: ## Логи xray
	$(COMPOSE) logs -f --tail=100 xray

ps: ## Статус контейнеров
	$(COMPOSE) ps

db-shell: ## PostgreSQL shell
	$(COMPOSE) exec postgres psql -U darkvision -d darkvision

db-backup: ## Дамп БД
	@mkdir -p backups
	$(COMPOSE) exec -T postgres pg_dump -U darkvision darkvision | \
	  gzip > backups/dump_$(shell date +%Y%m%d_%H%M%S).sql.gz
	@echo "✓ Дамп сохранён в backups/"

shell-backend: ## Shell в backend
	$(COMPOSE) exec backend sh

clean: ## Полная очистка (ОСТОРОЖНО!)
	$(COMPOSE) down -v --remove-orphans

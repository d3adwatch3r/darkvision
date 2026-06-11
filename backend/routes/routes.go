package routes

import (
	"github.com/darkvision/panel/config"
	"github.com/darkvision/panel/handlers"
	mw "github.com/darkvision/panel/middleware"
	"github.com/darkvision/panel/telegram"
	"github.com/darkvision/panel/xray"
	"github.com/gofiber/fiber/v2"
)

func Register(app *fiber.App, cfg *config.Config, xrayMgr *xray.Manager) {
	// ─── Handlers ────────────────────────────────────────────
	authH := handlers.NewAuthHandler(cfg)
	userH := handlers.NewUserHandler(xrayMgr)
	nodeH := handlers.NewNodeHandler()
	subH  := handlers.NewSubHandler(cfg)
	statH := handlers.NewStatsHandler()
	tgH   := telegram.NewHandler(cfg)

	// ─── Публичные маршруты ───────────────────────────────────

	// Ссылки подписки (скачиваются VPN клиентами автоматически)
	app.Get("/sub/:token", subH.GetSubscription)

	// Telegram webhook (проверяется через secret header, не JWT)
	app.Post("/api/v1/telegram/webhook", tgH.Webhook)

	// ─── Auth (без JWT) ───────────────────────────────────────
	auth := app.Group("/api/v1/auth")
	auth.Get("/setup-status", authH.SetupStatus)
	auth.Post("/setup",       authH.Setup)
	auth.Post("/login",       authH.Login)
	auth.Post("/refresh",     authH.Refresh)

	// ─── Защищённые маршруты (JWT обязателен) ────────────────
	api := app.Group("/api/v1", mw.JWTMiddleware(cfg.JWTSecret))

	// Auth (с JWT)
	api.Delete("/auth/logout",          authH.Logout)
	api.Get("/auth/me",                 authH.Me)
	api.Put("/auth/change-password",    authH.ChangePassword)

	// VPN Пользователи
	users := api.Group("/users")
	users.Get("/",              userH.List)
	users.Post("/",             userH.Create)
	users.Get("/:id",           userH.Get)
	users.Put("/:id",           userH.Update)
	users.Delete("/:id",        userH.Delete)
	users.Post("/:id/reset-traffic", userH.ResetTraffic)
	users.Post("/:id/revoke-sub",    userH.RevokeSub)
	users.Get("/:id/sub-link",       subH.GetSubLink)

	// Ноды (только superadmin)
	nodes := api.Group("/nodes", mw.SuperAdminOnly())
	nodes.Get("/",         nodeH.List)
	nodes.Post("/",        nodeH.Create)
	nodes.Get("/:id",      nodeH.Get)
	nodes.Put("/:id",      nodeH.Update)
	nodes.Delete("/:id",   nodeH.Delete)
	nodes.Get("/:id/status", nodeH.Status)

	// Статистика
	api.Get("/stats", statH.Dashboard)
}

package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/darkvision/panel/config"
	"github.com/darkvision/panel/database"
	mw "github.com/darkvision/panel/middleware"
	"github.com/darkvision/panel/routes"
	"github.com/darkvision/panel/xray"
	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/compress"
	"github.com/gofiber/fiber/v2/middleware/cors"
	"github.com/gofiber/fiber/v2/middleware/helmet"
	"github.com/gofiber/fiber/v2/middleware/recover"
	"github.com/gofiber/fiber/v2/middleware/requestid"
	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
)

func main() {
	// Config
	cfg := config.Load()

	// Logger
	logger := buildLogger(cfg.AppEnv, cfg.LogLevel)
	defer logger.Sync()
	zap.ReplaceGlobals(logger)
	zap.L().Info("DarkVision Panel starting",
		zap.String("env", cfg.AppEnv),
		zap.String("port", cfg.AppPort),
	)

	// Database
	if err := database.Connect(cfg); err != nil {
		zap.L().Fatal("postgres connect failed", zap.Error(err))
	}

	// Redis
	if err := database.ConnectRedis(cfg); err != nil {
		zap.L().Fatal("redis connect failed", zap.Error(err))
	}

	// Xray Manager (горячая перезагрузка пользователей через gRPC)
	xrayMgr, err := xray.NewManager(cfg.XrayAPIHost, cfg.XrayAPIPort)
	if err != nil {
		zap.L().Warn("xray manager unavailable at startup (will retry on demand)",
			zap.Error(err))
	}

	// Fiber app
	app := fiber.New(fiber.Config{
		AppName:               "DarkVision Panel",
		ReadTimeout:           15 * time.Second,
		WriteTimeout:          30 * time.Second,
		IdleTimeout:           60 * time.Second,
		BodyLimit:             4 * 1024 * 1024, // 4 MB
		DisableStartupMessage: true,
		ErrorHandler:          mw.ErrorHandler,
		// Prefork отключён для корректного graceful shutdown
	})

	// ─── Global Middleware ────────────────────────────────────

	app.Use(recover.New(recover.Config{
		EnableStackTrace: cfg.AppEnv == "development",
	}))
	app.Use(requestid.New())
	app.Use(mw.StructuredLogger(logger))
	app.Use(compress.New(compress.Config{Level: compress.LevelBestSpeed}))

	app.Use(cors.New(cors.Config{
		AllowOrigins:     cfg.AllowedOrigins,
		AllowHeaders:     "Origin, Content-Type, Accept, Authorization, X-CSRF-Token",
		AllowMethods:     "GET, POST, PUT, DELETE, OPTIONS",
		AllowCredentials: true,
		MaxAge:           600,
	}))

	// Security headers
	app.Use(helmet.New(helmet.Config{
		XSSProtection:             "1; mode=block",
		ContentTypeNosniff:        "nosniff",
		XFrameOptions:             "DENY",
		ReferrerPolicy:            "strict-origin-when-cross-origin",
		ContentSecurityPolicy:     "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'",
		HSTSMaxAge:                31536000,
		HSTSExcludeSubdomains:     false,
		HSTSPreloadEnabled:        true,
		PermissionPolicy:          "camera=(), microphone=(), geolocation=()",
	}))

	// Rate limiter (Redis-backed sliding window)
	app.Use(mw.RateLimiter(database.Redis, cfg))

	// CSRF (double-submit cookie) — применяется до регистрации роутов
	app.Use(mw.CSRFMiddleware())

	// ─── Routes ───────────────────────────────────────────────
	routes.Register(app, cfg, xrayMgr)

	// Health check (без JWT, без CSRF)
	app.Get("/health", func(c *fiber.Ctx) error {
		return c.JSON(fiber.Map{
			"status":  "ok",
			"name":    "DarkVision",
			"version": "1.0.0",
		})
	})

	// 404
	app.Use(func(c *fiber.Ctx) error {
		return c.Status(404).JSON(fiber.Map{"error": "not found"})
	})

	// ─── Graceful Shutdown ────────────────────────────────────
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGTERM)

	go func() {
		addr := ":" + cfg.AppPort
		zap.L().Info("server listening", zap.String("addr", addr))
		if err := app.Listen(addr); err != nil {
			zap.L().Error("server error", zap.Error(err))
		}
	}()

	<-quit
	zap.L().Info("graceful shutdown...")

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if xrayMgr != nil {
		xrayMgr.Close()
	}

	if err := app.ShutdownWithContext(ctx); err != nil {
		zap.L().Error("shutdown error", zap.Error(err))
	}

	zap.L().Info("stopped")
}

func buildLogger(env, level string) *zap.Logger {
	var lvl zapcore.Level
	switch level {
	case "debug":
		lvl = zapcore.DebugLevel
	case "warn":
		lvl = zapcore.WarnLevel
	case "error":
		lvl = zapcore.ErrorLevel
	default:
		lvl = zapcore.InfoLevel
	}

	var cfg zap.Config
	if env == "development" {
		cfg = zap.NewDevelopmentConfig()
		cfg.EncoderConfig.EncodeLevel = zapcore.CapitalColorLevelEncoder
	} else {
		cfg = zap.NewProductionConfig()
	}
	cfg.Level = zap.NewAtomicLevelAt(lvl)

	logger, _ := cfg.Build()
	return logger
}

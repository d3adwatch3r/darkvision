package middleware

import (
	"context"
	"fmt"
	"time"

	"github.com/darkvision/panel/config"
	"github.com/gofiber/fiber/v2"
	jwtmw "github.com/gofiber/contrib/jwt"
	"github.com/golang-jwt/jwt/v5"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

// ─────────────────────────────────────────
//  JWT Claims
// ─────────────────────────────────────────

type Claims struct {
	AdminID  uint   `json:"admin_id"`
	Username string `json:"username"`
	IsSuper  bool   `json:"is_super"`
	jwt.RegisteredClaims
}

// JWTMiddleware — защита роутов токеном
func JWTMiddleware(secret string) fiber.Handler {
	return jwtmw.New(jwtmw.Config{
		SigningKey: jwtmw.SigningKey{Key: []byte(secret)},
		ContextKey: "admin_claims",
		ErrorHandler: func(c *fiber.Ctx, err error) error {
			return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
				"error": "unauthorized",
			})
		},
		Claims: &Claims{},
	})
}

// GetClaims — извлечь claims из контекста
func GetClaims(c *fiber.Ctx) *Claims {
	token := c.Locals("admin_claims").(*jwt.Token)
	return token.Claims.(*Claims)
}

// ─────────────────────────────────────────
//  CSRF (double-submit cookie)
// ─────────────────────────────────────────

const csrfCookieName = "csrf_token"
const csrfHeaderName = "X-CSRF-Token"

func CSRFMiddleware() fiber.Handler {
	return func(c *fiber.Ctx) error {
		// Skip safe methods and exempt paths
		method := c.Method()
		if method == "GET" || method == "HEAD" || method == "OPTIONS" {
			return c.Next()
		}

		// Skip telegram webhook (uses HMAC secret instead)
		if c.Path() == "/api/v1/telegram/webhook" {
			return c.Next()
		}

		// Skip subscription links
		if len(c.Path()) > 5 && c.Path()[:5] == "/sub/" {
			return c.Next()
		}

		cookieToken := c.Cookies(csrfCookieName)
		headerToken := c.Get(csrfHeaderName)

		if cookieToken == "" || headerToken == "" || cookieToken != headerToken {
			return c.Status(fiber.StatusForbidden).JSON(fiber.Map{
				"error": "csrf validation failed",
			})
		}

		return c.Next()
	}
}

// ─────────────────────────────────────────
//  Rate Limiter (Redis-backed sliding window)
// ─────────────────────────────────────────

func RateLimiter(rdb *redis.Client, cfg *config.Config) fiber.Handler {
	max := cfg.RateLimitMax
	window := time.Duration(cfg.RateLimitWindow) * time.Second

	return func(c *fiber.Ctx) error {
		key := fmt.Sprintf("rl:%s", c.IP())
		ctx := context.Background()

		pipe := rdb.TxPipeline()
		incr := pipe.Incr(ctx, key)
		pipe.Expire(ctx, key, window)
		_, err := pipe.Exec(ctx)
		if err != nil {
			// Redis error — pass through (fail open)
			return c.Next()
		}

		count := int(incr.Val())
		c.Set("X-RateLimit-Limit", fmt.Sprintf("%d", max))
		c.Set("X-RateLimit-Remaining", fmt.Sprintf("%d", max-count))

		if count > max {
			return c.Status(fiber.StatusTooManyRequests).JSON(fiber.Map{
				"error": "rate limit exceeded",
			})
		}

		return c.Next()
	}
}

// ─────────────────────────────────────────
//  Structured Logger
// ─────────────────────────────────────────

func StructuredLogger(log *zap.Logger) fiber.Handler {
	return func(c *fiber.Ctx) error {
		start := time.Now()
		err := c.Next()
		latency := time.Since(start)

		status := c.Response().StatusCode()
		fields := []zap.Field{
			zap.String("method", c.Method()),
			zap.String("path", c.Path()),
			zap.Int("status", status),
			zap.Duration("latency", latency),
			zap.String("ip", c.IP()),
			zap.String("request_id", c.GetRespHeader("X-Request-Id")),
		}

		if err != nil {
			fields = append(fields, zap.Error(err))
		}

		if status >= 500 {
			log.Error("request", fields...)
		} else if status >= 400 {
			log.Warn("request", fields...)
		} else {
			log.Info("request", fields...)
		}

		return err
	}
}

// ─────────────────────────────────────────
//  Error Handler
// ─────────────────────────────────────────

func ErrorHandler(c *fiber.Ctx, err error) error {
	code := fiber.StatusInternalServerError
	msg := "internal server error"

	if e, ok := err.(*fiber.Error); ok {
		code = e.Code
		msg = e.Message
	}

	zap.L().Error("unhandled error",
		zap.Error(err),
		zap.String("path", c.Path()),
		zap.Int("code", code),
	)

	return c.Status(code).JSON(fiber.Map{
		"error": msg,
	})
}

// ─────────────────────────────────────────
//  SuperAdmin only
// ─────────────────────────────────────────

func SuperAdminOnly() fiber.Handler {
	return func(c *fiber.Ctx) error {
		claims := GetClaims(c)
		if !claims.IsSuper {
			return c.Status(fiber.StatusForbidden).JSON(fiber.Map{
				"error": "superadmin access required",
			})
		}
		return c.Next()
	}
}

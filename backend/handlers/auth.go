package handlers

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"time"

	"github.com/darkvision/panel/config"
	"github.com/darkvision/panel/database"
	"github.com/darkvision/panel/middleware"
	"github.com/darkvision/panel/models"
	"github.com/gofiber/fiber/v2"
	"github.com/golang-jwt/jwt/v5"
	"go.uber.org/zap"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
)

type AuthHandler struct {
	cfg *config.Config
}

func NewAuthHandler(cfg *config.Config) *AuthHandler {
	return &AuthHandler{cfg: cfg}
}

// ─────────────────────────────────────────
//  POST /api/v1/auth/setup-status
//  Проверить — был ли уже создан admin
// ─────────────────────────────────────────

func (h *AuthHandler) SetupStatus(c *fiber.Ctx) error {
	var count int64
	database.DB.Model(&models.Admin{}).Count(&count)
	return c.JSON(fiber.Map{
		"setup_done": count > 0,
	})
}

// ─────────────────────────────────────────
//  POST /api/v1/auth/setup
//  Первый запуск — создание superadmin
// ─────────────────────────────────────────

type SetupRequest struct {
	Username string `json:"username" validate:"required,min=3,max=50"`
	Password string `json:"password" validate:"required,min=8"`
}

func (h *AuthHandler) Setup(c *fiber.Ctx) error {
	// Проверить что admins ещё нет
	var count int64
	database.DB.Model(&models.Admin{}).Count(&count)
	if count > 0 {
		return c.Status(fiber.StatusConflict).JSON(fiber.Map{
			"error": "setup already completed",
		})
	}

	var req SetupRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{"error": "invalid body"})
	}
	if len(req.Username) < 3 || len(req.Password) < 8 {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{
			"error": "username >= 3 chars, password >= 8 chars",
		})
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		return fiber.ErrInternalServerError
	}

	admin := &models.Admin{
		Username:     req.Username,
		PasswordHash: string(hash),
		IsSuper:      true,
	}
	if err := database.DB.Create(admin).Error; err != nil {
		return c.Status(fiber.StatusInternalServerError).JSON(fiber.Map{"error": "db error"})
	}

	zap.L().Info("Superadmin created", zap.String("username", req.Username))

	// Выдать токены сразу
	return h.issueTokens(c, admin)
}

// ─────────────────────────────────────────
//  POST /api/v1/auth/login
// ─────────────────────────────────────────

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func (h *AuthHandler) Login(c *fiber.Ctx) error {
	var req LoginRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{"error": "invalid body"})
	}

	var admin models.Admin
	if err := database.DB.Where("username = ?", req.Username).First(&admin).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{"error": "invalid credentials"})
		}
		return fiber.ErrInternalServerError
	}

	if err := bcrypt.CompareHashAndPassword([]byte(admin.PasswordHash), []byte(req.Password)); err != nil {
		zap.L().Warn("Failed login attempt", zap.String("username", req.Username), zap.String("ip", c.IP()))
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{"error": "invalid credentials"})
	}

	// Обновить last_login
	now := time.Now().UTC()
	database.DB.Model(&admin).Update("last_login", now)

	// Записать в audit log
	writeAudit(admin.ID, "login", "admin", admin.ID, nil, c.IP())

	return h.issueTokens(c, &admin)
}

// ─────────────────────────────────────────
//  POST /api/v1/auth/refresh
// ─────────────────────────────────────────

type RefreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

func (h *AuthHandler) Refresh(c *fiber.Ctx) error {
	var req RefreshRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(fiber.StatusBadRequest).JSON(fiber.Map{"error": "invalid body"})
	}

	// Найти сессию в БД
	var session models.Session
	if err := database.DB.Where("refresh_token = ? AND expires_at > ?", req.RefreshToken, time.Now()).
		First(&session).Error; err != nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{"error": "invalid or expired refresh token"})
	}

	// Также удалить Redis запись (refresh rotation)
	ctx := context.Background()
	database.Redis.Del(ctx, "refresh:"+req.RefreshToken)

	// Загрузить admin
	var admin models.Admin
	if err := database.DB.First(&admin, session.AdminID).Error; err != nil {
		return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{"error": "admin not found"})
	}

	// Удалить старую сессию
	database.DB.Delete(&session)

	return h.issueTokens(c, &admin)
}

// ─────────────────────────────────────────
//  DELETE /api/v1/auth/logout
// ─────────────────────────────────────────

func (h *AuthHandler) Logout(c *fiber.Ctx) error {
	claims := middleware.GetClaims(c)

	// Удалить все сессии этого admin
	database.DB.Where("admin_id = ?", claims.AdminID).Delete(&models.Session{})

	// Удалить CSRF cookie
	c.Cookie(&fiber.Cookie{
		Name:    "csrf_token",
		Value:   "",
		Expires: time.Unix(0, 0),
	})

	return c.JSON(fiber.Map{"message": "logged out"})
}

// ─────────────────────────────────────────
//  GET /api/v1/auth/me
// ─────────────────────────────────────────

func (h *AuthHandler) Me(c *fiber.Ctx) error {
	claims := middleware.GetClaims(c)
	var admin models.Admin
	if err := database.DB.First(&admin, claims.AdminID).Error; err != nil {
		return fiber.ErrUnauthorized
	}
	return c.JSON(admin)
}

// ─────────────────────────────────────────
//  PUT /api/v1/auth/change-password
// ─────────────────────────────────────────

type ChangePassRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

func (h *AuthHandler) ChangePassword(c *fiber.Ctx) error {
	claims := middleware.GetClaims(c)
	var req ChangePassRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(400).JSON(fiber.Map{"error": "invalid body"})
	}
	if len(req.NewPassword) < 8 {
		return c.Status(400).JSON(fiber.Map{"error": "new password must be at least 8 chars"})
	}

	var admin models.Admin
	database.DB.First(&admin, claims.AdminID)

	if err := bcrypt.CompareHashAndPassword([]byte(admin.PasswordHash), []byte(req.CurrentPassword)); err != nil {
		return c.Status(400).JSON(fiber.Map{"error": "current password is wrong"})
	}

	hash, _ := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	database.DB.Model(&admin).Update("password_hash", string(hash))

	// Сбросить все сессии
	database.DB.Where("admin_id = ?", admin.ID).Delete(&models.Session{})

	writeAudit(admin.ID, "change_password", "admin", admin.ID, nil, c.IP())
	return c.JSON(fiber.Map{"message": "password changed"})
}

// ─────────────────────────────────────────
//  Helpers
// ─────────────────────────────────────────

func (h *AuthHandler) issueTokens(c *fiber.Ctx, admin *models.Admin) error {
	now := time.Now().UTC()

	// Access token
	accessClaims := middleware.Claims{
		AdminID:  admin.ID,
		Username: admin.Username,
		IsSuper:  admin.IsSuper,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(now.Add(h.cfg.JWTAccessTTL)),
			IssuedAt:  jwt.NewNumericDate(now),
			Issuer:    "darkvision",
		},
	}
	accessToken := jwt.NewWithClaims(jwt.SigningMethodHS256, accessClaims)
	accessStr, err := accessToken.SignedString([]byte(h.cfg.JWTSecret))
	if err != nil {
		return fiber.ErrInternalServerError
	}

	// Refresh token — случайный hex
	refreshBytes := make([]byte, 32)
	rand.Read(refreshBytes)
	refreshStr := hex.EncodeToString(refreshBytes)

	// Сохранить сессию в БД
	session := &models.Session{
		AdminID:      admin.ID,
		RefreshToken: refreshStr,
		IPAddress:    c.IP(),
		UserAgent:    c.Get("User-Agent"),
		ExpiresAt:    now.Add(h.cfg.JWTRefreshTTL),
	}
	database.DB.Create(session)

	// CSRF token в cookie
	csrfBytes := make([]byte, 16)
	rand.Read(csrfBytes)
	csrfToken := hex.EncodeToString(csrfBytes)
	c.Cookie(&fiber.Cookie{
		Name:     "csrf_token",
		Value:    csrfToken,
		HTTPOnly: false, // фронт должен читать
		Secure:   h.cfg.AppEnv == "production",
		SameSite: "Strict",
		MaxAge:   int(h.cfg.JWTRefreshTTL.Seconds()),
	})

	return c.JSON(fiber.Map{
		"access_token":  accessStr,
		"refresh_token": refreshStr,
		"expires_in":    int(h.cfg.JWTAccessTTL.Seconds()),
		"admin": fiber.Map{
			"id":       admin.ID,
			"username": admin.Username,
			"is_super": admin.IsSuper,
		},
	})
}

func writeAudit(adminID uint, action, targetType string, targetID uint, details map[string]interface{}, ip string) {
	log := &models.AuditLog{
		AdminID:    &adminID,
		Action:     action,
		TargetType: targetType,
		TargetID:   &targetID,
		IPAddress:  ip,
	}
	if details != nil {
		log.Details = models.JSONB(details)
	}
	database.DB.Create(log)
}

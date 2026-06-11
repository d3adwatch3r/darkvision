package handlers

import (
	"crypto/rand"
	"encoding/hex"
	"time"

	"github.com/darkvision/panel/database"
	"github.com/darkvision/panel/middleware"
	"github.com/darkvision/panel/models"
	"github.com/darkvision/panel/xray"
	"github.com/gofiber/fiber/v2"
	"github.com/google/uuid"
	"go.uber.org/zap"
	"gorm.io/gorm"
)

type UserHandler struct {
	xray *xray.Manager
}

func NewUserHandler(mgr *xray.Manager) *UserHandler {
	return &UserHandler{xray: mgr}
}

// ─────────────────────────────────────────
//  GET /api/v1/users
// ─────────────────────────────────────────

func (h *UserHandler) List(c *fiber.Ctx) error {
	page := c.QueryInt("page", 1)
	limit := c.QueryInt("limit", 50)
	search := c.Query("search")
	status := c.Query("status")

	if limit > 200 {
		limit = 200
	}
	offset := (page - 1) * limit

	q := database.DB.Model(&models.VPNUser{})

	if search != "" {
		q = q.Where("username ILIKE ? OR email ILIKE ?", "%"+search+"%", "%"+search+"%")
	}
	if status != "" {
		q = q.Where("status = ?", status)
	}

	var total int64
	q.Count(&total)

	var users []models.VPNUser
	q.Offset(offset).Limit(limit).
		Order("created_at DESC").
		Find(&users)

	return c.JSON(fiber.Map{
		"users": users,
		"total": total,
		"page":  page,
		"limit": limit,
	})
}

// ─────────────────────────────────────────
//  GET /api/v1/users/:id
// ─────────────────────────────────────────

func (h *UserHandler) Get(c *fiber.Ctx) error {
	id := c.Params("id")
	var user models.VPNUser
	if err := database.DB.Preload("Inbounds.Node").First(&user, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return c.Status(404).JSON(fiber.Map{"error": "user not found"})
		}
		return fiber.ErrInternalServerError
	}
	return c.JSON(user)
}

// ─────────────────────────────────────────
//  POST /api/v1/users
// ─────────────────────────────────────────

type CreateUserRequest struct {
	Username      string     `json:"username"`
	Email         string     `json:"email"`
	TrafficLimit  int64      `json:"traffic_limit"` // байт, 0 = unlimited
	ExpireAt      *time.Time `json:"expire_at"`
	TelegramID    *int64     `json:"telegram_id"`
	Note          string     `json:"note"`
	InboundIDs    []uint     `json:"inbound_ids"` // к каким inbound'ам добавить
}

func (h *UserHandler) Create(c *fiber.Ctx) error {
	claims := middleware.GetClaims(c)

	var req CreateUserRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(400).JSON(fiber.Map{"error": "invalid body"})
	}
	if req.Username == "" {
		return c.Status(400).JSON(fiber.Map{"error": "username is required"})
	}

	// Генерировать sub token
	subBytes := make([]byte, 16)
	rand.Read(subBytes)

	user := &models.VPNUser{
		UUID:         uuid.New(),
		Username:     req.Username,
		Email:        req.Email,
		SubToken:     hex.EncodeToString(subBytes),
		Status:       models.UserStatusActive,
		TrafficLimit: req.TrafficLimit,
		ExpireAt:     req.ExpireAt,
		TelegramID:   req.TelegramID,
		Note:         req.Note,
	}

	if err := database.DB.Create(user).Error; err != nil {
		return c.Status(409).JSON(fiber.Map{"error": "username already exists"})
	}

	// Привязать к inbound'ам и добавить в Xray (горячо)
	if len(req.InboundIDs) > 0 {
		var inbounds []models.Inbound
		database.DB.Find(&inbounds, req.InboundIDs)
		database.DB.Model(user).Association("Inbounds").Append(inbounds)

		// Горячее добавление в Xray — соединения не рвутся
		for _, ib := range inbounds {
			email := user.Username + "@darkvision"
			if err := h.xray.AddUser(ib.Tag, user.UUID.String(), email); err != nil {
				zap.L().Error("xray AddUser failed", zap.String("username", user.Username), zap.Error(err))
				// Не фатально — пользователь создан в БД
			}
		}
	}

	writeAudit(claims.AdminID, "create_user", "vpn_user", user.ID,
		map[string]interface{}{"username": user.Username}, c.IP())

	zap.L().Info("VPN user created", zap.String("username", user.Username))
	return c.Status(201).JSON(user)
}

// ─────────────────────────────────────────
//  PUT /api/v1/users/:id
// ─────────────────────────────────────────

type UpdateUserRequest struct {
	Email        string     `json:"email"`
	Status       string     `json:"status"`
	TrafficLimit int64      `json:"traffic_limit"`
	ExpireAt     *time.Time `json:"expire_at"`
	Note         string     `json:"note"`
}

func (h *UserHandler) Update(c *fiber.Ctx) error {
	claims := middleware.GetClaims(c)
	id := c.Params("id")

	var user models.VPNUser
	if err := database.DB.First(&user, id).Error; err != nil {
		return c.Status(404).JSON(fiber.Map{"error": "user not found"})
	}

	var req UpdateUserRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(400).JSON(fiber.Map{"error": "invalid body"})
	}

	prevStatus := user.Status

	updates := map[string]interface{}{
		"email":         req.Email,
		"traffic_limit": req.TrafficLimit,
		"expire_at":     req.ExpireAt,
		"note":          req.Note,
	}
	if req.Status != "" {
		updates["status"] = req.Status
	}

	database.DB.Model(&user).Updates(updates)

	// Если статус изменился — синхронизировать с Xray
	newStatus := models.UserStatus(req.Status)
	if req.Status != "" && newStatus != prevStatus {
		h.syncUserStatusToXray(&user, newStatus)
	}

	writeAudit(claims.AdminID, "update_user", "vpn_user", user.ID,
		map[string]interface{}{"username": user.Username, "status": req.Status}, c.IP())

	return c.JSON(user)
}

// ─────────────────────────────────────────
//  DELETE /api/v1/users/:id
// ─────────────────────────────────────────

func (h *UserHandler) Delete(c *fiber.Ctx) error {
	claims := middleware.GetClaims(c)
	id := c.Params("id")

	var user models.VPNUser
	if err := database.DB.Preload("Inbounds").First(&user, id).Error; err != nil {
		return c.Status(404).JSON(fiber.Map{"error": "user not found"})
	}

	// Удалить из Xray (горячо)
	email := user.Username + "@darkvision"
	for _, ib := range user.Inbounds {
		if err := h.xray.RemoveUser(ib.Tag, email); err != nil {
			zap.L().Warn("xray RemoveUser failed", zap.String("tag", ib.Tag), zap.Error(err))
		}
	}

	database.DB.Delete(&user)

	writeAudit(claims.AdminID, "delete_user", "vpn_user", user.ID,
		map[string]interface{}{"username": user.Username}, c.IP())

	return c.JSON(fiber.Map{"message": "user deleted"})
}

// ─────────────────────────────────────────
//  POST /api/v1/users/:id/reset-traffic
// ─────────────────────────────────────────

func (h *UserHandler) ResetTraffic(c *fiber.Ctx) error {
	id := c.Params("id")
	var user models.VPNUser
	if err := database.DB.First(&user, id).Error; err != nil {
		return c.Status(404).JSON(fiber.Map{"error": "user not found"})
	}
	database.DB.Model(&user).Update("traffic_used", 0)
	return c.JSON(fiber.Map{"message": "traffic reset"})
}

// ─────────────────────────────────────────
//  POST /api/v1/users/:id/revoke-sub
//  Перевыдать ссылку подписки
// ─────────────────────────────────────────

func (h *UserHandler) RevokeSub(c *fiber.Ctx) error {
	id := c.Params("id")
	var user models.VPNUser
	if err := database.DB.First(&user, id).Error; err != nil {
		return c.Status(404).JSON(fiber.Map{"error": "user not found"})
	}

	newBytes := make([]byte, 16)
	rand.Read(newBytes)
	newToken := hex.EncodeToString(newBytes)
	database.DB.Model(&user).Update("sub_token", newToken)
	user.SubToken = newToken

	return c.JSON(user)
}

// ─────────────────────────────────────────
//  Helpers
// ─────────────────────────────────────────

func (h *UserHandler) syncUserStatusToXray(user *models.VPNUser, newStatus models.UserStatus) {
	var inbounds []models.Inbound
	database.DB.Model(user).Association("Inbounds").Find(&inbounds)

	email := user.Username + "@darkvision"
	tags := make([]string, 0, len(inbounds))
	for _, ib := range inbounds {
		tags = append(tags, ib.Tag)
	}

	switch newStatus {
	case models.UserStatusDisabled, models.UserStatusExpired:
		// Удалить из Xray — клиент больше не сможет подключиться
		h.xray.RemoveUserFromAllInbounds(tags, email)
		zap.L().Info("user disabled in xray", zap.String("user", user.Username))

	case models.UserStatusActive:
		// Добавить обратно в Xray
		h.xray.AddUserToAllInbounds(tags, user.UUID.String(), email)
		zap.L().Info("user re-enabled in xray", zap.String("user", user.Username))
	}
}

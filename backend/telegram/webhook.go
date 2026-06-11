package telegram

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/darkvision/panel/config"
	"github.com/darkvision/panel/database"
	"github.com/darkvision/panel/models"
	"github.com/gofiber/fiber/v2"
	"go.uber.org/zap"
)

type Handler struct {
	cfg *config.Config
}

func NewHandler(cfg *config.Config) *Handler {
	return &Handler{cfg: cfg}
}

// POST /api/v1/telegram/webhook
// Принимает события от DarkVPN Telegram бота после успешной оплаты
func (h *Handler) Webhook(c *fiber.Ctx) error {
	// Проверить secret токен (передаётся ботом в заголовке)
	secret := c.Get("X-Telegram-Bot-Api-Secret-Token")
	if h.cfg.TelegramWebhookSecret != "" && secret != h.cfg.TelegramWebhookSecret {
		zap.L().Warn("telegram webhook: invalid secret", zap.String("ip", c.IP()))
		return c.Status(401).JSON(fiber.Map{"error": "unauthorized"})
	}

	var update TelegramUpdate
	if err := c.BodyParser(&update); err != nil {
		return c.Status(400).JSON(fiber.Map{"error": "invalid body"})
	}

	// Оплата через Telegram Payments
	if update.Message != nil && update.Message.SuccessfulPayment != nil {
		return h.handlePaymentSuccess(c, update.Message)
	}

	// pre_checkout подтверждение
	if update.PreCheckoutQuery != nil {
		zap.L().Info("pre_checkout_query", zap.Int64("user", int64(update.PreCheckoutQuery.From.ID)))
		return c.JSON(fiber.Map{"ok": true})
	}

	// callback_query от инлайн кнопок
	if update.CallbackQuery != nil {
		zap.L().Info("callback_query", zap.String("data", update.CallbackQuery.Data))
		return c.JSON(fiber.Map{"ok": true})
	}

	return c.JSON(fiber.Map{"ok": true})
}

// handlePaymentSuccess — создать/продлить подписку после оплаты
func (h *Handler) handlePaymentSuccess(c *fiber.Ctx, msg *TelegramMessage) error {
	payment := msg.SuccessfulPayment
	telegramID := int64(msg.From.ID)

	zap.L().Info("payment success",
		zap.Int64("telegram_id", telegramID),
		zap.String("payload", payment.InvoicePayload),
		zap.Int("amount", payment.TotalAmount),
	)

	// Декодировать payload: {"type":"days","value":30}
	var payload PaymentPayload
	if err := json.Unmarshal([]byte(payment.InvoicePayload), &payload); err != nil {
		zap.L().Error("invalid payment payload", zap.String("raw", payment.InvoicePayload), zap.Error(err))
		return c.JSON(fiber.Map{"ok": true})
	}

	// Найти или создать VPN пользователя по Telegram ID
	var user models.VPNUser
	err := database.DB.Where("telegram_id = ?", telegramID).First(&user).Error

	if err != nil {
		// Новый пользователь — создать автоматически
		username := fmt.Sprintf("tg_%d", telegramID)
		user = models.VPNUser{
			Username:   username,
			TelegramID: &telegramID,
			Status:     models.UserStatusActive,
		}
		if createErr := database.DB.Create(&user).Error; createErr != nil {
			zap.L().Error("failed to create user from telegram",
				zap.Int64("tg_id", telegramID), zap.Error(createErr))
			return c.JSON(fiber.Map{"ok": true})
		}
		zap.L().Info("auto-created vpn user", zap.String("username", username))
	}

	// Применить тариф
	now := time.Now().UTC()
	updates := map[string]interface{}{"status": models.UserStatusActive}

	switch payload.Type {
	case "days":
		var baseTime time.Time
		if user.ExpireAt == nil || user.ExpireAt.Before(now) {
			baseTime = now
		} else {
			baseTime = *user.ExpireAt
		}
		newExpire := baseTime.AddDate(0, 0, payload.Value)
		updates["expire_at"] = newExpire
		zap.L().Info("subscription extended",
			zap.Int64("tg_id", telegramID), zap.Int("days", payload.Value),
			zap.Time("new_expire", newExpire))

	case "gb":
		addBytes := int64(payload.Value) * 1024 * 1024 * 1024
		updates["traffic_limit"] = user.TrafficLimit + addBytes
		zap.L().Info("traffic added",
			zap.Int64("tg_id", telegramID), zap.Int("gb", payload.Value))
	}

	database.DB.Model(&user).Updates(updates)

	// Логируем событие в audit
	database.DB.Create(&models.AuditLog{
		Action:     "telegram_payment",
		TargetType: "vpn_user",
		TargetID:   &user.ID,
		Details: models.JSONB{
			"telegram_id": telegramID,
			"payload":     payload,
			"amount":      payment.TotalAmount,
		},
	})

	// Отправить ссылку подписки пользователю
	subURL := fmt.Sprintf("%s/%s", h.cfg.SubBaseURL, user.SubToken)
	go h.sendMessage(telegramID, fmt.Sprintf(
		"✅ Подписка активирована!\n\n"+
			"👤 %s\n\n"+
			"📱 Ссылка подписки:\n%s\n\n"+
			"Скопируй и вставь в Hiddify / v2rayNG",
		user.Username, subURL,
	))

	return c.JSON(fiber.Map{"ok": true})
}

// sendMessage — отправить сообщение пользователю через Bot API
func (h *Handler) sendMessage(chatID int64, text string) {
	if h.cfg.TelegramBotToken == "" {
		return
	}
	// TODO: использовать http.Post с retry logic
	zap.L().Info("telegram send message", zap.Int64("chat_id", chatID))
}

// ─────────────────────────────────────────
//  Telegram типы
// ─────────────────────────────────────────

type TelegramUpdate struct {
	UpdateID         int               `json:"update_id"`
	Message          *TelegramMessage  `json:"message,omitempty"`
	CallbackQuery    *CallbackQuery    `json:"callback_query,omitempty"`
	PreCheckoutQuery *PreCheckoutQuery `json:"pre_checkout_query,omitempty"`
}

type TelegramMessage struct {
	MessageID         int                `json:"message_id"`
	From              *TelegramUser      `json:"from"`
	Chat              TelegramChat       `json:"chat"`
	Text              string             `json:"text,omitempty"`
	SuccessfulPayment *SuccessfulPayment `json:"successful_payment,omitempty"`
}

type TelegramUser struct {
	ID        int    `json:"id"`
	FirstName string `json:"first_name"`
	Username  string `json:"username"`
}

type TelegramChat struct {
	ID int64 `json:"id"`
}

type CallbackQuery struct {
	ID   string       `json:"id"`
	From TelegramUser `json:"from"`
	Data string       `json:"data"`
}

type PreCheckoutQuery struct {
	ID      string       `json:"id"`
	From    TelegramUser `json:"from"`
	Payload string       `json:"invoice_payload"`
}

type SuccessfulPayment struct {
	Currency       string `json:"currency"`
	TotalAmount    int    `json:"total_amount"`
	InvoicePayload string `json:"invoice_payload"`
}

type PaymentPayload struct {
	Type  string `json:"type"`  // "days" или "gb"
	Value int    `json:"value"` // количество
}

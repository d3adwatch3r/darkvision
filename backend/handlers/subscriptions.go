package handlers

import (
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/darkvision/panel/config"
	"github.com/darkvision/panel/database"
	"github.com/darkvision/panel/models"
	"github.com/darkvision/panel/xray"
	"github.com/gofiber/fiber/v2"
	"gorm.io/gorm"
)

type SubHandler struct {
	cfg *config.Config
}

func NewSubHandler(cfg *config.Config) *SubHandler {
	return &SubHandler{cfg: cfg}
}

// ─────────────────────────────────────────
//  GET /sub/:token
//  Публичный — отдаёт base64 список ссылок
//  Поддерживает ?format=v2ray|clash|singbox
// ─────────────────────────────────────────

func (h *SubHandler) GetSubscription(c *fiber.Ctx) error {
	token := c.Params("token")
	if token == "" {
		return c.Status(404).SendString("not found")
	}

	var user models.VPNUser
	err := database.DB.Preload("Inbounds.Node").
		Where("sub_token = ?", token).
		First(&user).Error
	if err != nil {
		if err == gorm.ErrRecordNotFound {
			return c.Status(404).SendString("not found")
		}
		return c.Status(500).SendString("error")
	}

	// Проверка статуса
	if user.Status != models.UserStatusActive {
		return c.Status(403).SendString("subscription inactive")
	}

	format := c.Query("format", "v2ray")

	switch format {
	case "v2ray", "":
		return h.serveV2Ray(c, &user)
	case "clash":
		return h.serveClash(c, &user)
	case "singbox":
		return h.serveSingbox(c, &user)
	default:
		return h.serveV2Ray(c, &user)
	}
}

// ─────────────────────────────────────────
//  V2Ray / Base64 формат
// ─────────────────────────────────────────

func (h *SubHandler) serveV2Ray(c *fiber.Ctx, user *models.VPNUser) error {
	var links []string

	for _, ib := range user.Inbounds {
		if !ib.Enabled || ib.Node == nil {
			continue
		}
		if ib.Node.Status != models.NodeStatusOnline {
			continue
		}

		link := xray.BuildVLESSLink(xray.VLESSLinkParams{
			UUID:        user.UUID.String(),
			Host:        ib.Node.Host,
			Port:        ib.Port,
			PublicKey:   ib.RealityPBK,
			ShortID:     ib.RealitySID,
			SNI:         ib.SNI,
			Fingerprint: ib.Fingerprint,
			Flow:        ib.Flow,
			Remark:      fmt.Sprintf("DarkVision-%s", ib.Node.Name),
		})
		links = append(links, link)
	}

	if len(links) == 0 {
		return c.Status(404).SendString("no active nodes")
	}

	raw := strings.Join(links, "\n")
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))

	c.Set("Content-Type", "text/plain; charset=utf-8")
	c.Set("Content-Disposition", fmt.Sprintf(`attachment; filename="darkvision_%s.txt"`, user.Username))
	c.Set("Profile-Update-Interval", "12")  // клиент обновляет каждые 12 часов
	c.Set("Subscription-Userinfo",
		fmt.Sprintf("upload=%d; download=%d; total=%d",
			0, user.TrafficUsed, user.TrafficLimit))

	return c.SendString(encoded)
}

// ─────────────────────────────────────────
//  Clash YAML формат
// ─────────────────────────────────────────

func (h *SubHandler) serveClash(c *fiber.Ctx, user *models.VPNUser) error {
	var proxies []string
	var proxyNames []string

	for _, ib := range user.Inbounds {
		if !ib.Enabled || ib.Node == nil {
			continue
		}
		if ib.Node.Status != models.NodeStatusOnline {
			continue
		}

		name := fmt.Sprintf("DarkVision-%s", ib.Node.Name)
		proxyNames = append(proxyNames, name)

		proxy := fmt.Sprintf(`  - name: "%s"
    type: vless
    server: %s
    port: %d
    uuid: %s
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    reality-opts:
      public-key: %s
      short-id: %s
    servername: %s
    client-fingerprint: %s`,
			name, ib.Node.Host, ib.Port,
			user.UUID.String(),
			ib.RealityPBK, ib.RealitySID,
			ib.SNI, ib.Fingerprint)

		proxies = append(proxies, proxy)
	}

	namesYAML := "    - " + strings.Join(proxyNames, "\n    - ")
	proxiesYAML := strings.Join(proxies, "\n")

	yaml := fmt.Sprintf(`mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
external-controller: 127.0.0.1:9090

dns:
  enable: true
  nameserver:
    - 8.8.8.8
    - 1.1.1.1

proxies:
%s

proxy-groups:
  - name: DarkVision
    type: select
    proxies:
%s

rules:
  - MATCH,DarkVision
`, proxiesYAML, namesYAML)

	c.Set("Content-Type", "text/yaml; charset=utf-8")
	c.Set("Content-Disposition", fmt.Sprintf(`attachment; filename="darkvision_%s.yaml"`, user.Username))
	return c.SendString(yaml)
}

// ─────────────────────────────────────────
//  Sing-box формат
// ─────────────────────────────────────────

func (h *SubHandler) serveSingbox(c *fiber.Ctx, user *models.VPNUser) error {
	var outbounds []string

	for _, ib := range user.Inbounds {
		if !ib.Enabled || ib.Node == nil {
			continue
		}
		outbound := fmt.Sprintf(`{
      "type": "vless",
      "tag": "DarkVision-%s",
      "server": "%s",
      "server_port": %d,
      "uuid": "%s",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "%s",
        "utls": { "enabled": true, "fingerprint": "%s" },
        "reality": {
          "enabled": true,
          "public_key": "%s",
          "short_id": "%s"
        }
      }
    }`,
			ib.Node.Name,
			ib.Node.Host, ib.Port,
			user.UUID.String(),
			ib.SNI, ib.Fingerprint,
			ib.RealityPBK, ib.RealitySID)

		outbounds = append(outbounds, outbound)
	}

	json := fmt.Sprintf(`{
  "log": { "level": "info" },
  "dns": {
    "servers": [
      { "tag": "google", "address": "8.8.8.8" }
    ]
  },
  "inbounds": [
    { "type": "tun", "tag": "tun-in", "inet4_address": "172.19.0.1/30", "auto_route": true }
  ],
  "outbounds": [
    %s,
    { "type": "direct", "tag": "direct" }
  ]
}`, strings.Join(outbounds, ",\n    "))

	c.Set("Content-Type", "application/json; charset=utf-8")
	c.Set("Content-Disposition", fmt.Sprintf(`attachment; filename="darkvision_%s.json"`, user.Username))
	return c.SendString(json)
}

// ─────────────────────────────────────────
//  GET /api/v1/users/:id/sub-link
//  Получить ссылку подписки (для панели)
// ─────────────────────────────────────────

func (h *SubHandler) GetSubLink(c *fiber.Ctx) error {
	var user models.VPNUser
	if err := database.DB.First(&user, c.Params("id")).Error; err != nil {
		return c.Status(404).JSON(fiber.Map{"error": "user not found"})
	}

	subURL := fmt.Sprintf("%s/%s", h.cfg.SubBaseURL, user.SubToken)

	return c.JSON(fiber.Map{
		"sub_url":      subURL,
		"sub_url_v2ray": subURL + "?format=v2ray",
		"sub_url_clash": subURL + "?format=clash",
		"sub_url_sing":  subURL + "?format=singbox",
	})
}

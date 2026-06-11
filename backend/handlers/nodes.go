package handlers

import (
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/darkvision/panel/database"
	"github.com/darkvision/panel/middleware"
	"github.com/darkvision/panel/models"
	"github.com/gofiber/fiber/v2"
	"go.uber.org/zap"
	"gorm.io/gorm"
)

type NodeHandler struct{}

func NewNodeHandler() *NodeHandler { return &NodeHandler{} }

// GET /api/v1/nodes
func (h *NodeHandler) List(c *fiber.Ctx) error {
	var nodes []models.Node
	database.DB.Preload("Inbounds").Order("created_at ASC").Find(&nodes)
	return c.JSON(nodes)
}

// GET /api/v1/nodes/:id
func (h *NodeHandler) Get(c *fiber.Ctx) error {
	var node models.Node
	if err := database.DB.Preload("Inbounds").First(&node, c.Params("id")).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			return c.Status(404).JSON(fiber.Map{"error": "node not found"})
		}
		return fiber.ErrInternalServerError
	}
	return c.JSON(node)
}

// POST /api/v1/nodes
type CreateNodeRequest struct {
	Name        string `json:"name"`
	Host        string `json:"host"`
	Port        int    `json:"port"`
	AgentPort   int    `json:"agent_port"`
	AgentSecret string `json:"agent_secret"`
}

func (h *NodeHandler) Create(c *fiber.Ctx) error {
	claims := middleware.GetClaims(c)
	var req CreateNodeRequest
	if err := c.BodyParser(&req); err != nil {
		return c.Status(400).JSON(fiber.Map{"error": "invalid body"})
	}
	if req.Name == "" || req.Host == "" {
		return c.Status(400).JSON(fiber.Map{"error": "name and host required"})
	}
	if req.Port == 0 { req.Port = 443 }
	if req.AgentPort == 0 { req.AgentPort = 2095 }

	node := &models.Node{
		Name:        req.Name,
		Host:        req.Host,
		Port:        req.Port,
		AgentPort:   req.AgentPort,
		AgentSecret: req.AgentSecret,
		Status:      models.NodeStatusOffline,
	}
	database.DB.Create(node)

	writeAudit(claims.AdminID, "create_node", "node", node.ID,
		map[string]interface{}{"name": node.Name, "host": node.Host}, c.IP())

	return c.Status(201).JSON(node)
}

// PUT /api/v1/nodes/:id
type UpdateNodeRequest struct {
	Name        string `json:"name"`
	Host        string `json:"host"`
	Port        int    `json:"port"`
	AgentPort   int    `json:"agent_port"`
	AgentSecret string `json:"agent_secret"`
}

func (h *NodeHandler) Update(c *fiber.Ctx) error {
	claims := middleware.GetClaims(c)
	var node models.Node
	if err := database.DB.First(&node, c.Params("id")).Error; err != nil {
		return c.Status(404).JSON(fiber.Map{"error": "node not found"})
	}

	var req UpdateNodeRequest
	c.BodyParser(&req)

	updates := map[string]interface{}{}
	if req.Name != ""        { updates["name"] = req.Name }
	if req.Host != ""        { updates["host"] = req.Host }
	if req.Port != 0         { updates["port"] = req.Port }
	if req.AgentPort != 0    { updates["agent_port"] = req.AgentPort }
	if req.AgentSecret != "" { updates["agent_secret"] = req.AgentSecret }

	database.DB.Model(&node).Updates(updates)

	writeAudit(claims.AdminID, "update_node", "node", node.ID, nil, c.IP())
	return c.JSON(node)
}

// DELETE /api/v1/nodes/:id
func (h *NodeHandler) Delete(c *fiber.Ctx) error {
	claims := middleware.GetClaims(c)
	var node models.Node
	if err := database.DB.First(&node, c.Params("id")).Error; err != nil {
		return c.Status(404).JSON(fiber.Map{"error": "node not found"})
	}
	database.DB.Delete(&node)

	writeAudit(claims.AdminID, "delete_node", "node", node.ID,
		map[string]interface{}{"name": node.Name}, c.IP())

	return c.JSON(fiber.Map{"message": "node deleted"})
}

// GET /api/v1/nodes/:id/status — пинг агента на ноде
func (h *NodeHandler) Status(c *fiber.Ctx) error {
	var node models.Node
	if err := database.DB.First(&node, c.Params("id")).Error; err != nil {
		return c.Status(404).JSON(fiber.Map{"error": "node not found"})
	}

	status := pingAgent(node)

	// Обновить статус в БД
	database.DB.Model(&node).Updates(map[string]interface{}{
		"status":     status.Status,
		"updated_at": time.Now().UTC(),
	})

	return c.JSON(status)
}

// ─────────────────────────────────────────
//  Node Agent ping
// ─────────────────────────────────────────

type AgentStatus struct {
	Status      models.NodeStatus `json:"status"`
	XrayVersion string            `json:"xray_version"`
	Uptime      int64             `json:"uptime_seconds"`
	Load        float64           `json:"load_1m"`
	TrafficUp   int64             `json:"traffic_up"`
	TrafficDown int64             `json:"traffic_down"`
	Error       string            `json:"error,omitempty"`
}

func pingAgent(node models.Node) AgentStatus {
	url := fmt.Sprintf("http://%s:%d/status", node.Host, node.AgentPort)

	client := &http.Client{Timeout: 5 * time.Second}
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("X-Agent-Secret", node.AgentSecret)

	resp, err := client.Do(req)
	if err != nil {
		zap.L().Warn("node agent unreachable", zap.String("host", node.Host), zap.Error(err))
		return AgentStatus{Status: models.NodeStatusOffline, Error: err.Error()}
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return AgentStatus{Status: models.NodeStatusError, Error: fmt.Sprintf("agent returned %d", resp.StatusCode)}
	}

	body, _ := io.ReadAll(resp.Body)
	_ = body
	// В реальности парсим JSON от агента, здесь упрощено
	return AgentStatus{Status: models.NodeStatusOnline}
}

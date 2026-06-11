package handlers

import (
	"time"

	"github.com/darkvision/panel/database"
	"github.com/darkvision/panel/models"
	"github.com/gofiber/fiber/v2"
)

type StatsHandler struct{}

func NewStatsHandler() *StatsHandler { return &StatsHandler{} }

// GET /api/v1/stats
func (h *StatsHandler) Dashboard(c *fiber.Ctx) error {
	// Пользователи по статусам
	var totalUsers, activeUsers, expiredUsers, disabledUsers int64
	database.DB.Model(&models.VPNUser{}).Count(&totalUsers)
	database.DB.Model(&models.VPNUser{}).Where("status = 'active'").Count(&activeUsers)
	database.DB.Model(&models.VPNUser{}).Where("status = 'expired'").Count(&expiredUsers)
	database.DB.Model(&models.VPNUser{}).Where("status = 'disabled'").Count(&disabledUsers)

	// Истекают в ближайшие 7 дней
	var expiresoon int64
	database.DB.Model(&models.VPNUser{}).
		Where("status = 'active' AND expire_at IS NOT NULL AND expire_at <= ?",
			time.Now().AddDate(0, 0, 7)).
		Count(&expiresoon)

	// Ноды
	var totalNodes, onlineNodes int64
	database.DB.Model(&models.Node{}).Count(&totalNodes)
	database.DB.Model(&models.Node{}).Where("status = 'online'").Count(&onlineNodes)

	// Трафик за сегодня
	var todayUp, todayDown int64
	today := time.Now().UTC().Truncate(24 * time.Hour)
	database.DB.Model(&models.TrafficLog{}).
		Where("logged_at >= ?", today).
		Select("COALESCE(SUM(upload),0)").Scan(&todayUp)
	database.DB.Model(&models.TrafficLog{}).
		Where("logged_at >= ?", today).
		Select("COALESCE(SUM(download),0)").Scan(&todayDown)

	// Трафик за 7 дней
	var weekUp, weekDown int64
	week := time.Now().UTC().AddDate(0, 0, -7)
	database.DB.Model(&models.TrafficLog{}).
		Where("logged_at >= ?", week).
		Select("COALESCE(SUM(upload),0)").Scan(&weekUp)
	database.DB.Model(&models.TrafficLog{}).
		Where("logged_at >= ?", week).
		Select("COALESCE(SUM(download),0)").Scan(&weekDown)

	// Топ-5 пользователей по трафику
	type TopUser struct {
		Username string `json:"username"`
		Traffic  int64  `json:"traffic"`
	}
	var topUsers []TopUser
	database.DB.Raw(`
		SELECT v.username, (v.traffic_used) as traffic
		FROM vpn_users v
		ORDER BY traffic DESC
		LIMIT 5
	`).Scan(&topUsers)

	// График трафика за 7 дней
	type DayTraffic struct {
		Day      string `json:"day"`
		Upload   int64  `json:"upload"`
		Download int64  `json:"download"`
	}
	var trafficChart []DayTraffic
	database.DB.Raw(`
		SELECT
			TO_CHAR(DATE_TRUNC('day', logged_at), 'YYYY-MM-DD') AS day,
			COALESCE(SUM(upload), 0) AS upload,
			COALESCE(SUM(download), 0) AS download
		FROM traffic_logs
		WHERE logged_at >= NOW() - INTERVAL '7 days'
		GROUP BY DATE_TRUNC('day', logged_at)
		ORDER BY day ASC
	`).Scan(&trafficChart)

	return c.JSON(fiber.Map{
		"users": fiber.Map{
			"total":      totalUsers,
			"active":     activeUsers,
			"expired":    expiredUsers,
			"disabled":   disabledUsers,
			"expireSoon": expiresoon,
		},
		"nodes": fiber.Map{
			"total":  totalNodes,
			"online": onlineNodes,
		},
		"traffic": fiber.Map{
			"today_up":    todayUp,
			"today_down":  todayDown,
			"week_up":     weekUp,
			"week_down":   weekDown,
		},
		"top_users":     topUsers,
		"traffic_chart": trafficChart,
	})
}

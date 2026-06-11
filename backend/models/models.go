package models

import (
	"database/sql/driver"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// ─────────────────────────────────────────
//  JSONB helper
// ─────────────────────────────────────────

type JSONB map[string]interface{}

func (j JSONB) Value() (driver.Value, error) {
	b, err := json.Marshal(j)
	return string(b), err
}

func (j *JSONB) Scan(value interface{}) error {
	switch v := value.(type) {
	case []byte:
		return json.Unmarshal(v, j)
	case string:
		return json.Unmarshal([]byte(v), j)
	}
	return fmt.Errorf("cannot scan type %T into JSONB", value)
}

// ─────────────────────────────────────────
//  Admin
// ─────────────────────────────────────────

type Admin struct {
	ID           uint       `gorm:"primaryKey" json:"id"`
	Username     string     `gorm:"uniqueIndex;size:50;not null" json:"username"`
	PasswordHash string     `gorm:"size:255;not null" json:"-"`
	IsSuper      bool       `gorm:"default:false" json:"is_super"`
	CreatedAt    time.Time  `json:"created_at"`
	LastLogin    *time.Time `json:"last_login,omitempty"`
}

// ─────────────────────────────────────────
//  Session (refresh tokens)
// ─────────────────────────────────────────

type Session struct {
	ID           uint      `gorm:"primaryKey" json:"-"`
	AdminID      uint      `gorm:"index;not null" json:"-"`
	RefreshToken string    `gorm:"uniqueIndex;size:512;not null" json:"-"`
	IPAddress    string    `gorm:"type:inet" json:"ip_address"`
	UserAgent    string    `json:"-"`
	ExpiresAt    time.Time `json:"expires_at"`
	CreatedAt    time.Time `json:"created_at"`
}

// ─────────────────────────────────────────
//  Node
// ─────────────────────────────────────────

type NodeStatus string

const (
	NodeStatusOnline  NodeStatus = "online"
	NodeStatusOffline NodeStatus = "offline"
	NodeStatusError   NodeStatus = "error"
)

type Node struct {
	ID            uint       `gorm:"primaryKey" json:"id"`
	Name          string     `gorm:"size:100;not null" json:"name"`
	Host          string     `gorm:"size:255;not null" json:"host"`
	Port          int        `gorm:"default:443" json:"port"`
	AgentPort     int        `gorm:"default:2095" json:"agent_port"`
	AgentSecret   string     `gorm:"size:255;not null" json:"-"`
	Status        NodeStatus `gorm:"size:20;default:'offline'" json:"status"`
	XrayVersion   string     `gorm:"size:50" json:"xray_version"`
	UptimeSeconds int64      `gorm:"default:0" json:"uptime_seconds"`
	Load1m        float64    `gorm:"default:0" json:"load_1m"`
	TrafficUp     int64      `gorm:"default:0" json:"traffic_up"`
	TrafficDown   int64      `gorm:"default:0" json:"traffic_down"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`

	Inbounds []Inbound `gorm:"foreignKey:NodeID" json:"inbounds,omitempty"`
}

// ─────────────────────────────────────────
//  Inbound
// ─────────────────────────────────────────

type Inbound struct {
	ID             uint      `gorm:"primaryKey" json:"id"`
	NodeID         uint      `gorm:"index;not null" json:"node_id"`
	Tag            string    `gorm:"size:100;not null" json:"tag"`
	Protocol       string    `gorm:"size:50;not null" json:"protocol"`
	Port           int       `gorm:"not null" json:"port"`
	Network        string    `gorm:"size:50;default:'tcp'" json:"network"`
	Security       string    `gorm:"size:50;default:'reality'" json:"security"`
	RealityPBK     string    `gorm:"size:255" json:"reality_pbk"`
	RealitySID     string    `gorm:"size:100" json:"reality_sid"`
	SNI            string    `gorm:"size:255" json:"sni"`
	Fingerprint    string    `gorm:"size:50;default:'chrome'" json:"fingerprint"`
	Flow           string    `gorm:"size:100;default:'xtls-rprx-vision'" json:"flow"`
	Settings       JSONB     `gorm:"type:jsonb;default:'{}'" json:"settings"`
	StreamSettings JSONB     `gorm:"type:jsonb;default:'{}'" json:"stream_settings"`
	Enabled        bool      `gorm:"default:true" json:"enabled"`
	CreatedAt      time.Time `json:"created_at"`

	Node *Node `gorm:"foreignKey:NodeID" json:"node,omitempty"`
}

// ─────────────────────────────────────────
//  VPN User
// ─────────────────────────────────────────

type UserStatus string

const (
	UserStatusActive   UserStatus = "active"
	UserStatusDisabled UserStatus = "disabled"
	UserStatusExpired  UserStatus = "expired"
)

type VPNUser struct {
	ID           uint       `gorm:"primaryKey" json:"id"`
	UUID         uuid.UUID  `gorm:"type:uuid;uniqueIndex;default:gen_random_uuid()" json:"uuid"`
	Username     string     `gorm:"size:100;uniqueIndex;not null" json:"username"`
	Email        string     `gorm:"size:255" json:"email,omitempty"`
	SubToken     string     `gorm:"size:64;uniqueIndex;not null" json:"sub_token"`
	Status       UserStatus `gorm:"size:20;default:'active'" json:"status"`
	TrafficLimit int64      `gorm:"default:0" json:"traffic_limit"`  // 0 = unlimited
	TrafficUsed  int64      `gorm:"default:0" json:"traffic_used"`
	ExpireAt     *time.Time `json:"expire_at,omitempty"`
	TelegramID   *int64     `gorm:"index" json:"telegram_id,omitempty"`
	Note         string     `json:"note,omitempty"`
	CreatedAt    time.Time  `json:"created_at"`
	UpdatedAt    time.Time  `json:"updated_at"`

	Inbounds []Inbound `gorm:"many2many:user_inbounds;" json:"inbounds,omitempty"`
}

// ─────────────────────────────────────────
//  Traffic log
// ─────────────────────────────────────────

type TrafficLog struct {
	ID       uint       `gorm:"primaryKey"`
	UserID   *uint      `gorm:"index"`
	NodeID   *uint      `gorm:"index"`
	Upload   int64      `gorm:"default:0"`
	Download int64      `gorm:"default:0"`
	LoggedAt time.Time  `gorm:"index"`
}

// ─────────────────────────────────────────
//  Audit log
// ─────────────────────────────────────────

type AuditLog struct {
	ID         uint      `gorm:"primaryKey"`
	AdminID    *uint     `gorm:"index"`
	Action     string    `gorm:"size:100;not null"`
	TargetType string    `gorm:"size:50"`
	TargetID   *uint
	Details    JSONB     `gorm:"type:jsonb"`
	IPAddress  string    `gorm:"type:inet"`
	CreatedAt  time.Time `gorm:"index"`
}

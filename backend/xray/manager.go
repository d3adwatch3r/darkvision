package xray

// DarkVision — Xray gRPC Manager
// Горячее добавление/удаление VPN пользователей через HandlerService.AlterInbound
// Соединения существующих клиентов НЕ разрываются.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/xtls/xray-core/app/proxyman/command"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	vlessproxy "github.com/xtls/xray-core/proxy/vless"
	statsCommand "github.com/xtls/xray-core/app/stats/command"
	"go.uber.org/zap"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"
)

// Manager управляет Xray через gRPC
type Manager struct {
	mu         sync.RWMutex
	conn       *grpc.ClientConn
	handler    command.HandlerServiceClient
	stats      statsCommand.StatsServiceClient
	apiHost    string
	apiPort    int
	configPath string
}

// NewManager — создать менеджер и установить gRPC соединение
func NewManager(host string, port int) (*Manager, error) {
	m := &Manager{
		apiHost:    host,
		apiPort:    port,
		configPath: os.Getenv("XRAY_CONFIG_PATH"),
	}
	if err := m.connect(); err != nil {
		return m, err // возвращаем менеджер даже при ошибке — переподключится позже
	}
	return m, nil
}

func (m *Manager) connect() error {
	addr := fmt.Sprintf("%s:%d", m.apiHost, m.apiPort)

	conn, err := grpc.NewClient(addr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithKeepaliveParams(keepalive.ClientParameters{
			Time:                10 * time.Second,
			Timeout:             5 * time.Second,
			PermitWithoutStream: true,
		}),
	)
	if err != nil {
		return fmt.Errorf("xray grpc dial %s: %w", addr, err)
	}

	m.mu.Lock()
	m.conn = conn
	m.handler = command.NewHandlerServiceClient(conn)
	m.stats = statsCommand.NewStatsServiceClient(conn)
	m.mu.Unlock()

	zap.L().Info("Xray gRPC connected", zap.String("addr", addr))
	return nil
}

// reconnect — переподключиться при обрыве
func (m *Manager) reconnect() {
	for {
		time.Sleep(5 * time.Second)
		zap.L().Warn("Xray gRPC reconnecting...")
		if err := m.connect(); err == nil {
			return
		}
	}
}

// ─────────────────────────────────────────
//  Горячее управление пользователями
// ─────────────────────────────────────────

// AddUser — добавить пользователя в inbound БЕЗ перезапуска Xray
// inboundTag — тег inbound'а из xray config (напр. "vless-reality")
// userUUID  — UUID пользователя
// email     — уникальный email (используется как идентификатор в Xray)
func (m *Manager) AddUser(inboundTag, userUUID, email string) error {
	m.mu.RLock()
	handler := m.handler
	m.mu.RUnlock()

	if handler == nil {
		return fmt.Errorf("xray handler not connected")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err := handler.AlterInbound(ctx, &command.AlterInboundRequest{
		Tag: inboundTag,
		Operation: serial.ToTypedMessage(&command.AddUserOperation{
			User: &protocol.User{
				Level: 0,
				Email: email,
				Account: serial.ToTypedMessage(&vlessproxy.Account{
					Id:   userUUID,
					Flow: "xtls-rprx-vision",
				}),
			},
		}),
	})
	if err != nil {
		zap.L().Error("xray AddUser failed", zap.String("tag", inboundTag), zap.String("uuid", userUUID), zap.Error(err))
		// grpc error — попробуем переподключиться
		go m.reconnect()
		return fmt.Errorf("xray add user: %w", err)
	}

	zap.L().Info("xray user added", zap.String("tag", inboundTag), zap.String("email", email))
	return nil
}

// RemoveUser — удалить пользователя из inbound БЕЗ перезапуска Xray
func (m *Manager) RemoveUser(inboundTag, email string) error {
	m.mu.RLock()
	handler := m.handler
	m.mu.RUnlock()

	if handler == nil {
		return fmt.Errorf("xray handler not connected")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	_, err := handler.AlterInbound(ctx, &command.AlterInboundRequest{
		Tag: inboundTag,
		Operation: serial.ToTypedMessage(&command.RemoveUserOperation{
			Email: email,
		}),
	})
	if err != nil {
		zap.L().Error("xray RemoveUser failed", zap.String("tag", inboundTag), zap.String("email", email), zap.Error(err))
		go m.reconnect()
		return fmt.Errorf("xray remove user: %w", err)
	}

	zap.L().Info("xray user removed", zap.String("tag", inboundTag), zap.String("email", email))
	return nil
}

// AddUserToAllInbounds — добавить пользователя сразу во все включённые inbound'ы
func (m *Manager) AddUserToAllInbounds(tags []string, userUUID, email string) []error {
	var errs []error
	for _, tag := range tags {
		if err := m.AddUser(tag, userUUID, email); err != nil {
			errs = append(errs, err)
		}
	}
	return errs
}

// RemoveUserFromAllInbounds — удалить из всех
func (m *Manager) RemoveUserFromAllInbounds(tags []string, email string) []error {
	var errs []error
	for _, tag := range tags {
		if err := m.RemoveUser(tag, email); err != nil {
			errs = append(errs, err)
		}
	}
	return errs
}

// ─────────────────────────────────────────
//  Статистика трафика
// ─────────────────────────────────────────

type UserTraffic struct {
	Email    string
	Upload   int64
	Download int64
}

// GetUserTraffic — получить трафик пользователя из Xray stats
func (m *Manager) GetUserTraffic(email string, reset bool) (*UserTraffic, error) {
	m.mu.RLock()
	stats := m.stats
	m.mu.RUnlock()

	if stats == nil {
		return nil, fmt.Errorf("xray stats not connected")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	upResp, err := stats.GetStats(ctx, &statsCommand.GetStatsRequest{
		Name:   fmt.Sprintf("user>>>%s>>>traffic>>>uplink", email),
		Reset_: reset,
	})
	if err != nil {
		return nil, err
	}

	downResp, err := stats.GetStats(ctx, &statsCommand.GetStatsRequest{
		Name:   fmt.Sprintf("user>>>%s>>>traffic>>>downlink", email),
		Reset_: reset,
	})
	if err != nil {
		return nil, err
	}

	return &UserTraffic{
		Email:    email,
		Upload:   upResp.Stat.Value,
		Download: downResp.Stat.Value,
	}, nil
}

// ─────────────────────────────────────────
//  Config file management
// ─────────────────────────────────────────

// WriteConfig — записать конфиг Xray в файл
// Используется при добавлении новых inbound'ов (требует перезапуска Xray)
func (m *Manager) WriteConfig(cfg *XrayConfig) error {
	if m.configPath == "" {
		m.configPath = "/xray-config/config.json"
	}

	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal xray config: %w", err)
	}

	if err := os.WriteFile(m.configPath, data, 0644); err != nil {
		return fmt.Errorf("write xray config: %w", err)
	}

	zap.L().Info("Xray config written", zap.String("path", m.configPath))
	return nil
}

// Close — закрыть gRPC соединение
func (m *Manager) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.conn != nil {
		return m.conn.Close()
	}
	return nil
}

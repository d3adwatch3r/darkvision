package config

import (
	"log"
	"strings"
	"time"

	"github.com/spf13/viper"
)

type Config struct {
	// App
	AppEnv         string
	AppPort        string
	LogLevel       string
	AllowedOrigins string

	// Database
	PostgresHost     string
	PostgresPort     string
	PostgresDB       string
	PostgresUser     string
	PostgresPassword string

	// Redis
	RedisHost     string
	RedisPort     string
	RedisPassword string

	// JWT
	JWTSecret     string
	JWTAccessTTL  time.Duration
	JWTRefreshTTL time.Duration

	// Xray
	XrayConfigPath string
	XrayAPIHost    string
	XrayAPIPort    int

	// Panel
	PanelDomain string
	SubBaseURL  string

	// Telegram
	TelegramBotToken      string
	TelegramWebhookSecret string

	// Rate limit
	RateLimitMax    int
	RateLimitWindow int // seconds

	// Setup
	AdminSetupDone bool
}

func Load() *Config {
	viper.SetConfigFile(".env")
	viper.AutomaticEnv()
	_ = viper.ReadInConfig()

	accessTTL, err := time.ParseDuration(viper.GetString("JWT_ACCESS_TTL"))
	if err != nil {
		accessTTL = 15 * time.Minute
	}
	refreshTTL, err := time.ParseDuration(viper.GetString("JWT_REFRESH_TTL"))
	if err != nil {
		refreshTTL = 168 * time.Hour
	}

	cfg := &Config{
		AppEnv:         getEnv("APP_ENV", "production"),
		AppPort:        getEnv("APP_PORT", "8080"),
		LogLevel:       getEnv("LOG_LEVEL", "info"),
		AllowedOrigins: getEnv("ALLOWED_ORIGINS", "*"),

		PostgresHost:     getEnv("POSTGRES_HOST", "darkvision-postgres"),
		PostgresPort:     getEnv("POSTGRES_PORT", "5432"),
		PostgresDB:       getEnv("POSTGRES_DB", "darkvision"),
		PostgresUser:     getEnv("POSTGRES_USER", "darkvision"),
		PostgresPassword: mustEnv("POSTGRES_PASSWORD"),

		RedisHost:     getEnv("REDIS_HOST", "darkvision-redis"),
		RedisPort:     getEnv("REDIS_PORT", "6379"),
		RedisPassword: mustEnv("REDIS_PASSWORD"),

		JWTSecret:     mustEnv("JWT_SECRET"),
		JWTAccessTTL:  accessTTL,
		JWTRefreshTTL: refreshTTL,

		XrayConfigPath: getEnv("XRAY_CONFIG_PATH", "/xray-config/config.json"),
		XrayAPIHost:    getEnv("XRAY_API_HOST", "darkvision-xray"),
		XrayAPIPort:    viper.GetInt("XRAY_API_PORT"),

		PanelDomain: getEnv("PANEL_DOMAIN", "localhost"),
		SubBaseURL:  getEnv("SUB_BASE_URL", "http://localhost:8080/sub"),

		TelegramBotToken:      getEnv("TELEGRAM_BOT_TOKEN", ""),
		TelegramWebhookSecret: getEnv("TELEGRAM_WEBHOOK_SECRET", ""),

		RateLimitMax:    viper.GetInt("RATE_LIMIT_MAX"),
		RateLimitWindow: viper.GetInt("RATE_LIMIT_WINDOW"),

		AdminSetupDone: viper.GetBool("ADMIN_SETUP_DONE"),
	}

	if cfg.XrayAPIPort == 0 {
		cfg.XrayAPIPort = 10085
	}
	if cfg.RateLimitMax == 0 {
		cfg.RateLimitMax = 100
	}
	if cfg.RateLimitWindow == 0 {
		cfg.RateLimitWindow = 60
	}

	return cfg
}

func getEnv(key, fallback string) string {
	if v := viper.GetString(key); v != "" {
		return strings.TrimSpace(v)
	}
	return fallback
}

func mustEnv(key string) string {
	v := viper.GetString(key)
	if v == "" {
		log.Fatalf("FATAL: required env variable %s is not set", key)
	}
	return strings.TrimSpace(v)
}

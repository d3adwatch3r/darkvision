package xray

import (
	"encoding/json"
	"fmt"
	"net/url"
)

type XrayConfig struct {
	Log       LogConfig       `json:"log"`
	API       APIConfig       `json:"api"`
	Stats     json.RawMessage `json:"stats"`
	Policy    PolicyConfig    `json:"policy"`
	Inbounds  []InboundConfig `json:"inbounds"`
	Outbounds []OutboundConf  `json:"outbounds"`
	Routing   RoutingConfig   `json:"routing"`
}
type LogConfig struct {
	LogLevel string `json:"loglevel"`
	Access   string `json:"access,omitempty"`
	Error    string `json:"error,omitempty"`
}
type APIConfig struct {
	Tag      string   `json:"tag"`
	Services []string `json:"services"`
}
type PolicyConfig struct {
	Levels map[string]PolicyLevel `json:"levels"`
	System SystemPolicy           `json:"system"`
}
type PolicyLevel struct {
	HandshakeTimeout int  `json:"handshake"`
	ConnIdle         int  `json:"connIdle"`
	StatsUserUplink  bool `json:"statsUserUplink"`
	StatsUserDown    bool `json:"statsUserDownlink"`
}
type SystemPolicy struct {
	StatsInboundUplink   bool `json:"statsInboundUplink"`
	StatsInboundDownlink bool `json:"statsInboundDownlink"`
	StatsOutboundUplink  bool `json:"statsOutboundUplink"`
	StatsOutboundDown    bool `json:"statsOutboundDownlink"`
}
type InboundConfig struct {
	Tag            string          `json:"tag"`
	Listen         string          `json:"listen"`
	Port           int             `json:"port"`
	Protocol       string          `json:"protocol"`
	Settings       json.RawMessage `json:"settings"`
	StreamSettings json.RawMessage `json:"streamSettings,omitempty"`
	Sniffing       json.RawMessage `json:"sniffing,omitempty"`
}
type OutboundConf struct {
	Tag      string          `json:"tag"`
	Protocol string          `json:"protocol"`
	Settings json.RawMessage `json:"settings,omitempty"`
}
type RoutingConfig struct{ Rules []RoutingRule `json:"rules"` }
type RoutingRule struct {
	Type        string   `json:"type"`
	InboundTag  []string `json:"inboundTag,omitempty"`
	OutboundTag string   `json:"outboundTag"`
}

type InboundParams struct {
	Tag         string
	Port        int
	PrivKey     string
	PublicKey   string
	ShortID     string
	Dest        string
	ServerNames []string
}

func BuildBaseConfig(params InboundParams) *XrayConfig {
	dest := params.Dest
	if dest == "" {
		dest = "microsoft.com:443"
	}
	serverNames := `["microsoft.com","www.microsoft.com"]`
	if len(params.ServerNames) > 0 {
		b, _ := json.Marshal(params.ServerNames)
		serverNames = string(b)
	}
	realityStream := json.RawMessage(fmt.Sprintf(`{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"%s","xver":0,"serverNames":%s,"privateKey":"%s","shortIds":["%s"]},"tcpSettings":{"header":{"type":"none"}}}`,
		dest, serverNames, params.PrivKey, params.ShortID))

	return &XrayConfig{
		Log: LogConfig{LogLevel: "warning", Access: "/var/log/xray/access.log", Error: "/var/log/xray/error.log"},
		API: APIConfig{Tag: "api", Services: []string{"HandlerService", "StatsService", "LoggerService"}},
		Stats: json.RawMessage(`{}`),
		Policy: PolicyConfig{
			Levels: map[string]PolicyLevel{"0": {HandshakeTimeout: 4, ConnIdle: 300, StatsUserUplink: true, StatsUserDown: true}},
			System: SystemPolicy{StatsInboundUplink: true, StatsInboundDownlink: true, StatsOutboundUplink: true, StatsOutboundDown: true},
		},
		Inbounds: []InboundConfig{
			{Tag: "api", Listen: "0.0.0.0", Port: 10085, Protocol: "dokodemo-door", Settings: json.RawMessage(`{"address":"127.0.0.1"}`)},
			{Tag: params.Tag, Listen: "0.0.0.0", Port: params.Port, Protocol: "vless",
				Settings:       json.RawMessage(`{"clients":[],"decryption":"none","fallbacks":[]}`),
				StreamSettings: realityStream,
				Sniffing:       json.RawMessage(`{"enabled":true,"destOverride":["http","tls","quic"]}`)},
		},
		Outbounds: []OutboundConf{{Tag: "direct", Protocol: "freedom"}, {Tag: "block", Protocol: "blackhole"}},
		Routing:   RoutingConfig{Rules: []RoutingRule{{Type: "field", InboundTag: []string{"api"}, OutboundTag: "api"}}},
	}
}

type VLESSLinkParams struct {
	UUID, Host                       string
	Port                             int
	PublicKey, ShortID, SNI          string
	Fingerprint, Flow, Remark string
}

func BuildVLESSLink(p VLESSLinkParams) string {
	fp := p.Fingerprint
	if fp == "" { fp = "chrome" }
	flow := p.Flow
	if flow == "" { flow = "xtls-rprx-vision" }
	return fmt.Sprintf("vless://%s@%s:%d?type=tcp&security=reality&pbk=%s&sid=%s&sni=%s&fp=%s&flow=%s#%s",
		p.UUID, p.Host, p.Port, url.QueryEscape(p.PublicKey), p.ShortID, p.SNI, fp, flow, url.QueryEscape(p.Remark))
}

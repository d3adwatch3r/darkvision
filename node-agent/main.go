// DarkVision Node Agent
// Лёгкий HTTP агент на удалённых VPN серверах.
// Центральная панель общается с ним для получения статуса и управления Xray.
//
// Запуск: ./darkvision-agent --port 2095 --secret YOUR_SECRET
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"
)

var (
	port   = flag.Int("port", 2095, "Agent listen port")
	secret = flag.String("secret", "", "Agent secret (required)")
)

// ─────────────────────────────────────────
//  Handlers
// ─────────────────────────────────────────

// GET /status — статус ноды
func statusHandler(w http.ResponseWriter, r *http.Request) {
	if !auth(r) {
		http.Error(w, "unauthorized", 401)
		return
	}

	status := collectStatus()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
}

// GET /xray/version — версия xray
func xrayVersionHandler(w http.ResponseWriter, r *http.Request) {
	if !auth(r) {
		http.Error(w, "unauthorized", 401)
		return
	}

	out, err := exec.Command("xray", "version").Output()
	ver := "unknown"
	if err == nil {
		lines := strings.Split(string(out), "\n")
		if len(lines) > 0 {
			ver = strings.TrimPrefix(lines[0], "Xray ")
		}
	}

	json.NewEncoder(w).Encode(map[string]string{"version": ver})
}

// POST /xray/restart — перезапуск Xray (graceful через systemctl)
func xrayRestartHandler(w http.ResponseWriter, r *http.Request) {
	if !auth(r) {
		http.Error(w, "unauthorized", 401)
		return
	}
	if r.Method != "POST" {
		http.Error(w, "method not allowed", 405)
		return
	}

	// Попробуем systemctl сначала, потом Docker
	var err error
	if _, e := exec.LookPath("systemctl"); e == nil {
		err = exec.Command("systemctl", "restart", "xray").Run()
	} else {
		err = exec.Command("docker", "restart", "darkvision-xray").Run()
	}

	if err != nil {
		http.Error(w, fmt.Sprintf("restart failed: %v", err), 500)
		return
	}

	json.NewEncoder(w).Encode(map[string]string{"status": "restarted"})
}

// GET /health
func healthHandler(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

// ─────────────────────────────────────────
//  Status collection
// ─────────────────────────────────────────

type NodeStatus struct {
	Status      string  `json:"status"`
	Hostname    string  `json:"hostname"`
	OS          string  `json:"os"`
	Arch        string  `json:"arch"`
	GoVersion   string  `json:"go_version"`
	XrayVersion string  `json:"xray_version"`
	Uptime      int64   `json:"uptime_seconds"`
	Load1m      float64 `json:"load_1m"`
	MemTotalMB  int64   `json:"mem_total_mb"`
	MemUsedMB   int64   `json:"mem_used_mb"`
	CPUCount    int     `json:"cpu_count"`
	Timestamp   int64   `json:"timestamp"`
}

func collectStatus() NodeStatus {
	hostname, _ := os.Hostname()

	s := NodeStatus{
		Status:    "online",
		Hostname:  hostname,
		OS:        runtime.GOOS,
		Arch:      runtime.GOARCH,
		GoVersion: runtime.Version(),
		CPUCount:  runtime.NumCPU(),
		Timestamp: time.Now().Unix(),
	}

	// Uptime из /proc/uptime
	if data, err := os.ReadFile("/proc/uptime"); err == nil {
		parts := strings.Fields(string(data))
		if len(parts) > 0 {
			if f, err := strconv.ParseFloat(parts[0], 64); err == nil {
				s.Uptime = int64(f)
			}
		}
	}

	// Load average из /proc/loadavg
	if data, err := os.ReadFile("/proc/loadavg"); err == nil {
		parts := strings.Fields(string(data))
		if len(parts) > 0 {
			if f, err := strconv.ParseFloat(parts[0], 64); err == nil {
				s.Load1m = f
			}
		}
	}

	// Память из /proc/meminfo
	if data, err := os.ReadFile("/proc/meminfo"); err == nil {
		lines := strings.Split(string(data), "\n")
		var total, available int64
		for _, line := range lines {
			fields := strings.Fields(line)
			if len(fields) < 2 {
				continue
			}
			val, _ := strconv.ParseInt(fields[1], 10, 64)
			switch fields[0] {
			case "MemTotal:":
				total = val / 1024
			case "MemAvailable:":
				available = val / 1024
			}
		}
		s.MemTotalMB = total
		s.MemUsedMB = total - available
	}

	// Версия Xray
	if out, err := exec.Command("xray", "version").Output(); err == nil {
		lines := strings.Split(string(out), "\n")
		if len(lines) > 0 {
			s.XrayVersion = strings.TrimPrefix(strings.TrimSpace(lines[0]), "Xray ")
		}
	}

	return s
}

// ─────────────────────────────────────────
//  Auth
// ─────────────────────────────────────────

func auth(r *http.Request) bool {
	if *secret == "" {
		return true
	}
	return r.Header.Get("X-Agent-Secret") == *secret
}

// ─────────────────────────────────────────
//  Main
// ─────────────────────────────────────────

func main() {
	flag.Parse()

	if *secret == "" {
		// Читать из env если не передан флаг
		if s := os.Getenv("AGENT_SECRET"); s != "" {
			*secret = s
		} else {
			fmt.Fprintln(os.Stderr, "WARNING: no secret set, agent is unprotected!")
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/status",       statusHandler)
	mux.HandleFunc("/xray/version", xrayVersionHandler)
	mux.HandleFunc("/xray/restart", xrayRestartHandler)
	mux.HandleFunc("/health",       healthHandler)

	addr := fmt.Sprintf("0.0.0.0:%d", *port)
	fmt.Printf("DarkVision Node Agent v1.0.0\n")
	fmt.Printf("Listening on %s\n", addr)

	srv := &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	if err := srv.ListenAndServe(); err != nil {
		fmt.Fprintf(os.Stderr, "agent error: %v\n", err)
		os.Exit(1)
	}
}

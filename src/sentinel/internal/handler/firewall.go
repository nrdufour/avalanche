package handler

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// FirewallHandler handles firewall log pages and API.
type FirewallHandler struct {
	sessions *auth.SessionManager
	cfg      *config.Config
	firewall *collector.FirewallCollector
}

// NewFirewallHandler creates a new firewall handler.
func NewFirewallHandler(sessions *auth.SessionManager, cfg *config.Config, firewall *collector.FirewallCollector) *FirewallHandler {
	return &FirewallHandler{
		sessions: sessions,
		cfg:      cfg,
		firewall: firewall,
	}
}

// FirewallPage renders the firewall logs page.
func (h *FirewallHandler) FirewallPage(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}

	params := pages.FirewallParams{
		Username: user.Username,
		Role:     user.Role,
	}

	// Get initial stats
	if h.firewall != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		if stats, err := h.firewall.GetStats(ctx, "1 hour ago"); err == nil {
			params.Stats = stats
		}
	}

	component := pages.FirewallPage(params)
	component.Render(r.Context(), w)
}

// GetLogs returns firewall logs as JSON or HTML partial.
func (h *FirewallHandler) GetLogs(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.firewall == nil {
		http.Error(w, "Firewall collector not configured", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	// Parse query parameters
	limitStr := r.URL.Query().Get("limit")
	limit := 100
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	since := r.URL.Query().Get("since")
	if since == "" {
		since = "1 hour ago"
	}

	search := r.URL.Query().Get("search")
	action := r.URL.Query().Get("action")
	protocol := r.URL.Query().Get("protocol")

	// Get logs
	logs, err := h.firewall.GetLogs(ctx, limit*2, since) // Get more, then filter
	if err != nil {
		http.Error(w, "Failed to get logs: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Filter logs
	filtered := make([]collector.FirewallLogEntry, 0, len(logs))
	for _, entry := range logs {
		// Filter by action
		if action != "" && !strings.EqualFold(entry.Action, action) {
			continue
		}

		// Filter by protocol
		if protocol != "" && !strings.EqualFold(entry.Protocol, protocol) {
			continue
		}

		// Filter by search term
		if search != "" {
			search = strings.ToLower(search)
			if !strings.Contains(strings.ToLower(entry.SrcIP), search) &&
				!strings.Contains(strings.ToLower(entry.DstIP), search) &&
				!strings.Contains(strconv.Itoa(entry.SrcPort), search) &&
				!strings.Contains(strconv.Itoa(entry.DstPort), search) &&
				!strings.Contains(strings.ToLower(entry.InInterface), search) {
				continue
			}
		}

		filtered = append(filtered, entry)
		if len(filtered) >= limit {
			break
		}
	}

	// Check if client wants JSON or HTML
	accept := r.Header.Get("Accept")
	if strings.Contains(accept, "application/json") {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(filtered)
		return
	}

	// Return HTML partial for htmx
	w.Header().Set("Content-Type", "text/html")
	component := pages.FirewallTable(filtered)
	component.Render(r.Context(), w)
}

// GetStats returns firewall statistics.
func (h *FirewallHandler) GetStats(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.firewall == nil {
		http.Error(w, "Firewall collector not configured", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	since := r.URL.Query().Get("since")
	if since == "" {
		since = "1 hour ago"
	}

	stats, err := h.firewall.GetStats(ctx, since)
	if err != nil {
		http.Error(w, "Failed to get stats: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Check if client wants JSON or HTML
	accept := r.Header.Get("Accept")
	if strings.Contains(accept, "application/json") {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(stats)
		return
	}

	// Return HTML partial for htmx
	w.Header().Set("Content-Type", "text/html")
	component := pages.FirewallStats(stats)
	component.Render(r.Context(), w)
}

// StreamLogs streams firewall logs via Server-Sent Events.
func (h *FirewallHandler) StreamLogs(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.firewall == nil {
		http.Error(w, "Firewall collector not configured", http.StatusServiceUnavailable)
		return
	}

	// Set SSE headers
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no") // Disable nginx buffering

	// Use ResponseController to access Flusher through wrapped ResponseWriters
	// This works with chi middleware that wraps the ResponseWriter
	rc := http.NewResponseController(w)

	// Test if we can flush
	if err := rc.Flush(); err != nil {
		http.Error(w, "Streaming not supported", http.StatusInternalServerError)
		return
	}

	// Send initial connection message
	fmt.Fprintf(w, "event: connected\ndata: {\"status\": \"connected\"}\n\n")
	rc.Flush()

	// Stream logs
	ctx := r.Context()
	err := h.firewall.StreamLogs(ctx, func(entry collector.FirewallLogEntry) {
		// Convert entry to JSON
		data, err := json.Marshal(entry)
		if err != nil {
			return
		}

		// Send SSE event
		fmt.Fprintf(w, "event: log\ndata: %s\n\n", data)
		rc.Flush()
	})

	if err != nil && err != context.Canceled {
		fmt.Fprintf(w, "event: error\ndata: {\"error\": \"%s\"}\n\n", err.Error())
		rc.Flush()
	}
}

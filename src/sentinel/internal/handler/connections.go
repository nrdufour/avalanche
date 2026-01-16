package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// ConnectionsHandler handles connection tracking pages and API.
type ConnectionsHandler struct {
	sessions  *auth.SessionManager
	cfg       *config.Config
	conntrack *collector.ConntrackCollector
}

// NewConnectionsHandler creates a new connections handler.
func NewConnectionsHandler(sessions *auth.SessionManager, cfg *config.Config, conntrack *collector.ConntrackCollector) *ConnectionsHandler {
	return &ConnectionsHandler{
		sessions:  sessions,
		cfg:       cfg,
		conntrack: conntrack,
	}
}

// ConnectionsPage renders the connections page.
func (h *ConnectionsHandler) ConnectionsPage(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}

	params := pages.ConnectionsParams{
		Username: user.Username,
		Role:     user.Role,
	}

	// Get initial stats
	if h.conntrack != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		if stats, err := h.conntrack.GetStats(ctx); err == nil {
			params.Stats = stats
		}

		if count, err := h.conntrack.GetCount(ctx); err == nil {
			params.TotalCount = count
		}
	}

	component := pages.ConnectionsPage(params)
	component.Render(r.Context(), w)
}

// GetConnections returns connections as JSON or HTML partial.
func (h *ConnectionsHandler) GetConnections(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.conntrack == nil {
		http.Error(w, "Conntrack collector not configured", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	// Parse query parameters
	protocol := r.URL.Query().Get("protocol")
	state := r.URL.Query().Get("state")
	search := r.URL.Query().Get("search")
	limitStr := r.URL.Query().Get("limit")
	limit := 100
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	var connections []collector.Connection
	var err error

	// Fetch connections
	if protocol != "" {
		connections, err = h.conntrack.GetConnectionsByProtocol(ctx, protocol)
	} else if state != "" {
		connections, err = h.conntrack.GetConnectionsByState(ctx, state)
	} else {
		connections, err = h.conntrack.GetConnections(ctx)
	}

	if err != nil {
		http.Error(w, "Failed to get connections: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Filter by search term
	if search != "" {
		search = strings.ToLower(search)
		filtered := make([]collector.Connection, 0)
		for _, conn := range connections {
			if strings.Contains(strings.ToLower(conn.SrcIP), search) ||
				strings.Contains(strings.ToLower(conn.DstIP), search) ||
				strings.Contains(strconv.Itoa(conn.SrcPort), search) ||
				strings.Contains(strconv.Itoa(conn.DstPort), search) {
				filtered = append(filtered, conn)
			}
		}
		connections = filtered
	}

	// Apply limit
	if len(connections) > limit {
		connections = connections[:limit]
	}

	// Check if client wants JSON or HTML
	accept := r.Header.Get("Accept")
	if strings.Contains(accept, "application/json") {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(connections)
		return
	}

	// Return HTML partial for htmx
	w.Header().Set("Content-Type", "text/html")
	component := pages.ConnectionsTable(connections)
	component.Render(r.Context(), w)
}

// GetConnectionStats returns connection statistics.
func (h *ConnectionsHandler) GetConnectionStats(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.conntrack == nil {
		http.Error(w, "Conntrack collector not configured", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	stats, err := h.conntrack.GetStats(ctx)
	if err != nil {
		http.Error(w, "Failed to get stats: "+err.Error(), http.StatusInternalServerError)
		return
	}

	count, _ := h.conntrack.GetCount(ctx)

	// Check if client wants JSON or HTML
	accept := r.Header.Get("Accept")
	if strings.Contains(accept, "application/json") {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"stats": stats,
			"count": count,
		})
		return
	}

	// Return HTML partial for htmx
	w.Header().Set("Content-Type", "text/html")
	component := pages.ConnectionsStats(stats, count)
	component.Render(r.Context(), w)
}

package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/rs/zerolog/log"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// NetworkHandler handles network status pages and API endpoints.
type NetworkHandler struct {
	sessions *auth.SessionManager
	cfg      *config.Config
	adguard  *collector.AdGuardCollector
	lldp     *collector.LLDPCollector
}

// NewNetworkHandler creates a new network handler.
func NewNetworkHandler(sessions *auth.SessionManager, cfg *config.Config, adguard *collector.AdGuardCollector, lldp *collector.LLDPCollector) *NetworkHandler {
	return &NetworkHandler{
		sessions: sessions,
		cfg:      cfg,
		adguard:  adguard,
		lldp:     lldp,
	}
}

// NetworkPage renders the network status page.
func (h *NetworkHandler) NetworkPage(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)

	params := pages.NetworkPageParams{
		Username: user.Username,
		Role:     user.Role,
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	pages.NetworkPage(params).Render(r.Context(), w)
}

// GetLLDPNeighbors returns LLDP-discovered neighbors.
func (h *NetworkHandler) GetLLDPNeighbors(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.lldp == nil {
		http.Error(w, "LLDP collector not configured", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	neighbors, err := h.lldp.GetNeighbors(ctx)
	if err != nil {
		log.Error().Err(err).Msg("Failed to get LLDP neighbors")
		http.Error(w, "Failed to get LLDP neighbors: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Check if client wants JSON or HTML
	accept := r.Header.Get("Accept")
	if strings.Contains(accept, "application/json") {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(neighbors)
		return
	}

	// Return HTML partial for htmx
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	pages.LLDPNeighborsPartial(neighbors).Render(r.Context(), w)
}

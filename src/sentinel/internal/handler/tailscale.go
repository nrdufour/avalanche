package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/rs/zerolog/log"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// TailscaleHandler handles Tailscale-related requests.
type TailscaleHandler struct {
	sessions  *auth.SessionManager
	cfg       *config.Config
	collector *collector.TailscaleCollector
}

// NewTailscaleHandler creates a new Tailscale handler.
func NewTailscaleHandler(
	sessions *auth.SessionManager,
	cfg *config.Config,
) *TailscaleHandler {
	var coll *collector.TailscaleCollector
	if cfg.Collectors.Tailscale.Enabled {
		coll = collector.NewTailscaleCollector()
	}

	return &TailscaleHandler{
		sessions:  sessions,
		cfg:       cfg,
		collector: coll,
	}
}

// TailscalePage renders the Tailscale peers page.
func (h *TailscaleHandler) TailscalePage(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}

	// Check if Tailscale is enabled
	if h.collector == nil {
		http.Error(w, "Tailscale monitoring not enabled", http.StatusNotFound)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	// Check availability first
	if !h.collector.IsAvailable(ctx) {
		// Render page with unavailable state
		component := pages.TailscalePage(pages.TailscalePageParams{
			Username:    user.Username,
			Role:        user.Role,
			Available:   false,
			BackendState: "not-running",
		})
		w.Header().Set("Content-Type", "text/html")
		component.Render(ctx, w)
		return
	}

	// Collect status
	status, err := h.collector.Collect(ctx)
	if err != nil {
		log.Error().Err(err).Msg("Failed to collect Tailscale status")
		// Render page with error state
		component := pages.TailscalePage(pages.TailscalePageParams{
			Username:    user.Username,
			Role:        user.Role,
			Available:   false,
			BackendState: "error",
			Error:       err.Error(),
		})
		w.Header().Set("Content-Type", "text/html")
		component.Render(ctx, w)
		return
	}

	// Convert peers for template
	peers := make([]pages.TailscalePeerInfo, len(status.Peers))
	for i, p := range status.Peers {
		peers[i] = convertTailscalePeer(p)
	}

	component := pages.TailscalePage(pages.TailscalePageParams{
		Username:       user.Username,
		Role:           user.Role,
		Available:      true,
		BackendState:   status.BackendState,
		Self:           convertTailscalePeer(status.Self),
		Peers:          peers,
		MagicDNSSuffix: status.MagicDNSSuffix,
	})

	w.Header().Set("Content-Type", "text/html")
	component.Render(ctx, w)
}

// GetPeers returns Tailscale peers as JSON or HTML partial.
func (h *TailscaleHandler) GetPeers(w http.ResponseWriter, r *http.Request) {
	if h.collector == nil {
		http.Error(w, "Tailscale monitoring not enabled", http.StatusNotFound)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	status, err := h.collector.Collect(ctx)
	if err != nil {
		log.Error().Err(err).Msg("Failed to collect Tailscale status")
		http.Error(w, "Failed to collect Tailscale status", http.StatusInternalServerError)
		return
	}

	// Check if client wants HTML (htmx) or JSON
	if r.Header.Get("HX-Request") == "true" {
		peers := make([]pages.TailscalePeerInfo, len(status.Peers))
		for i, p := range status.Peers {
			peers[i] = convertTailscalePeer(p)
		}

		w.Header().Set("Content-Type", "text/html")
		pages.TailscalePeersPartial(peers).Render(ctx, w)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
}

// convertTailscalePeer converts collector peer to template peer.
func convertTailscalePeer(p collector.TailscalePeer) pages.TailscalePeerInfo {
	return pages.TailscalePeerInfo{
		ID:             p.ID,
		HostName:       p.HostName,
		DNSName:        p.DNSName,
		TailscaleIPs:   p.TailscaleIPs,
		Online:         p.Online,
		LastSeen:       p.LastSeen,
		OS:             p.OS,
		ExitNode:       p.ExitNode,
		ExitNodeOption: p.ExitNodeOption,
		SubnetRouter:   p.SubnetRouter,
		Subnets:        p.Subnets,
		IsSelf:         p.IsSelf,
	}
}

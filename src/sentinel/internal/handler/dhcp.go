package handler

import (
	"net/http"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// DHCPHandler handles DHCP-related pages and API endpoints.
type DHCPHandler struct {
	sessions *auth.SessionManager
	cfg      *config.Config
	kea      *collector.KeaCollector
}

// NewDHCPHandler creates a new DHCP handler.
func NewDHCPHandler(sessions *auth.SessionManager, cfg *config.Config, kea *collector.KeaCollector) *DHCPHandler {
	return &DHCPHandler{
		sessions: sessions,
		cfg:      cfg,
		kea:      kea,
	}
}

// DHCPPage renders the DHCP leases page.
func (h *DHCPHandler) DHCPPage(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)

	// Get lease stats
	stats := pages.DHCPStats{
		ByNetwork: make(map[string]int),
	}
	var leases []pages.DHCPLease

	if h.kea != nil {
		keaStats, err := h.kea.GetLeaseStats()
		if err == nil {
			stats.Total = keaStats.Total
			stats.Active = keaStats.Active
			stats.ByNetwork = keaStats.ByNetwork
		}

		// Get active leases
		activeLeases, err := h.kea.GetActiveLeases()
		if err == nil {
			for _, lease := range activeLeases {
				state := "active"
				if lease.IsExpired() {
					state = "expired"
				}
				leases = append(leases, pages.DHCPLease{
					IPAddress:  lease.IPAddress,
					MACAddress: lease.HWAddress,
					Hostname:   lease.Hostname,
					Network:    lease.GetNetwork(),
					ExpiresIn:  lease.ExpiresInString(),
					State:      state,
				})
			}
		}
	}

	params := pages.DHCPPageParams{
		Username: user.Username,
		Role:     user.Role,
		Leases:   leases,
		Stats:    stats,
		Query:    r.URL.Query().Get("search"),
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	pages.DHCPPage(params).Render(r.Context(), w)
}

// GetLeases returns DHCP leases as HTML partial (for htmx updates).
func (h *DHCPHandler) GetLeases(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query().Get("search")

	var leases []pages.DHCPLease

	if h.kea != nil {
		var keaLeases []collector.DHCPLease
		var err error

		if query != "" {
			keaLeases, err = h.kea.SearchLeases(query)
		} else {
			keaLeases, err = h.kea.GetActiveLeases()
		}

		if err == nil {
			for _, lease := range keaLeases {
				state := "active"
				if lease.IsExpired() {
					state = "expired"
				}
				leases = append(leases, pages.DHCPLease{
					IPAddress:  lease.IPAddress,
					MACAddress: lease.HWAddress,
					Hostname:   lease.Hostname,
					Network:    lease.GetNetwork(),
					ExpiresIn:  lease.ExpiresInString(),
					State:      state,
				})
			}
		}
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	pages.LeaseRowsPartial(leases).Render(r.Context(), w)
}

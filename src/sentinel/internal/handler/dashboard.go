package handler

import (
	"net/http"

	"github.com/rs/zerolog/log"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// DashboardHandler handles dashboard-related requests.
type DashboardHandler struct {
	sessions         *auth.SessionManager
	cfg              *config.Config
	keaCollector     *collector.KeaCollector
	adguardCollector *collector.AdGuardCollector
	conntrackCollector *collector.ConntrackCollector
	systemCollector  *collector.SystemCollector
}

// NewDashboardHandler creates a new dashboard handler.
func NewDashboardHandler(
	sessions *auth.SessionManager,
	cfg *config.Config,
	kea *collector.KeaCollector,
	adguard *collector.AdGuardCollector,
	conntrack *collector.ConntrackCollector,
) *DashboardHandler {
	return &DashboardHandler{
		sessions:           sessions,
		cfg:                cfg,
		keaCollector:       kea,
		adguardCollector:   adguard,
		conntrackCollector: conntrack,
		systemCollector:    collector.NewSystemCollector(cfg.Collectors.System.DiskMountPoints),
	}
}

// Dashboard renders the main dashboard page.
func (h *DashboardHandler) Dashboard(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}

	// Build service list from config
	services := make([]pages.ServiceStatus, 0)

	// Add systemd services
	for _, svc := range h.cfg.Services.Systemd {
		services = append(services, pages.ServiceStatus{
			Name:        svc.Name,
			DisplayName: svc.DisplayName,
			Description: svc.Description,
			Status:      "unknown", // Will be updated by API
			Type:        "systemd",
		})
	}

	// Build interface list from config
	interfaces := make([]pages.InterfaceStatus, 0)
	for _, iface := range h.cfg.Collectors.Network.Interfaces {
		interfaces = append(interfaces, pages.InterfaceStatus{
			Name:        iface.Name,
			DisplayName: iface.DisplayName,
			Description: iface.Description,
			Status:      "unknown", // Will be updated by API
			IPv4:        nil,       // Will be updated by API
			RxBytes:     "-",
			TxBytes:     "-",
		})
	}

	// Fetch real stats from collectors
	var activeLeases int
	var dnsQueries int64
	var activeConnections int
	var uptime string = "-"

	// Get system stats
	if sysStats, err := h.systemCollector.Collect(); err == nil {
		uptime = collector.FormatUptime(sysStats.Uptime)
	} else {
		log.Warn().Err(err).Msg("Failed to collect system stats")
	}

	// Get DHCP lease count
	if h.keaCollector != nil {
		if count, err := h.keaCollector.GetLeaseCount(); err == nil {
			activeLeases = count
		} else {
			log.Warn().Err(err).Msg("Failed to get DHCP lease count")
		}
	}

	// Get DNS query count
	if h.adguardCollector != nil {
		if stats, err := h.adguardCollector.GetStats(r.Context()); err == nil {
			dnsQueries = stats.NumDNSQueries
		} else {
			log.Warn().Err(err).Msg("Failed to get AdGuard stats")
		}
	}

	// Get active connection count
	if h.conntrackCollector != nil {
		if conns, err := h.conntrackCollector.GetConnections(r.Context()); err == nil {
			activeConnections = len(conns)
		} else {
			log.Warn().Err(err).Msg("Failed to get connection count")
		}
	}

	params := pages.DashboardParams{
		Username:   user.Username,
		Role:       user.Role,
		Services:   services,
		Interfaces: interfaces,
		Stats: pages.DashboardStats{
			ActiveLeases:      activeLeases,
			TotalDNSQueries:   dnsQueries,
			ActiveConnections: activeConnections,
			Uptime:            uptime,
		},
	}

	component := pages.Dashboard(params)
	component.Render(r.Context(), w)
}

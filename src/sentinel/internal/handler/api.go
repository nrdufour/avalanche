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
	"forge.internal/nemo/avalanche/src/sentinel/internal/service"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// APIHandler handles API requests for services and network.
type APIHandler struct {
	cfg                 *config.Config
	sessions            *auth.SessionManager
	systemd             *service.SystemdManager
	networkCollector    *collector.NetworkCollector
	systemCollector     *collector.SystemCollector
	keaCollector        *collector.KeaCollector
	adguardCollector    *collector.AdGuardCollector
	conntrackCollector  *collector.ConntrackCollector
	wanCollector        *collector.WANCollector
	bandwidthCollector  *collector.BandwidthCollector
}

// NewAPIHandler creates a new API handler.
func NewAPIHandler(
	cfg *config.Config,
	sessions *auth.SessionManager,
	systemd *service.SystemdManager,
	kea *collector.KeaCollector,
	adguard *collector.AdGuardCollector,
	conntrack *collector.ConntrackCollector,
	bandwidth *collector.BandwidthCollector,
) *APIHandler {
	// Initialize WAN collector if enabled
	var wanCollector *collector.WANCollector
	if cfg.Collectors.WAN.Enabled {
		wanCollector = collector.NewWANCollector(
			cfg.Collectors.WAN.LatencyTargets,
			cfg.Collectors.WAN.CacheDuration,
		)
	}

	return &APIHandler{
		cfg:                 cfg,
		sessions:            sessions,
		systemd:             systemd,
		networkCollector:    collector.NewNetworkCollector(cfg.InterfaceNames()),
		systemCollector:     collector.NewSystemCollector(cfg.Collectors.System.DiskMountPoints),
		keaCollector:        kea,
		adguardCollector:    adguard,
		conntrackCollector:  conntrack,
		wanCollector:        wanCollector,
		bandwidthCollector:  bandwidth,
	}
}

// ServiceStatusResponse represents a service status in JSON.
type ServiceStatusResponse struct {
	Name        string `json:"name"`
	DisplayName string `json:"display_name"`
	Status      string `json:"status"`
	Type        string `json:"type"`
}

// GetServicesStatus returns the status of all configured services as HTML partial.
func (h *APIHandler) GetServicesStatus(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	services := make([]pages.ServiceStatus, 0)

	// Get systemd service names
	systemdNames := make([]string, len(h.cfg.Services.Systemd))
	for i, svc := range h.cfg.Services.Systemd {
		systemdNames[i] = svc.Name
	}

	// Get systemd service statuses
	if h.systemd != nil && len(systemdNames) > 0 {
		statuses, err := h.systemd.GetUnitsStatus(ctx, systemdNames)
		if err != nil {
			log.Error().Err(err).Msg("Failed to get systemd service status")
		} else {
			for _, svc := range h.cfg.Services.Systemd {
				status := "unknown"
				if s, ok := statuses[svc.Name]; ok {
					status = s.StatusString()
				} else if s, ok := statuses[svc.Name+".service"]; ok {
					status = s.StatusString()
				}

				services = append(services, pages.ServiceStatus{
					Name:        svc.Name,
					DisplayName: svc.DisplayName,
					Description: svc.Description,
					Status:      status,
					Type:        "systemd",
				})
			}
		}
	}

	// Render service cards as HTML partial
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	for _, svc := range services {
		pages.ServiceCardPartial(svc).Render(r.Context(), w)
	}
}

// GetServicesStatusJSON returns the status of all services as JSON.
func (h *APIHandler) GetServicesStatusJSON(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	var services []ServiceStatusResponse

	// Get systemd services
	if h.systemd != nil {
		systemdNames := make([]string, len(h.cfg.Services.Systemd))
		for i, svc := range h.cfg.Services.Systemd {
			systemdNames[i] = svc.Name
		}

		if len(systemdNames) > 0 {
			statuses, err := h.systemd.GetUnitsStatus(ctx, systemdNames)
			if err != nil {
				log.Error().Err(err).Msg("Failed to get systemd status")
			} else {
				for _, svc := range h.cfg.Services.Systemd {
					status := "unknown"
					if s, ok := statuses[svc.Name]; ok {
						status = s.StatusString()
					} else if s, ok := statuses[svc.Name+".service"]; ok {
						status = s.StatusString()
					}

					services = append(services, ServiceStatusResponse{
						Name:        svc.Name,
						DisplayName: svc.DisplayName,
						Status:      status,
						Type:        "systemd",
					})
				}
			}
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(services)
}

// InterfaceStatusResponse represents network interface status in JSON.
type InterfaceStatusResponse struct {
	Name        string   `json:"name"`
	DisplayName string   `json:"display_name"`
	Status      string   `json:"status"`
	IPv4        []string `json:"ipv4"`
	RxBytes     string   `json:"rx_bytes"`
	TxBytes     string   `json:"tx_bytes"`
}

// GetNetworkInterfaces returns network interface status as HTML partial.
func (h *APIHandler) GetNetworkInterfaces(w http.ResponseWriter, r *http.Request) {
	stats, err := h.networkCollector.Collect()
	if err != nil {
		log.Error().Err(err).Msg("Failed to collect network stats")
		http.Error(w, "Failed to collect network stats", http.StatusInternalServerError)
		return
	}

	// Build interface list matching config order
	interfaces := make([]pages.InterfaceStatus, 0)
	for _, ifaceCfg := range h.cfg.Collectors.Network.Interfaces {
		iface := pages.InterfaceStatus{
			Name:        ifaceCfg.Name,
			DisplayName: ifaceCfg.DisplayName,
			Description: ifaceCfg.Description,
			Status:      "down",
			IPv4:        nil,
			RxBytes:     "-",
			TxBytes:     "-",
		}

		if s, ok := stats[ifaceCfg.Name]; ok {
			iface.Status = s.StatusString()
			iface.IPv4 = s.IPv4
			iface.RxBytes = collector.FormatBytes(s.RxBytes)
			iface.TxBytes = collector.FormatBytes(s.TxBytes)
		}

		interfaces = append(interfaces, iface)
	}

	// Render interface cards as HTML partial
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	for _, iface := range interfaces {
		pages.InterfaceCardPartial(iface).Render(r.Context(), w)
	}
}

// GetNetworkInterfacesJSON returns network interface status as JSON.
func (h *APIHandler) GetNetworkInterfacesJSON(w http.ResponseWriter, r *http.Request) {
	stats, err := h.networkCollector.Collect()
	if err != nil {
		log.Error().Err(err).Msg("Failed to collect network stats")
		http.Error(w, "Failed to collect network stats", http.StatusInternalServerError)
		return
	}

	var interfaces []InterfaceStatusResponse
	for _, ifaceCfg := range h.cfg.Collectors.Network.Interfaces {
		iface := InterfaceStatusResponse{
			Name:        ifaceCfg.Name,
			DisplayName: ifaceCfg.DisplayName,
			Status:      "down",
			IPv4:        nil,
			RxBytes:     "-",
			TxBytes:     "-",
		}

		if s, ok := stats[ifaceCfg.Name]; ok {
			iface.Status = s.StatusString()
			iface.IPv4 = s.IPv4
			iface.RxBytes = collector.FormatBytes(s.RxBytes)
			iface.TxBytes = collector.FormatBytes(s.TxBytes)
		}

		interfaces = append(interfaces, iface)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(interfaces)
}

// GetDashboardStats returns dashboard statistics.
func (h *APIHandler) GetDashboardStats(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	sysStats, err := h.systemCollector.Collect()
	if err != nil {
		log.Error().Err(err).Msg("Failed to collect system stats")
	}

	// Get active lease count from Kea
	activeLeases := 0
	if h.keaCollector != nil {
		count, err := h.keaCollector.GetLeaseCount()
		if err != nil {
			log.Error().Err(err).Msg("Failed to get DHCP lease count")
		} else {
			activeLeases = count
		}
	}

	// Get DNS query count from AdGuard
	var dnsQueries int64
	if h.adguardCollector != nil {
		adgStats, err := h.adguardCollector.GetStats(ctx)
		if err != nil {
			log.Error().Err(err).Msg("Failed to get AdGuard stats")
		} else {
			dnsQueries = adgStats.NumDNSQueries
		}
	}

	// Get active connections from conntrack
	activeConnections := 0
	if h.conntrackCollector != nil {
		conns, err := h.conntrackCollector.GetConnections(ctx)
		if err != nil {
			log.Error().Err(err).Msg("Failed to get connection count")
		} else {
			activeConnections = len(conns)
		}
	}

	// Check if client wants HTML (htmx) or JSON
	// htmx sends HX-Request header
	if r.Header.Get("HX-Request") == "true" {
		w.Header().Set("Content-Type", "text/html")
		component := pages.StatsPartial(pages.DashboardStats{
			ActiveLeases:      activeLeases,
			TotalDNSQueries:   dnsQueries,
			ActiveConnections: activeConnections,
			Uptime:            collector.FormatUptime(sysStats.Uptime),
		})
		component.Render(ctx, w)
		return
	}

	stats := map[string]interface{}{
		"uptime":        collector.FormatUptime(sysStats.Uptime),
		"load_avg":      sysStats.LoadAvg1,
		"mem_used":      collector.FormatMemory(sysStats.MemUsed),
		"mem_total":     collector.FormatMemory(sysStats.MemTotal),
		"mem_percent":   sysStats.MemPercent,
		"active_leases": activeLeases,
		"dns_queries":   dnsQueries,
		"connections":   activeConnections,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

// GetWANStatus returns WAN status information.
func (h *APIHandler) GetWANStatus(w http.ResponseWriter, r *http.Request) {
	if h.wanCollector == nil {
		http.Error(w, "WAN monitoring not enabled", http.StatusNotFound)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	stats, err := h.wanCollector.Collect(ctx)
	if err != nil {
		log.Error().Err(err).Msg("Failed to collect WAN stats")
		http.Error(w, "Failed to collect WAN stats", http.StatusInternalServerError)
		return
	}

	// Check if client wants HTML (htmx) or JSON
	if r.Header.Get("HX-Request") == "true" {
		w.Header().Set("Content-Type", "text/html")
		pages.WANStatusPartial(convertWANStats(stats)).Render(ctx, w)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

// convertWANStats converts collector WAN stats to page WAN stats.
func convertWANStats(stats *collector.WANStats) pages.WANStatus {
	targets := make([]pages.WANTarget, len(stats.Targets))
	for i, t := range stats.Targets {
		targets[i] = pages.WANTarget{
			Name:       t.Name,
			IP:         t.IP,
			Latency:    t.Latency,
			PacketLoss: t.PacketLoss,
			Status:     t.Status,
		}
	}

	return pages.WANStatus{
		PublicIP:  stats.PublicIP,
		Targets:   targets,
		LastCheck: stats.LastCheck,
	}
}

// GetTimers returns systemd timer status.
func (h *APIHandler) GetTimers(w http.ResponseWriter, r *http.Request) {
	if h.systemd == nil {
		http.Error(w, "Systemd manager not available", http.StatusNotFound)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	timers, err := h.systemd.GetTimers(ctx)
	if err != nil {
		log.Error().Err(err).Msg("Failed to get timers")
		http.Error(w, "Failed to get timers", http.StatusInternalServerError)
		return
	}

	// Check if client wants HTML (htmx) or JSON
	if r.Header.Get("HX-Request") == "true" {
		timerInfos := make([]pages.TimerInfo, len(timers))
		for i, t := range timers {
			timerInfos[i] = pages.TimerInfo{
				Name:        t.Name,
				Description: t.Description,
				Active:      t.Active,
				NextRun:     t.NextRun,
				LastRun:     t.LastRun,
				Unit:        t.Unit,
			}
		}

		w.Header().Set("Content-Type", "text/html")
		pages.TimersPartial(timerInfos).Render(ctx, w)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(timers)
}

// GetBandwidth returns bandwidth history for interfaces.
func (h *APIHandler) GetBandwidth(w http.ResponseWriter, r *http.Request) {
	if h.bandwidthCollector == nil {
		http.Error(w, "Bandwidth monitoring not enabled", http.StatusNotFound)
		return
	}

	// Parse query parameters
	ifaceName := r.URL.Query().Get("interface")
	sinceStr := r.URL.Query().Get("since")

	var since time.Duration
	if sinceStr != "" {
		parsed, err := time.ParseDuration(sinceStr)
		if err == nil {
			since = parsed
		}
	}

	// Default to 1 hour
	if since == 0 {
		since = time.Hour
	}

	var response interface{}
	if ifaceName != "" {
		// Get history for specific interface
		response = h.bandwidthCollector.GetHistory(ifaceName, since)
	} else {
		// Get history for all interfaces
		response = h.bandwidthCollector.GetAllHistory(since)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}

package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/rs/zerolog/log"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/internal/service"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// APIHandler handles API requests for services and network.
type APIHandler struct {
	cfg              *config.Config
	sessions         *auth.SessionManager
	systemd          *service.SystemdManager
	docker           *service.DockerManager
	networkCollector *collector.NetworkCollector
	systemCollector  *collector.SystemCollector
	keaCollector     *collector.KeaCollector
	adguardCollector *collector.AdGuardCollector
}

// NewAPIHandler creates a new API handler.
func NewAPIHandler(
	cfg *config.Config,
	sessions *auth.SessionManager,
	systemd *service.SystemdManager,
	docker *service.DockerManager,
	kea *collector.KeaCollector,
	adguard *collector.AdGuardCollector,
) *APIHandler {
	// Build interface list from config
	interfaces := make([]string, len(cfg.Collectors.Network.Interfaces))
	for i, iface := range cfg.Collectors.Network.Interfaces {
		interfaces[i] = iface.Name
	}

	return &APIHandler{
		cfg:              cfg,
		sessions:         sessions,
		systemd:          systemd,
		docker:           docker,
		networkCollector: collector.NewNetworkCollector(interfaces),
		systemCollector:  collector.NewSystemCollector(),
		keaCollector:     kea,
		adguardCollector: adguard,
	}
}

// ServiceStatusResponse represents a service status in JSON.
type ServiceStatusResponse struct {
	Name        string `json:"name"`
	DisplayName string `json:"display_name"`
	Status      string `json:"status"`
	CanRestart  bool   `json:"can_restart"`
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
					CanRestart:  svc.CanRestart,
					Type:        "systemd",
				})
			}
		}
	}

	// Get Docker container names
	if h.docker != nil && h.cfg.Services.Docker.Enabled {
		containerNames := make([]string, len(h.cfg.Services.Docker.Containers))
		for i, c := range h.cfg.Services.Docker.Containers {
			containerNames[i] = c.Name
		}

		if len(containerNames) > 0 {
			statuses, err := h.docker.GetContainersStatus(ctx, containerNames)
			if err != nil {
				log.Error().Err(err).Msg("Failed to get Docker container status")
			} else {
				for _, container := range h.cfg.Services.Docker.Containers {
					status := "unknown"
					if s, ok := statuses[container.Name]; ok {
						status = s.StatusString()
					}

					services = append(services, pages.ServiceStatus{
						Name:        container.Name,
						DisplayName: container.DisplayName,
						Description: container.Description,
						Status:      status,
						CanRestart:  container.CanRestart,
						Type:        "docker",
					})
				}
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
						CanRestart:  svc.CanRestart,
						Type:        "systemd",
					})
				}
			}
		}
	}

	// Get Docker containers
	if h.docker != nil && h.cfg.Services.Docker.Enabled {
		containerNames := make([]string, len(h.cfg.Services.Docker.Containers))
		for i, c := range h.cfg.Services.Docker.Containers {
			containerNames[i] = c.Name
		}

		if len(containerNames) > 0 {
			statuses, err := h.docker.GetContainersStatus(ctx, containerNames)
			if err != nil {
				log.Error().Err(err).Msg("Failed to get Docker status")
			} else {
				for _, container := range h.cfg.Services.Docker.Containers {
					status := "unknown"
					if s, ok := statuses[container.Name]; ok {
						status = s.StatusString()
					}

					services = append(services, ServiceStatusResponse{
						Name:        container.Name,
						DisplayName: container.DisplayName,
						Status:      status,
						CanRestart:  container.CanRestart,
						Type:        "docker",
					})
				}
			}
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(services)
}

// RestartService handles service restart requests.
func (h *APIHandler) RestartService(w http.ResponseWriter, r *http.Request) {
	serviceName := chi.URLParam(r, "name")
	if serviceName == "" {
		http.Error(w, "Service name required", http.StatusBadRequest)
		return
	}

	// Check if user has permission (operator or admin)
	if !h.sessions.HasMinRole(r, "operator") {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	// Find service in config and check if restart is allowed
	var serviceType string
	var canRestart bool

	for _, svc := range h.cfg.Services.Systemd {
		if svc.Name == serviceName {
			serviceType = "systemd"
			canRestart = svc.CanRestart
			break
		}
	}

	if serviceType == "" {
		for _, container := range h.cfg.Services.Docker.Containers {
			if container.Name == serviceName {
				serviceType = "docker"
				canRestart = container.CanRestart
				break
			}
		}
	}

	if serviceType == "" {
		http.Error(w, "Service not found", http.StatusNotFound)
		return
	}

	if !canRestart {
		http.Error(w, "Service restart not allowed", http.StatusForbidden)
		return
	}

	user := h.sessions.GetUser(r)
	log.Info().
		Str("service", serviceName).
		Str("type", serviceType).
		Str("user", user.Username).
		Msg("Service restart requested")

	var err error
	switch serviceType {
	case "systemd":
		if h.systemd == nil {
			http.Error(w, "Systemd manager not available", http.StatusServiceUnavailable)
			return
		}
		err = h.systemd.RestartUnit(ctx, serviceName)
	case "docker":
		if h.docker == nil {
			http.Error(w, "Docker manager not available", http.StatusServiceUnavailable)
			return
		}
		err = h.docker.RestartContainer(ctx, serviceName)
	}

	if err != nil {
		log.Error().Err(err).Str("service", serviceName).Msg("Failed to restart service")
		http.Error(w, "Failed to restart service: "+err.Error(), http.StatusInternalServerError)
		return
	}

	log.Info().Str("service", serviceName).Msg("Service restarted successfully")

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "ok",
		"message": "Service restart initiated",
	})
}

// InterfaceStatusResponse represents network interface status in JSON.
type InterfaceStatusResponse struct {
	Name        string `json:"name"`
	DisplayName string `json:"display_name"`
	Status      string `json:"status"`
	IPv4        string `json:"ipv4"`
	RxBytes     string `json:"rx_bytes"`
	TxBytes     string `json:"tx_bytes"`
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
			IPv4:        "-",
			RxBytes:     "-",
			TxBytes:     "-",
		}

		if s, ok := stats[ifaceCfg.Name]; ok {
			iface.Status = s.StatusString()
			if s.IPv4 != "" {
				iface.IPv4 = s.IPv4
			}
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
			IPv4:        "-",
			RxBytes:     "-",
			TxBytes:     "-",
		}

		if s, ok := stats[ifaceCfg.Name]; ok {
			iface.Status = s.StatusString()
			if s.IPv4 != "" {
				iface.IPv4 = s.IPv4
			}
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

	stats := map[string]interface{}{
		"uptime":        collector.FormatUptime(sysStats.Uptime),
		"load_avg":      sysStats.LoadAvg1,
		"mem_used":      collector.FormatMemory(sysStats.MemUsed),
		"mem_total":     collector.FormatMemory(sysStats.MemTotal),
		"mem_percent":   sysStats.MemPercent,
		"active_leases": activeLeases,
		"dns_queries":   dnsQueries,
		"connections":   0, // TODO: Implement conntrack in Phase 4
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(stats)
}

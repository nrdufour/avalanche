// Command sentinel is the gateway management tool for routy.
package main

import (
	"context"
	"flag"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/go-chi/chi/v5"
	chimiddleware "github.com/go-chi/chi/v5/middleware"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/internal/handler"
	"forge.internal/nemo/avalanche/src/sentinel/internal/metrics"
	"forge.internal/nemo/avalanche/src/sentinel/internal/middleware"
	"forge.internal/nemo/avalanche/src/sentinel/internal/service"
)

var (
	// Version is set at build time
	Version = "dev"
	// BuildTime is set at build time
	BuildTime = "unknown"
)

func main() {
	// Parse command line flags
	configPath := flag.String("config", "config.yaml", "Path to configuration file")
	flag.Parse()

	// Load configuration
	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to load configuration")
	}

	// Setup logging
	setupLogging(cfg.Logging)

	log.Info().
		Str("version", Version).
		Str("build_time", BuildTime).
		Msg("Starting Sentinel")

	// Initialize session manager
	sessions := auth.NewSessionManager(
		cfg.Session.Secret,
		cfg.Session.Lifetime,
		cfg.Session.Secure,
	)

	// Initialize local authenticator
	var localAuth *auth.LocalAuthenticator
	if cfg.Auth.Local.Enabled {
		localAuth = auth.NewLocalAuthenticator(cfg.Auth.Local)
	}

	// Initialize systemd manager
	var systemdMgr *service.SystemdManager
	systemdMgr, err = service.NewSystemdManager()
	if err != nil {
		log.Warn().Err(err).Msg("Failed to connect to systemd, service management disabled")
	} else {
		defer systemdMgr.Close()
	}

	// Initialize Docker manager (if enabled)
	var dockerMgr *service.DockerManager
	if cfg.Services.Docker.Enabled {
		dockerMgr, err = service.NewDockerManager(cfg.Services.Docker.Socket)
		if err != nil {
			log.Warn().Err(err).Msg("Failed to connect to Docker, container management disabled")
		} else {
			defer dockerMgr.Close()
		}
	}

	// Initialize Kea DHCP collector
	var keaCollector *collector.KeaCollector
	if cfg.Collectors.Kea.LeaseFile != "" {
		keaCollector = collector.NewKeaCollector(cfg.Collectors.Kea.LeaseFile, cfg.Collectors.Kea.ControlSocket)
		log.Info().Str("lease_file", cfg.Collectors.Kea.LeaseFile).Msg("Kea collector initialized")
	}

	// Initialize AdGuard Home collector
	var adguardCollector *collector.AdGuardCollector
	if cfg.Collectors.AdGuard.APIURL != "" {
		adguardCollector = collector.NewAdGuardCollector(
			cfg.Collectors.AdGuard.APIURL,
			cfg.Collectors.AdGuard.Username,
			"", // Password can be loaded from file in Phase 5
		)
		log.Info().Str("api_url", cfg.Collectors.AdGuard.APIURL).Msg("AdGuard collector initialized")
	}

	// Initialize diagnostics runner
	diagnosticsRunner := collector.NewDiagnosticsRunner(
		cfg.Diagnostics.AllowedTargets,
		cfg.Diagnostics.PingTimeout,
		cfg.Diagnostics.TracerouteTimeout,
		cfg.Diagnostics.DNSTimeout,
		cfg.Diagnostics.PortTimeout,
	)
	log.Info().Int("allowed_targets", len(cfg.Diagnostics.AllowedTargets)).Msg("Diagnostics runner initialized")

	// Initialize conntrack collector
	conntrackCollector := collector.NewConntrackCollector(30 * time.Second)
	log.Info().Msg("Conntrack collector initialized")

	// Initialize firewall log collector
	firewallCollector := collector.NewFirewallCollector(30 * time.Second)
	log.Info().Msg("Firewall log collector initialized")

	// Initialize LLDP collector (if enabled)
	var lldpCollector *collector.LLDPCollector
	if cfg.Collectors.LLDP.Enabled {
		lldpCollector = collector.NewLLDPCollector(10 * time.Second)
		if lldpCollector.IsAvailable() {
			log.Info().Str("path", lldpCollector.GetPath()).Msg("LLDP collector initialized")
		} else {
			log.Warn().Str("path", lldpCollector.GetPath()).Msg("LLDP collector enabled but lldpctl not found")
			lldpCollector = nil
		}
	}

	// Initialize DNS cache for reverse lookups
	dnsCache := collector.NewDNSCache(5000, time.Hour, 500*time.Millisecond)
	log.Info().Msg("DNS cache initialized")

	// Initialize network collector for interface stats
	interfaceNames := make([]string, len(cfg.Collectors.Network.Interfaces))
	for i, iface := range cfg.Collectors.Network.Interfaces {
		interfaceNames[i] = iface.Name
	}
	networkCollector := collector.NewNetworkCollector(interfaceNames)
	log.Info().Int("interfaces", len(cfg.Collectors.Network.Interfaces)).Msg("Network collector initialized")

	// Initialize Prometheus metrics
	promMetrics := metrics.New(Version, BuildTime)
	log.Info().Msg("Prometheus metrics initialized")

	// Start metrics collector (if metrics are enabled)
	var metricsCollector *metrics.Collector
	if cfg.Metrics.Enabled {
		metricsCollector = metrics.NewCollector(
			promMetrics,
			cfg,
			systemdMgr,
			keaCollector,
			adguardCollector,
			conntrackCollector,
			networkCollector,
			15*time.Second, // Collect every 15 seconds
		)
		metricsCollector.Start()
		defer metricsCollector.Stop()
		log.Info().Str("path", cfg.Metrics.Path).Msg("Metrics collector started")
	}

	// Initialize bandwidth collector if enabled
	var bandwidthCollector *collector.BandwidthCollector
	if cfg.Collectors.Bandwidth.Enabled {
		interfaces := make([]string, len(cfg.Collectors.Network.Interfaces))
		for i, iface := range cfg.Collectors.Network.Interfaces {
			interfaces[i] = iface.Name
		}
		bandwidthCollector = collector.NewBandwidthCollector(
			interfaces,
			cfg.Collectors.Bandwidth.SampleRate,
			cfg.Collectors.Bandwidth.Retention,
		)
		bandwidthCollector.Start(context.Background())
		defer bandwidthCollector.Stop()
		log.Info().Int("interfaces", len(interfaces)).Msg("Bandwidth collector started")
	}

	// Initialize handlers
	authHandler := handler.NewAuthHandler(localAuth, sessions)
	dashboardHandler := handler.NewDashboardHandler(sessions, cfg, keaCollector, adguardCollector, conntrackCollector)
	apiHandler := handler.NewAPIHandler(cfg, sessions, systemdMgr, dockerMgr, keaCollector, adguardCollector, conntrackCollector, bandwidthCollector)
	dhcpHandler := handler.NewDHCPHandler(sessions, cfg, keaCollector)
	networkHandler := handler.NewNetworkHandler(sessions, cfg, diagnosticsRunner, adguardCollector, lldpCollector)
	connectionsHandler := handler.NewConnectionsHandler(sessions, cfg, conntrackCollector, dnsCache)
	firewallHandler := handler.NewFirewallHandler(sessions, cfg, firewallCollector, dnsCache)
	tailscaleHandler := handler.NewTailscaleHandler(sessions, cfg)

	// Create router
	r := chi.NewRouter()

	// Global middleware
	r.Use(chimiddleware.RequestID)
	r.Use(chimiddleware.RealIP)
	r.Use(chimiddleware.Logger)
	r.Use(chimiddleware.Recoverer)
	r.Use(sessions.LoadAndSave)

	// Metrics middleware (if enabled)
	if cfg.Metrics.Enabled {
		r.Use(middleware.MetricsMiddleware(promMetrics))
	}

	// Static files (served from disk)
	r.Handle("/static/*", http.StripPrefix("/static/", http.FileServer(http.Dir("static"))))

	// Public routes
	r.Get("/login", authHandler.LoginPage)
	r.Post("/login", authHandler.Login)

	// Protected routes
	r.Group(func(r chi.Router) {
		r.Use(middleware.RequireAuth(sessions))

		// Dashboard
		r.Get("/", dashboardHandler.Dashboard)

		// Logout
		r.Post("/logout", authHandler.Logout)

		// API routes
		r.Route("/api", func(r chi.Router) {
			// Service status and control
			r.Get("/services/status", apiHandler.GetServicesStatus)
			r.Get("/services/status.json", apiHandler.GetServicesStatusJSON)
			r.Post("/services/{name}/restart", apiHandler.RestartService)

			// Network interfaces
			r.Get("/network/interfaces", apiHandler.GetNetworkInterfaces)
			r.Get("/network/interfaces.json", apiHandler.GetNetworkInterfacesJSON)

			// Bandwidth history
			r.Get("/network/bandwidth", apiHandler.GetBandwidth)

			// Dashboard stats
			r.Get("/stats", apiHandler.GetDashboardStats)

			// WAN status
			r.Get("/wan/status", apiHandler.GetWANStatus)

			// Tailscale
			r.Get("/tailscale/peers", tailscaleHandler.GetPeers)

			// Systemd timers
			r.Get("/timers", apiHandler.GetTimers)

			// DHCP leases
			r.Get("/dhcp/leases", dhcpHandler.GetLeases)

			// Network diagnostics
			r.Post("/network/ping", networkHandler.Ping)
			r.Post("/network/traceroute", networkHandler.Traceroute)
			r.Post("/network/dns", networkHandler.DNSLookup)
			r.Post("/network/port", networkHandler.PortCheck)
			r.Post("/network/dns/clear-cache", networkHandler.ClearDNSCache)
			r.Get("/network/lldp", networkHandler.GetLLDPNeighbors)

			// Firewall logs
			r.Get("/firewall/logs", firewallHandler.GetLogs)
			r.Get("/firewall/stats", firewallHandler.GetStats)
			r.Get("/firewall/stream", firewallHandler.StreamLogs)
			r.Get("/firewall/chart", firewallHandler.GetChartData)
			r.Get("/firewall/aggregated", firewallHandler.GetAggregatedLogs)

			// Connection tracking
			r.Get("/connections", connectionsHandler.GetConnections)
			r.Get("/connections/stats", connectionsHandler.GetConnectionStats)
			r.Get("/connections/talkers", connectionsHandler.GetTopTalkers)
		})

		// Pages
		r.Get("/dhcp", dhcpHandler.DHCPPage)
		r.Get("/network", networkHandler.NetworkPage)
		r.Get("/tailscale", tailscaleHandler.TailscalePage)
		r.Get("/firewall", firewallHandler.FirewallPage)
		r.Get("/connections", connectionsHandler.ConnectionsPage)
	})

	// Metrics endpoint (if enabled)
	if cfg.Metrics.Enabled {
		r.Handle(cfg.Metrics.Path, promhttp.Handler())
		log.Info().Str("path", cfg.Metrics.Path).Msg("Prometheus metrics endpoint enabled")
	}

	// Create server
	srv := &http.Server{
		Addr:         cfg.Address(),
		Handler:      r,
		ReadTimeout:  cfg.Server.ReadTimeout,
		WriteTimeout: cfg.Server.WriteTimeout,
	}

	// Start server in goroutine
	go func() {
		log.Info().Str("address", cfg.Address()).Msg("Starting HTTP server")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal().Err(err).Msg("HTTP server error")
		}
	}()

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Info().Msg("Shutting down server...")

	// Graceful shutdown with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		log.Fatal().Err(err).Msg("Server forced to shutdown")
	}

	log.Info().Msg("Server stopped")
}

// setupLogging configures the logger based on configuration.
func setupLogging(cfg config.LoggingConfig) {
	// Set log level
	level, err := zerolog.ParseLevel(cfg.Level)
	if err != nil {
		level = zerolog.InfoLevel
	}
	zerolog.SetGlobalLevel(level)

	// Set output format
	if cfg.Format == "console" {
		log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr})
	}
}

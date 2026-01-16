// Package metrics provides Prometheus metrics for Sentinel.
package metrics

import (
	"context"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/internal/service"
)

// Metrics holds all Prometheus metrics for Sentinel.
type Metrics struct {
	// Service metrics
	ServiceUp *prometheus.GaugeVec

	// DHCP metrics
	DHCPLeasesTotal *prometheus.GaugeVec

	// DNS metrics
	DNSQueriesTotal   prometheus.Gauge
	DNSBlockedTotal   prometheus.Gauge
	DNSBlockedPercent prometheus.Gauge

	// Connection metrics
	ConnectionsTotal *prometheus.GaugeVec

	// Network interface metrics
	InterfaceUp       *prometheus.GaugeVec
	InterfaceRxBytes  *prometheus.GaugeVec
	InterfaceTxBytes  *prometheus.GaugeVec
	InterfaceRxErrors *prometheus.GaugeVec
	InterfaceTxErrors *prometheus.GaugeVec

	// HTTP metrics
	HTTPRequestsTotal   *prometheus.CounterVec
	HTTPRequestDuration *prometheus.HistogramVec

	// Build info
	BuildInfo *prometheus.GaugeVec
}

// New creates a new Metrics instance with all metrics registered.
func New(version, buildTime string) *Metrics {
	m := &Metrics{
		ServiceUp: promauto.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "sentinel_service_up",
				Help: "Whether a monitored service is running (1) or not (0)",
			},
			[]string{"name", "display_name"},
		),

		DHCPLeasesTotal: promauto.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "sentinel_dhcp_leases_total",
				Help: "Total number of active DHCP leases",
			},
			[]string{"network"},
		),

		DNSQueriesTotal: promauto.NewGauge(
			prometheus.GaugeOpts{
				Name: "sentinel_dns_queries_total",
				Help: "Total DNS queries processed by AdGuard Home",
			},
		),

		DNSBlockedTotal: promauto.NewGauge(
			prometheus.GaugeOpts{
				Name: "sentinel_dns_blocked_total",
				Help: "Total DNS queries blocked by AdGuard Home",
			},
		),

		DNSBlockedPercent: promauto.NewGauge(
			prometheus.GaugeOpts{
				Name: "sentinel_dns_blocked_percent",
				Help: "Percentage of DNS queries blocked by AdGuard Home",
			},
		),

		ConnectionsTotal: promauto.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "sentinel_connections_total",
				Help: "Total number of tracked NAT connections",
			},
			[]string{"protocol", "state"},
		),

		InterfaceUp: promauto.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "sentinel_interface_up",
				Help: "Whether a network interface is up (1) or down (0)",
			},
			[]string{"interface", "display_name"},
		),

		InterfaceRxBytes: promauto.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "sentinel_interface_rx_bytes_total",
				Help: "Total bytes received on interface",
			},
			[]string{"interface"},
		),

		InterfaceTxBytes: promauto.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "sentinel_interface_tx_bytes_total",
				Help: "Total bytes transmitted on interface",
			},
			[]string{"interface"},
		),

		InterfaceRxErrors: promauto.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "sentinel_interface_rx_errors_total",
				Help: "Total receive errors on interface",
			},
			[]string{"interface"},
		),

		InterfaceTxErrors: promauto.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "sentinel_interface_tx_errors_total",
				Help: "Total transmit errors on interface",
			},
			[]string{"interface"},
		),

		HTTPRequestsTotal: promauto.NewCounterVec(
			prometheus.CounterOpts{
				Name: "sentinel_http_requests_total",
				Help: "Total number of HTTP requests",
			},
			[]string{"method", "path", "status"},
		),

		HTTPRequestDuration: promauto.NewHistogramVec(
			prometheus.HistogramOpts{
				Name:    "sentinel_http_request_duration_seconds",
				Help:    "HTTP request duration in seconds",
				Buckets: prometheus.DefBuckets,
			},
			[]string{"method", "path"},
		),

		BuildInfo: promauto.NewGaugeVec(
			prometheus.GaugeOpts{
				Name: "sentinel_build_info",
				Help: "Build information for Sentinel",
			},
			[]string{"version", "build_time"},
		),
	}

	// Set build info
	m.BuildInfo.WithLabelValues(version, buildTime).Set(1)

	return m
}

// Collector periodically collects metrics from various sources.
type Collector struct {
	metrics   *Metrics
	cfg       *config.Config
	systemd   *service.SystemdManager
	kea       *collector.KeaCollector
	adguard   *collector.AdGuardCollector
	conntrack *collector.ConntrackCollector
	network   *collector.NetworkCollector
	interval  time.Duration
	stopCh    chan struct{}
}

// NewCollector creates a new metrics collector.
func NewCollector(
	metrics *Metrics,
	cfg *config.Config,
	systemd *service.SystemdManager,
	kea *collector.KeaCollector,
	adguard *collector.AdGuardCollector,
	conntrack *collector.ConntrackCollector,
	network *collector.NetworkCollector,
	interval time.Duration,
) *Collector {
	return &Collector{
		metrics:   metrics,
		cfg:       cfg,
		systemd:   systemd,
		kea:       kea,
		adguard:   adguard,
		conntrack: conntrack,
		network:   network,
		interval:  interval,
		stopCh:    make(chan struct{}),
	}
}

// Start begins collecting metrics at the configured interval.
func (c *Collector) Start() {
	// Collect immediately on start
	c.collect()

	ticker := time.NewTicker(c.interval)
	go func() {
		for {
			select {
			case <-ticker.C:
				c.collect()
			case <-c.stopCh:
				ticker.Stop()
				return
			}
		}
	}()
}

// Stop stops the metrics collector.
func (c *Collector) Stop() {
	close(c.stopCh)
}

// collect gathers all metrics.
func (c *Collector) collect() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	c.collectServiceMetrics(ctx)
	c.collectDHCPMetrics(ctx)
	c.collectDNSMetrics(ctx)
	c.collectConnectionMetrics(ctx)
	c.collectNetworkMetrics(ctx)
}

// collectServiceMetrics collects systemd service status metrics.
func (c *Collector) collectServiceMetrics(ctx context.Context) {
	if c.systemd == nil {
		return
	}

	for _, svc := range c.cfg.Services.Systemd {
		status, err := c.systemd.GetUnitStatus(ctx, svc.Name)
		if err != nil {
			c.metrics.ServiceUp.WithLabelValues(svc.Name, svc.DisplayName).Set(0)
			continue
		}

		up := 0.0
		if status.ActiveState == "active" {
			up = 1.0
		}
		c.metrics.ServiceUp.WithLabelValues(svc.Name, svc.DisplayName).Set(up)
	}
}

// collectDHCPMetrics collects DHCP lease metrics.
func (c *Collector) collectDHCPMetrics(_ context.Context) {
	if c.kea == nil {
		return
	}

	leases, err := c.kea.GetLeases()
	if err != nil {
		return
	}

	// Count leases by network (simplified - could be enhanced)
	c.metrics.DHCPLeasesTotal.WithLabelValues("all").Set(float64(len(leases)))
}

// collectDNSMetrics collects DNS statistics from AdGuard Home.
func (c *Collector) collectDNSMetrics(ctx context.Context) {
	if c.adguard == nil {
		return
	}

	stats, err := c.adguard.GetStats(ctx)
	if err != nil {
		return
	}

	c.metrics.DNSQueriesTotal.Set(float64(stats.NumDNSQueries))
	c.metrics.DNSBlockedTotal.Set(float64(stats.NumBlockedFiltering))
	if stats.NumDNSQueries > 0 {
		blockedPercent := float64(stats.NumBlockedFiltering) / float64(stats.NumDNSQueries) * 100
		c.metrics.DNSBlockedPercent.Set(blockedPercent)
	}
}

// collectConnectionMetrics collects connection tracking metrics.
func (c *Collector) collectConnectionMetrics(ctx context.Context) {
	if c.conntrack == nil {
		return
	}

	stats, err := c.conntrack.GetStats(ctx)
	if err != nil {
		return
	}

	// Reset all connection metrics first
	c.metrics.ConnectionsTotal.Reset()

	// Set by protocol
	for proto, count := range stats.ByProtocol {
		c.metrics.ConnectionsTotal.WithLabelValues(proto, "").Set(float64(count))
	}

	// Set by state
	for state, count := range stats.ByState {
		c.metrics.ConnectionsTotal.WithLabelValues("", state).Set(float64(count))
	}
}

// collectNetworkMetrics collects network interface metrics.
func (c *Collector) collectNetworkMetrics(_ context.Context) {
	if c.network == nil {
		return
	}

	for _, iface := range c.cfg.Collectors.Network.Interfaces {
		status, err := c.network.CollectOne(iface.Name)
		if err != nil {
			c.metrics.InterfaceUp.WithLabelValues(iface.Name, iface.DisplayName).Set(0)
			continue
		}

		up := 0.0
		if status.IsUp {
			up = 1.0
		}
		c.metrics.InterfaceUp.WithLabelValues(iface.Name, iface.DisplayName).Set(up)
		c.metrics.InterfaceRxBytes.WithLabelValues(iface.Name).Set(float64(status.RxBytes))
		c.metrics.InterfaceTxBytes.WithLabelValues(iface.Name).Set(float64(status.TxBytes))
		c.metrics.InterfaceRxErrors.WithLabelValues(iface.Name).Set(float64(status.RxErrors))
		c.metrics.InterfaceTxErrors.WithLabelValues(iface.Name).Set(float64(status.TxErrors))
	}
}

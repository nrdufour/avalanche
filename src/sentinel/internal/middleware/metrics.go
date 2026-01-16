package middleware

import (
	"net/http"
	"strconv"
	"time"

	"forge.internal/nemo/avalanche/src/sentinel/internal/metrics"
)

// MetricsMiddleware records HTTP request metrics.
func MetricsMiddleware(m *metrics.Metrics) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()

			// Wrap response writer to capture status code
			wrapped := &statusRecorder{ResponseWriter: w, status: http.StatusOK}

			// Call the next handler
			next.ServeHTTP(wrapped, r)

			// Record metrics
			duration := time.Since(start).Seconds()
			path := normalizePath(r.URL.Path)

			m.HTTPRequestsTotal.WithLabelValues(
				r.Method,
				path,
				strconv.Itoa(wrapped.status),
			).Inc()

			m.HTTPRequestDuration.WithLabelValues(
				r.Method,
				path,
			).Observe(duration)
		})
	}
}

// statusRecorder wraps http.ResponseWriter to capture the status code.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

// normalizePath normalizes URL paths to avoid high-cardinality metrics.
func normalizePath(path string) string {
	// Normalize known dynamic paths
	switch {
	case path == "/":
		return "/"
	case path == "/login":
		return "/login"
	case path == "/logout":
		return "/logout"
	case path == "/dhcp":
		return "/dhcp"
	case path == "/network":
		return "/network"
	case path == "/firewall":
		return "/firewall"
	case path == "/connections":
		return "/connections"
	case path == "/services":
		return "/services"
	case len(path) > 4 && path[:4] == "/api":
		// Keep API paths but normalize service names
		return normalizeAPIPath(path)
	case len(path) > 7 && path[:7] == "/static":
		return "/static/*"
	default:
		return path
	}
}

// normalizeAPIPath normalizes API paths.
func normalizeAPIPath(path string) string {
	// Common API paths
	switch path {
	case "/api/services/status":
		return "/api/services/status"
	case "/api/services/status.json":
		return "/api/services/status.json"
	case "/api/network/interfaces":
		return "/api/network/interfaces"
	case "/api/network/interfaces.json":
		return "/api/network/interfaces.json"
	case "/api/stats":
		return "/api/stats"
	case "/api/dhcp/leases":
		return "/api/dhcp/leases"
	case "/api/network/ping":
		return "/api/network/ping"
	case "/api/network/traceroute":
		return "/api/network/traceroute"
	case "/api/network/dns":
		return "/api/network/dns"
	case "/api/network/port":
		return "/api/network/port"
	case "/api/network/dns/clear-cache":
		return "/api/network/dns/clear-cache"
	case "/api/firewall/logs":
		return "/api/firewall/logs"
	case "/api/firewall/stats":
		return "/api/firewall/stats"
	case "/api/firewall/stream":
		return "/api/firewall/stream"
	case "/api/connections":
		return "/api/connections"
	case "/api/connections/stats":
		return "/api/connections/stats"
	}

	// Normalize service restart paths: /api/services/{name}/restart -> /api/services/*/restart
	if len(path) > 14 && path[:14] == "/api/services/" {
		return "/api/services/*/restart"
	}

	return path
}

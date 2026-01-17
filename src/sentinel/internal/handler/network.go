package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/rs/zerolog/log"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// NetworkHandler handles network diagnostics pages and API endpoints.
type NetworkHandler struct {
	sessions    *auth.SessionManager
	cfg         *config.Config
	diagnostics *collector.DiagnosticsRunner
	adguard     *collector.AdGuardCollector
	lldp        *collector.LLDPCollector
}

// NewNetworkHandler creates a new network diagnostics handler.
func NewNetworkHandler(sessions *auth.SessionManager, cfg *config.Config, diagnostics *collector.DiagnosticsRunner, adguard *collector.AdGuardCollector, lldp *collector.LLDPCollector) *NetworkHandler {
	return &NetworkHandler{
		sessions:    sessions,
		cfg:         cfg,
		diagnostics: diagnostics,
		adguard:     adguard,
		lldp:        lldp,
	}
}

// NetworkPage renders the network diagnostics page.
func (h *NetworkHandler) NetworkPage(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)

	params := pages.NetworkPageParams{
		Username:       user.Username,
		Role:           user.Role,
		AllowedTargets: h.cfg.Diagnostics.AllowedTargets,
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	pages.NetworkPage(params).Render(r.Context(), w)
}

// Ping executes a ping command and returns results as HTML partial.
func (h *NetworkHandler) Ping(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Invalid form data", http.StatusBadRequest)
		return
	}

	host := r.FormValue("host")
	if host == "" {
		http.Error(w, "Host is required", http.StatusBadRequest)
		return
	}

	count := 4
	if c := r.FormValue("count"); c != "" {
		if n, err := strconv.Atoi(c); err == nil && n > 0 && n <= 10 {
			count = n
		}
	}

	user := h.sessions.GetUser(r)
	log.Info().
		Str("user", user.Username).
		Str("host", host).
		Int("count", count).
		Msg("Ping requested")

	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	result, err := h.diagnostics.Ping(ctx, host, count)
	if err != nil {
		log.Error().Err(err).Str("host", host).Msg("Ping failed")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		pages.PingResultPartial(pages.PingResult{
			Error: err.Error(),
		}).Render(r.Context(), w)
		return
	}

	// Convert to template type
	responseTimes := make([]string, len(result.ResponseTime))
	for i, rt := range result.ResponseTime {
		responseTimes[i] = collector.FormatRTT(rt)
	}

	pageResult := pages.PingResult{
		Host:          result.Host,
		IP:            result.IP,
		PacketsSent:   result.PacketsSent,
		PacketsRecv:   result.PacketsRecv,
		PacketLoss:    result.PacketLoss,
		MinRTT:        collector.FormatRTT(result.MinRTT),
		AvgRTT:        collector.FormatRTT(result.AvgRTT),
		MaxRTT:        collector.FormatRTT(result.MaxRTT),
		ResponseTimes: responseTimes,
		Error:         result.Error,
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	pages.PingResultPartial(pageResult).Render(r.Context(), w)
}

// Traceroute executes a traceroute command and returns results as HTML partial.
func (h *NetworkHandler) Traceroute(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Invalid form data", http.StatusBadRequest)
		return
	}

	host := r.FormValue("host")
	if host == "" {
		http.Error(w, "Host is required", http.StatusBadRequest)
		return
	}

	user := h.sessions.GetUser(r)
	log.Info().
		Str("user", user.Username).
		Str("host", host).
		Msg("Traceroute requested")

	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()

	result, err := h.diagnostics.Traceroute(ctx, host)
	if err != nil {
		log.Error().Err(err).Str("host", host).Msg("Traceroute failed")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		pages.TracerouteResultPartial(pages.TracerouteResult{
			Error: err.Error(),
		}).Render(r.Context(), w)
		return
	}

	// Convert to template type
	hops := make([]pages.TracerouteHop, len(result.Hops))
	for i, hop := range result.Hops {
		rtts := make([]string, len(hop.RTT))
		for j, rtt := range hop.RTT {
			rtts[j] = collector.FormatRTT(rtt)
		}
		hops[i] = pages.TracerouteHop{
			Number:  hop.Number,
			Host:    hop.Host,
			IP:      hop.IP,
			RTT:     rtts,
			Timeout: hop.Timeout,
		}
	}

	pageResult := pages.TracerouteResult{
		Host:  result.Host,
		Hops:  hops,
		Error: result.Error,
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	pages.TracerouteResultPartial(pageResult).Render(r.Context(), w)
}

// DNSLookup performs a DNS lookup and returns results as HTML partial.
func (h *NetworkHandler) DNSLookup(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Invalid form data", http.StatusBadRequest)
		return
	}

	query := r.FormValue("query")
	if query == "" {
		http.Error(w, "Query is required", http.StatusBadRequest)
		return
	}

	queryType := r.FormValue("type")
	if queryType == "" {
		queryType = "A"
	}

	server := r.FormValue("server")

	user := h.sessions.GetUser(r)
	log.Info().
		Str("user", user.Username).
		Str("query", query).
		Str("type", queryType).
		Str("server", server).
		Msg("DNS lookup requested")

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	result, err := h.diagnostics.DNSLookup(ctx, query, queryType, server)
	if err != nil {
		log.Error().Err(err).Str("query", query).Msg("DNS lookup failed")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		pages.DNSResultPartial(pages.DNSResult{
			Error: err.Error(),
		}).Render(r.Context(), w)
		return
	}

	// Convert to template type
	answers := make([]pages.DNSAnswer, len(result.Answers))
	for i, answer := range result.Answers {
		answers[i] = pages.DNSAnswer{
			Name:  answer.Name,
			Type:  answer.Type,
			TTL:   answer.TTL,
			Value: answer.Value,
		}
	}

	pageResult := pages.DNSResult{
		Query:     result.Query,
		QueryType: result.QueryType,
		Server:    result.Server,
		Answers:   answers,
		QueryTime: collector.FormatRTT(result.QueryTime),
		Error:     result.Error,
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	pages.DNSResultPartial(pageResult).Render(r.Context(), w)
}

// PortCheck checks if a port is open and returns results as HTML partial.
func (h *NetworkHandler) PortCheck(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Invalid form data", http.StatusBadRequest)
		return
	}

	host := r.FormValue("host")
	if host == "" {
		http.Error(w, "Host is required", http.StatusBadRequest)
		return
	}

	portStr := r.FormValue("port")
	if portStr == "" {
		http.Error(w, "Port is required", http.StatusBadRequest)
		return
	}

	port, err := strconv.Atoi(portStr)
	if err != nil || port < 1 || port > 65535 {
		http.Error(w, "Invalid port number", http.StatusBadRequest)
		return
	}

	user := h.sessions.GetUser(r)
	log.Info().
		Str("user", user.Username).
		Str("host", host).
		Int("port", port).
		Msg("Port check requested")

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	result, err := h.diagnostics.PortCheck(ctx, host, port)
	if err != nil {
		log.Error().Err(err).Str("host", host).Int("port", port).Msg("Port check failed")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		pages.PortResultPartial(pages.PortResult{
			Error: err.Error(),
		}).Render(r.Context(), w)
		return
	}

	pageResult := pages.PortResult{
		Host:    result.Host,
		Port:    result.Port,
		Open:    result.Open,
		Latency: collector.FormatRTT(result.Latency),
		Error:   result.Error,
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	pages.PortResultPartial(pageResult).Render(r.Context(), w)
}

// ClearDNSCache clears the AdGuard Home DNS cache.
func (h *NetworkHandler) ClearDNSCache(w http.ResponseWriter, r *http.Request) {
	if !h.sessions.HasMinRole(r, "operator") {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}

	if h.adguard == nil {
		http.Error(w, "AdGuard not configured", http.StatusServiceUnavailable)
		return
	}

	user := h.sessions.GetUser(r)
	log.Info().
		Str("user", user.Username).
		Msg("DNS cache clear requested")

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	if err := h.adguard.ClearDNSCache(ctx); err != nil {
		log.Error().Err(err).Msg("Failed to clear DNS cache")
		http.Error(w, "Failed to clear DNS cache: "+err.Error(), http.StatusInternalServerError)
		return
	}

	log.Info().Msg("DNS cache cleared successfully")
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"status": "ok", "message": "DNS cache cleared"}`))
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

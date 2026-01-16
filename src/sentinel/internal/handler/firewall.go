package handler

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"forge.internal/nemo/avalanche/src/sentinel/internal/auth"
	"forge.internal/nemo/avalanche/src/sentinel/internal/collector"
	"forge.internal/nemo/avalanche/src/sentinel/internal/config"
	"forge.internal/nemo/avalanche/src/sentinel/templates/pages"
)

// FirewallHandler handles firewall log pages and API.
type FirewallHandler struct {
	sessions *auth.SessionManager
	cfg      *config.Config
	firewall *collector.FirewallCollector
	dnsCache *collector.DNSCache
}

// NewFirewallHandler creates a new firewall handler.
func NewFirewallHandler(sessions *auth.SessionManager, cfg *config.Config, firewall *collector.FirewallCollector, dnsCache *collector.DNSCache) *FirewallHandler {
	return &FirewallHandler{
		sessions: sessions,
		cfg:      cfg,
		firewall: firewall,
		dnsCache: dnsCache,
	}
}

// FirewallPage renders the firewall logs page.
func (h *FirewallHandler) FirewallPage(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Redirect(w, r, "/login", http.StatusSeeOther)
		return
	}

	params := pages.FirewallParams{
		Username: user.Username,
		Role:     user.Role,
	}

	// Get initial stats
	if h.firewall != nil {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		if stats, err := h.firewall.GetStats(ctx, "1 hour ago"); err == nil {
			params.Stats = stats
		}
	}

	component := pages.FirewallPage(params)
	component.Render(r.Context(), w)
}

// GetLogs returns firewall logs as JSON or HTML partial.
func (h *FirewallHandler) GetLogs(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.firewall == nil {
		http.Error(w, "Firewall collector not configured", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	// Parse query parameters
	limitStr := r.URL.Query().Get("limit")
	limit := 100
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	since := r.URL.Query().Get("since")
	if since == "" {
		since = "1 hour ago"
	}

	search := r.URL.Query().Get("search")
	action := r.URL.Query().Get("action")
	protocol := r.URL.Query().Get("protocol")

	// Get logs
	logs, err := h.firewall.GetLogs(ctx, limit*2, since) // Get more, then filter
	if err != nil {
		http.Error(w, "Failed to get logs: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Filter logs
	filtered := make([]collector.FirewallLogEntry, 0, len(logs))
	for _, entry := range logs {
		// Filter by action
		if action != "" && !strings.EqualFold(entry.Action, action) {
			continue
		}

		// Filter by protocol
		if protocol != "" && !strings.EqualFold(entry.Protocol, protocol) {
			continue
		}

		// Filter by search term
		if search != "" {
			search = strings.ToLower(search)
			if !strings.Contains(strings.ToLower(entry.SrcIP), search) &&
				!strings.Contains(strings.ToLower(entry.DstIP), search) &&
				!strings.Contains(strconv.Itoa(entry.SrcPort), search) &&
				!strings.Contains(strconv.Itoa(entry.DstPort), search) &&
				!strings.Contains(strings.ToLower(entry.InInterface), search) {
				continue
			}
		}

		filtered = append(filtered, entry)
		if len(filtered) >= limit {
			break
		}
	}

	// Enrich entries with geolocation and hostname
	h.enrichEntries(filtered)

	// Check if client wants JSON or HTML
	accept := r.Header.Get("Accept")
	if strings.Contains(accept, "application/json") {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(filtered)
		return
	}

	// Return HTML partial for htmx
	w.Header().Set("Content-Type", "text/html")
	component := pages.FirewallTable(filtered)
	component.Render(r.Context(), w)
}

// enrichEntries adds hostname data to log entries.
func (h *FirewallHandler) enrichEntries(entries []collector.FirewallLogEntry) {
	for i := range entries {
		// Add reverse DNS (async lookup - returns cached or empty)
		if h.dnsCache != nil {
			entries[i].SrcHostname = h.dnsCache.LookupAddrAsync(entries[i].SrcIP)
		}
	}
}

// GetStats returns firewall statistics.
func (h *FirewallHandler) GetStats(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.firewall == nil {
		http.Error(w, "Firewall collector not configured", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	since := r.URL.Query().Get("since")
	if since == "" {
		since = "1 hour ago"
	}

	stats, err := h.firewall.GetStats(ctx, since)
	if err != nil {
		http.Error(w, "Failed to get stats: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Check if client wants JSON or HTML
	accept := r.Header.Get("Accept")
	if strings.Contains(accept, "application/json") {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(stats)
		return
	}

	// Return HTML partial for htmx
	w.Header().Set("Content-Type", "text/html")
	component := pages.FirewallStats(stats)
	component.Render(r.Context(), w)
}

// StreamLogs streams firewall logs via Server-Sent Events.
func (h *FirewallHandler) StreamLogs(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.firewall == nil {
		http.Error(w, "Firewall collector not configured", http.StatusServiceUnavailable)
		return
	}

	// Set SSE headers
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no") // Disable nginx buffering

	// Use ResponseController to access Flusher through wrapped ResponseWriters
	// This works with chi middleware that wraps the ResponseWriter
	rc := http.NewResponseController(w)

	// Test if we can flush
	if err := rc.Flush(); err != nil {
		http.Error(w, "Streaming not supported", http.StatusInternalServerError)
		return
	}

	// Send initial connection message
	fmt.Fprintf(w, "event: connected\ndata: {\"status\": \"connected\"}\n\n")
	rc.Flush()

	// Stream logs
	ctx := r.Context()
	err := h.firewall.StreamLogs(ctx, func(entry collector.FirewallLogEntry) {
		// Enrich entry with hostname
		if h.dnsCache != nil {
			entry.SrcHostname = h.dnsCache.LookupAddrAsync(entry.SrcIP)
		}

		// Convert entry to JSON
		data, err := json.Marshal(entry)
		if err != nil {
			return
		}

		// Send SSE event
		fmt.Fprintf(w, "event: log\ndata: %s\n\n", data)
		rc.Flush()
	})

	if err != nil && err != context.Canceled {
		fmt.Fprintf(w, "event: error\ndata: {\"error\": \"%s\"}\n\n", err.Error())
		rc.Flush()
	}
}

// ChartDataPoint represents a single data point for the time-series chart.
type ChartDataPoint struct {
	Time   string `json:"time"`
	Drop   int    `json:"drop"`
	Reject int    `json:"reject"`
	Accept int    `json:"accept"`
	Log    int    `json:"log"`
}

// GetChartData returns time-bucketed data for the firewall chart.
func (h *FirewallHandler) GetChartData(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.firewall == nil {
		http.Error(w, "Firewall collector not configured", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	since := r.URL.Query().Get("since")
	if since == "" {
		since = "1 hour ago"
	}

	// Get logs (no limit for chart data)
	logs, err := h.firewall.GetLogs(ctx, 0, since)
	if err != nil {
		http.Error(w, "Failed to get logs: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Determine bucket size based on time range
	bucketMinutes := 5
	if strings.Contains(since, "24 hour") {
		bucketMinutes = 30
	} else if strings.Contains(since, "6 hour") {
		bucketMinutes = 15
	}

	// Bucket logs by time
	buckets := make(map[string]*ChartDataPoint)
	for _, entry := range logs {
		// Round timestamp to bucket
		bucket := entry.Timestamp.Truncate(time.Duration(bucketMinutes) * time.Minute)
		key := bucket.Format("15:04")

		if _, ok := buckets[key]; !ok {
			buckets[key] = &ChartDataPoint{Time: key}
		}

		switch entry.Action {
		case "DROP":
			buckets[key].Drop++
		case "REJECT":
			buckets[key].Reject++
		case "ACCEPT":
			buckets[key].Accept++
		default:
			buckets[key].Log++
		}
	}

	// Convert to sorted slice
	data := make([]ChartDataPoint, 0, len(buckets))
	for _, point := range buckets {
		data = append(data, *point)
	}

	// Sort by time
	for i := 0; i < len(data)-1; i++ {
		for j := i + 1; j < len(data); j++ {
			if data[i].Time > data[j].Time {
				data[i], data[j] = data[j], data[i]
			}
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

// aggregatedLogEntry is the internal representation for aggregation.
type aggregatedLogEntry struct {
	SrcIP     string
	DstPort   int
	Protocol  string
	Action    string
	Count     int
	FirstSeen time.Time
	LastSeen  time.Time
}

// aggregatedLogJSON is the JSON response format.
type aggregatedLogJSON struct {
	SrcIP     string `json:"src_ip"`
	DstPort   int    `json:"dst_port"`
	Protocol  string `json:"protocol"`
	Action    string `json:"action"`
	Count     int    `json:"count"`
	FirstSeen string `json:"first_seen"`
	LastSeen  string `json:"last_seen"`
}

// GetAggregatedLogs returns aggregated firewall logs grouped by source IP, dest port, and action.
func (h *FirewallHandler) GetAggregatedLogs(w http.ResponseWriter, r *http.Request) {
	user := h.sessions.GetUser(r)
	if user == nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if h.firewall == nil {
		http.Error(w, "Firewall collector not configured", http.StatusServiceUnavailable)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	since := r.URL.Query().Get("since")
	if since == "" {
		since = "1 hour ago"
	}

	action := r.URL.Query().Get("action")
	protocol := r.URL.Query().Get("protocol")
	search := r.URL.Query().Get("search")

	// Get all logs for the time range
	logs, err := h.firewall.GetLogs(ctx, 0, since)
	if err != nil {
		http.Error(w, "Failed to get logs: "+err.Error(), http.StatusInternalServerError)
		return
	}

	// Aggregate logs
	type aggKey struct {
		SrcIP    string
		DstPort  int
		Protocol string
		Action   string
	}
	aggregates := make(map[aggKey]*aggregatedLogEntry)

	for _, entry := range logs {
		// Apply filters
		if action != "" && !strings.EqualFold(entry.Action, action) {
			continue
		}
		if protocol != "" && !strings.EqualFold(entry.Protocol, protocol) {
			continue
		}
		if search != "" {
			searchLower := strings.ToLower(search)
			if !strings.Contains(strings.ToLower(entry.SrcIP), searchLower) &&
				!strings.Contains(strings.ToLower(entry.DstIP), searchLower) &&
				!strings.Contains(strconv.Itoa(entry.DstPort), searchLower) {
				continue
			}
		}

		key := aggKey{
			SrcIP:    entry.SrcIP,
			DstPort:  entry.DstPort,
			Protocol: entry.Protocol,
			Action:   entry.Action,
		}

		if agg, ok := aggregates[key]; ok {
			agg.Count++
			if entry.Timestamp.Before(agg.FirstSeen) {
				agg.FirstSeen = entry.Timestamp
			}
			if entry.Timestamp.After(agg.LastSeen) {
				agg.LastSeen = entry.Timestamp
			}
		} else {
			aggregates[key] = &aggregatedLogEntry{
				SrcIP:     entry.SrcIP,
				DstPort:   entry.DstPort,
				Protocol:  entry.Protocol,
				Action:    entry.Action,
				Count:     1,
				FirstSeen: entry.Timestamp,
				LastSeen:  entry.Timestamp,
			}
		}
	}

	// Convert to slice and sort by count descending
	result := make([]aggregatedLogEntry, 0, len(aggregates))
	for _, agg := range aggregates {
		result = append(result, *agg)
	}

	// Sort by count (descending)
	for i := 0; i < len(result)-1; i++ {
		for j := i + 1; j < len(result); j++ {
			if result[j].Count > result[i].Count {
				result[i], result[j] = result[j], result[i]
			}
		}
	}

	// Limit to top 100
	if len(result) > 100 {
		result = result[:100]
	}

	// Check if client wants JSON or HTML
	accept := r.Header.Get("Accept")
	if strings.Contains(accept, "application/json") {
		// Convert to JSON format with string timestamps
		jsonResult := make([]aggregatedLogJSON, len(result))
		for i, r := range result {
			jsonResult[i] = aggregatedLogJSON{
				SrcIP:     r.SrcIP,
				DstPort:   r.DstPort,
				Protocol:  r.Protocol,
				Action:    r.Action,
				Count:     r.Count,
				FirstSeen: r.FirstSeen.Format("15:04:05"),
				LastSeen:  r.LastSeen.Format("15:04:05"),
			}
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(jsonResult)
		return
	}

	// Convert to display format for HTML
	displayResult := make([]pages.AggregatedLogEntry, len(result))
	for i, r := range result {
		displayResult[i] = pages.AggregatedLogEntry{
			SrcIP:     r.SrcIP,
			DstPort:   r.DstPort,
			Protocol:  r.Protocol,
			Action:    r.Action,
			Count:     r.Count,
			FirstSeen: r.FirstSeen.Format("15:04:05"),
			LastSeen:  r.LastSeen.Format("15:04:05"),
		}
	}

	// Return HTML partial for htmx
	w.Header().Set("Content-Type", "text/html")
	component := pages.FirewallAggregatedTable(displayResult)
	component.Render(r.Context(), w)
}

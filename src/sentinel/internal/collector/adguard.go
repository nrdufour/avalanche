package collector

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// AdGuardStats represents AdGuard Home statistics.
type AdGuardStats struct {
	NumDNSQueries           int64    `json:"num_dns_queries"`
	NumBlockedFiltering     int64    `json:"num_blocked_filtering"`
	NumReplacedSafebrowsing int64    `json:"num_replaced_safebrowsing"`
	NumReplacedSafesearch   int64    `json:"num_replaced_safesearch"`
	NumReplacedParental     int64    `json:"num_replaced_parental"`
	AvgProcessingTime       float64  `json:"avg_processing_time"`
	TopQueriedDomains       []TopItem `json:"top_queried_domains"`
	TopBlockedDomains       []TopItem `json:"top_blocked_domains"`
	TopClients              []TopItem `json:"top_clients"`
}

// TopItem represents a top item (domain or client) with count.
type TopItem struct {
	Name  string
	Count int64
}

// UnmarshalJSON custom unmarshaler for TopItem since AdGuard uses a map format.
func (t *TopItem) UnmarshalJSON(data []byte) error {
	// AdGuard returns top items as [{"domain.com": 123}, ...]
	var m map[string]int64
	if err := json.Unmarshal(data, &m); err != nil {
		return err
	}
	for k, v := range m {
		t.Name = k
		t.Count = v
		break
	}
	return nil
}

// AdGuardStatus represents AdGuard Home status.
type AdGuardStatus struct {
	ProtectionEnabled bool     `json:"protection_enabled"`
	Running           bool     `json:"running"`
	FilteringEnabled  bool     `json:"filtering_enabled"`
	DHCPAvailable     bool     `json:"dhcp_available"`
	Version           string   `json:"version"`
	DNSAddresses      []string `json:"dns_addresses"`
	DNSPort           int      `json:"dns_port"`
	HTTPPort          int      `json:"http_port"`
}

// AdGuardCollector collects data from AdGuard Home API.
type AdGuardCollector struct {
	baseURL  string
	username string
	password string
	client   *http.Client
}

// NewAdGuardCollector creates a new AdGuard collector.
func NewAdGuardCollector(baseURL, username, password string) *AdGuardCollector {
	return &AdGuardCollector{
		baseURL:  baseURL,
		username: username,
		password: password,
		client: &http.Client{
			Timeout: 10 * time.Second,
		},
	}
}

// doRequest performs an authenticated HTTP request.
func (c *AdGuardCollector) doRequest(ctx context.Context, method, path string, body io.Reader) (*http.Response, error) {
	url := c.baseURL + path
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return nil, err
	}

	if c.username != "" && c.password != "" {
		req.SetBasicAuth(c.username, c.password)
	}

	req.Header.Set("Content-Type", "application/json")

	return c.client.Do(req)
}

// GetStatus returns the current AdGuard Home status.
func (c *AdGuardCollector) GetStatus(ctx context.Context) (*AdGuardStatus, error) {
	resp, err := c.doRequest(ctx, "GET", "/control/status", nil)
	if err != nil {
		return nil, fmt.Errorf("requesting status: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	var status AdGuardStatus
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		return nil, fmt.Errorf("decoding response: %w", err)
	}

	return &status, nil
}

// GetStats returns AdGuard Home statistics.
func (c *AdGuardCollector) GetStats(ctx context.Context) (*AdGuardStats, error) {
	resp, err := c.doRequest(ctx, "GET", "/control/stats", nil)
	if err != nil {
		return nil, fmt.Errorf("requesting stats: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	var stats AdGuardStats
	if err := json.NewDecoder(resp.Body).Decode(&stats); err != nil {
		return nil, fmt.Errorf("decoding response: %w", err)
	}

	return &stats, nil
}

// ClearDNSCache clears the AdGuard Home DNS cache.
func (c *AdGuardCollector) ClearDNSCache(ctx context.Context) error {
	resp, err := c.doRequest(ctx, "POST", "/control/cache_clear", nil)
	if err != nil {
		return fmt.Errorf("clearing cache: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	return nil
}

// QueryLogEntry represents a single DNS query log entry.
type QueryLogEntry struct {
	Time       time.Time `json:"time"`
	QH         string    `json:"QH"`  // Query hostname
	QT         string    `json:"QT"`  // Query type
	QC         string    `json:"QC"`  // Query class
	CP         string    `json:"CP"`  // Client proto
	Client     string    `json:"client"`
	ClientInfo struct {
		Name string `json:"name"`
	} `json:"client_info"`
	Upstream string `json:"upstream"`
	Answer   []struct {
		Type  int    `json:"type"`
		Value string `json:"value"`
		TTL   int    `json:"ttl"`
	} `json:"answer"`
	Reason     string  `json:"reason"`
	Elapsed    float64 `json:"elapsedMs"`
	Cached     bool    `json:"cached"`
	FilteredBy string  `json:"filteredBy"`
}

// QueryLogResponse represents the query log API response.
type QueryLogResponse struct {
	Data   []QueryLogEntry `json:"data"`
	Oldest string          `json:"oldest"`
}

// GetQueryLog returns recent DNS query log entries.
func (c *AdGuardCollector) GetQueryLog(ctx context.Context, limit int) (*QueryLogResponse, error) {
	if limit <= 0 {
		limit = 100
	}

	path := fmt.Sprintf("/control/querylog?limit=%d", limit)
	resp, err := c.doRequest(ctx, "GET", path, nil)
	if err != nil {
		return nil, fmt.Errorf("requesting query log: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	var log QueryLogResponse
	if err := json.NewDecoder(resp.Body).Decode(&log); err != nil {
		return nil, fmt.Errorf("decoding response: %w", err)
	}

	return &log, nil
}

// FilteringStatus represents the filtering configuration status.
type FilteringStatus struct {
	Enabled       bool `json:"enabled"`
	Interval      int  `json:"interval"`
	Filters       []FilterEntry `json:"filters"`
	WhitelistFilters []FilterEntry `json:"whitelist_filters"`
	UserRules     []string `json:"user_rules"`
}

// FilterEntry represents a filter list entry.
type FilterEntry struct {
	ID          int64  `json:"id"`
	URL         string `json:"url"`
	Name        string `json:"name"`
	Enabled     bool   `json:"enabled"`
	LastUpdated string `json:"last_updated"`
	RulesCount  int    `json:"rules_count"`
}

// GetFilteringStatus returns the current filtering configuration.
func (c *AdGuardCollector) GetFilteringStatus(ctx context.Context) (*FilteringStatus, error) {
	resp, err := c.doRequest(ctx, "GET", "/control/filtering/status", nil)
	if err != nil {
		return nil, fmt.Errorf("requesting filtering status: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	var status FilteringStatus
	if err := json.NewDecoder(resp.Body).Decode(&status); err != nil {
		return nil, fmt.Errorf("decoding response: %w", err)
	}

	return &status, nil
}

// BlockedPercentage returns the percentage of blocked queries.
func (s *AdGuardStats) BlockedPercentage() float64 {
	if s.NumDNSQueries == 0 {
		return 0
	}
	total := s.NumBlockedFiltering + s.NumReplacedSafebrowsing + s.NumReplacedParental
	return float64(total) / float64(s.NumDNSQueries) * 100
}

// TotalBlocked returns the total number of blocked queries.
func (s *AdGuardStats) TotalBlocked() int64 {
	return s.NumBlockedFiltering + s.NumReplacedSafebrowsing + s.NumReplacedParental + s.NumReplacedSafesearch
}

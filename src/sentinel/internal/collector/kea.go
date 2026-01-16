package collector

import (
	"encoding/json"
	"fmt"
	"net"
	"sort"
	"strings"
	"time"
)

// DHCPLease represents a DHCP lease from Kea.
type DHCPLease struct {
	IPAddress     string
	HWAddress     string
	ClientID      string
	ValidLifetime int64
	Expire        time.Time
	SubnetID      int
	FQDN          string
	Hostname      string
	State         int // 0=default, 1=declined, 2=expired-reclaimed
}

// KeaCollector collects DHCP lease information from Kea.
type KeaCollector struct {
	controlSocket string
}

// NewKeaCollector creates a new Kea collector.
// The leaseFile parameter is kept for backward compatibility but ignored.
func NewKeaCollector(leaseFile, controlSocket string) *KeaCollector {
	return &KeaCollector{
		controlSocket: controlSocket,
	}
}

// keaResponse represents the response from Kea control socket.
type keaResponse struct {
	Result    int    `json:"result"`
	Text      string `json:"text"`
	Arguments struct {
		Leases []keaLease `json:"leases"`
	} `json:"arguments"`
}

// keaLease represents a lease in Kea API response.
type keaLease struct {
	IPAddress  string `json:"ip-address"`
	HWAddress  string `json:"hw-address"`
	ClientID   string `json:"client-id"`
	Hostname   string `json:"hostname"`
	State      int    `json:"state"`
	SubnetID   int    `json:"subnet-id"`
	CLTT       int64  `json:"cltt"`       // Client Last Transaction Time
	ValidLft   int64  `json:"valid-lft"`  // Valid lifetime in seconds
	FqdnFwd    bool   `json:"fqdn-fwd"`
	FqdnRev    bool   `json:"fqdn-rev"`
}

// sendCommand sends a command to the Kea control socket and returns the response.
func (c *KeaCollector) sendCommand(command string) ([]byte, error) {
	if c.controlSocket == "" {
		return nil, fmt.Errorf("control socket not configured")
	}

	conn, err := net.DialTimeout("unix", c.controlSocket, 5*time.Second)
	if err != nil {
		return nil, fmt.Errorf("connecting to control socket: %w", err)
	}
	defer conn.Close()

	// Set read/write deadline
	conn.SetDeadline(time.Now().Add(10 * time.Second))

	// Send command
	cmd := fmt.Sprintf(`{"command":"%s"}`, command)
	if _, err := conn.Write([]byte(cmd)); err != nil {
		return nil, fmt.Errorf("sending command: %w", err)
	}

	// Read response
	buf := make([]byte, 1024*1024) // 1MB buffer for large lease lists
	n, err := conn.Read(buf)
	if err != nil {
		return nil, fmt.Errorf("reading response: %w", err)
	}

	return buf[:n], nil
}

// GetActiveLeases returns all active leases from the Kea control socket API.
func (c *KeaCollector) GetActiveLeases() ([]DHCPLease, error) {
	data, err := c.sendCommand("lease4-get-all")
	if err != nil {
		return nil, err
	}

	var resp keaResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, fmt.Errorf("parsing response: %w", err)
	}

	if resp.Result != 0 && resp.Result != 3 {
		// Result 3 means "no leases found" which is valid
		return nil, fmt.Errorf("kea error (result=%d): %s", resp.Result, resp.Text)
	}

	leases := make([]DHCPLease, 0, len(resp.Arguments.Leases))
	for _, kl := range resp.Arguments.Leases {
		// Calculate expiration time: cltt + valid-lft
		expire := time.Unix(kl.CLTT+kl.ValidLft, 0)

		// Clean up hostname (remove trailing dot and .internal suffix for display)
		hostname := strings.TrimSuffix(kl.Hostname, ".")
		hostname = strings.TrimSuffix(hostname, ".internal")

		lease := DHCPLease{
			IPAddress:     kl.IPAddress,
			HWAddress:     kl.HWAddress,
			ClientID:      kl.ClientID,
			ValidLifetime: kl.ValidLft,
			Expire:        expire,
			SubnetID:      kl.SubnetID,
			Hostname:      hostname,
			FQDN:          kl.Hostname,
			State:         kl.State,
		}
		leases = append(leases, lease)
	}

	// Sort by hostname (case-insensitive)
	sort.Slice(leases, func(i, j int) bool {
		return strings.ToLower(leases[i].Hostname) < strings.ToLower(leases[j].Hostname)
	})

	return leases, nil
}

// GetLeaseCount returns the count of active leases.
func (c *KeaCollector) GetLeaseCount() (int, error) {
	leases, err := c.GetActiveLeases()
	if err != nil {
		return 0, err
	}
	return len(leases), nil
}

// SearchLeases searches leases by IP, MAC, or hostname.
func (c *KeaCollector) SearchLeases(query string) ([]DHCPLease, error) {
	leases, err := c.GetActiveLeases()
	if err != nil {
		return nil, err
	}

	query = strings.ToLower(query)
	results := make([]DHCPLease, 0)

	for _, lease := range leases {
		if strings.Contains(strings.ToLower(lease.IPAddress), query) ||
			strings.Contains(strings.ToLower(lease.HWAddress), query) ||
			strings.Contains(strings.ToLower(lease.Hostname), query) ||
			strings.Contains(strings.ToLower(lease.FQDN), query) {
			results = append(results, lease)
		}
	}

	return results, nil
}

// IsExpired returns true if the lease has expired.
func (l *DHCPLease) IsExpired() bool {
	return time.Now().After(l.Expire)
}

// ExpiresIn returns the duration until the lease expires.
func (l *DHCPLease) ExpiresIn() time.Duration {
	return time.Until(l.Expire)
}

// ExpiresInString returns a human-readable expiration string.
func (l *DHCPLease) ExpiresInString() string {
	if l.IsExpired() {
		return "Expired"
	}

	d := l.ExpiresIn()
	hours := int(d.Hours())
	minutes := int(d.Minutes()) % 60

	if hours > 24 {
		days := hours / 24
		hours = hours % 24
		return fmt.Sprintf("%dd %dh", days, hours)
	}
	if hours > 0 {
		return fmt.Sprintf("%dh %dm", hours, minutes)
	}
	return fmt.Sprintf("%dm", minutes)
}

// GetNetwork returns the network/subnet the IP belongs to.
func (l *DHCPLease) GetNetwork() string {
	ip := net.ParseIP(l.IPAddress)
	if ip == nil {
		return "unknown"
	}

	// Determine network based on IP range
	if ip4 := ip.To4(); ip4 != nil {
		switch {
		case ip4[0] == 10 && ip4[1] == 0 && ip4[2] == 0:
			return "lan0"
		case ip4[0] == 10 && ip4[1] == 1 && ip4[2] == 0:
			return "lab0"
		case ip4[0] == 10 && ip4[1] == 2 && ip4[2] == 0:
			return "lab1"
		}
	}

	return fmt.Sprintf("subnet-%d", l.SubnetID)
}

// LeaseStats contains aggregate lease statistics.
type LeaseStats struct {
	Total     int
	Active    int
	ByNetwork map[string]int
}

// GetLeaseStats returns aggregate statistics about leases.
func (c *KeaCollector) GetLeaseStats() (*LeaseStats, error) {
	leases, err := c.GetActiveLeases()
	if err != nil {
		return nil, err
	}

	stats := &LeaseStats{
		Total:     len(leases),
		Active:    len(leases),
		ByNetwork: make(map[string]int),
	}

	for _, lease := range leases {
		network := lease.GetNetwork()
		stats.ByNetwork[network]++
	}

	return stats, nil
}

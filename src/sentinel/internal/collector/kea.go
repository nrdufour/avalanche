package collector

import (
	"bufio"
	"encoding/csv"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// DHCPLease represents a DHCP lease from Kea.
type DHCPLease struct {
	IPAddress    string
	HWAddress    string
	ClientID     string
	ValidLifetime int64
	Expire       time.Time
	SubnetID     int
	FQDN         string
	Hostname     string
	State        int // 0=default, 1=declined, 2=expired-reclaimed
	UserContext  string
}

// KeaCollector collects DHCP lease information from Kea.
type KeaCollector struct {
	leaseFile     string
	controlSocket string
}

// NewKeaCollector creates a new Kea collector.
func NewKeaCollector(leaseFile, controlSocket string) *KeaCollector {
	return &KeaCollector{
		leaseFile:     leaseFile,
		controlSocket: controlSocket,
	}
}

// GetLeases reads all leases from the Kea lease file.
func (c *KeaCollector) GetLeases() ([]DHCPLease, error) {
	file, err := os.Open(c.leaseFile)
	if err != nil {
		return nil, fmt.Errorf("opening lease file: %w", err)
	}
	defer file.Close()

	return c.parseLeaseFile(file)
}

// GetActiveLeases returns only active (non-expired) leases.
func (c *KeaCollector) GetActiveLeases() ([]DHCPLease, error) {
	leases, err := c.GetLeases()
	if err != nil {
		return nil, err
	}

	now := time.Now()
	active := make([]DHCPLease, 0)

	for _, lease := range leases {
		// State 0 = default (active), skip declined (1) and expired-reclaimed (2)
		if lease.State == 0 && lease.Expire.After(now) {
			active = append(active, lease)
		}
	}

	return active, nil
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

// parseLeaseFile parses the Kea CSV lease file.
// Kea lease file format (CSV with header):
// address,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn_fwd,fqdn_rev,hostname,state,user_context
func (c *KeaCollector) parseLeaseFile(r io.Reader) ([]DHCPLease, error) {
	reader := csv.NewReader(r)
	reader.FieldsPerRecord = -1 // Variable number of fields
	reader.LazyQuotes = true

	// Read header
	header, err := reader.Read()
	if err != nil {
		return nil, fmt.Errorf("reading header: %w", err)
	}

	// Build column index map
	colIndex := make(map[string]int)
	for i, col := range header {
		colIndex[col] = i
	}

	leases := make([]DHCPLease, 0)

	for {
		record, err := reader.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			// Skip malformed lines
			continue
		}

		lease := DHCPLease{}

		// Parse fields by column name
		if idx, ok := colIndex["address"]; ok && idx < len(record) {
			lease.IPAddress = record[idx]
		}
		if idx, ok := colIndex["hwaddr"]; ok && idx < len(record) {
			lease.HWAddress = normalizeMAC(record[idx])
		}
		if idx, ok := colIndex["client_id"]; ok && idx < len(record) {
			lease.ClientID = record[idx]
		}
		if idx, ok := colIndex["valid_lifetime"]; ok && idx < len(record) {
			lease.ValidLifetime, _ = strconv.ParseInt(record[idx], 10, 64)
		}
		if idx, ok := colIndex["expire"]; ok && idx < len(record) {
			expireUnix, _ := strconv.ParseInt(record[idx], 10, 64)
			lease.Expire = time.Unix(expireUnix, 0)
		}
		if idx, ok := colIndex["subnet_id"]; ok && idx < len(record) {
			lease.SubnetID, _ = strconv.Atoi(record[idx])
		}
		if idx, ok := colIndex["hostname"]; ok && idx < len(record) {
			lease.Hostname = record[idx]
		}
		if idx, ok := colIndex["fqdn_fwd"]; ok && idx < len(record) {
			// FQDN is sometimes in a separate field
			lease.FQDN = record[idx]
		}
		if idx, ok := colIndex["state"]; ok && idx < len(record) {
			lease.State, _ = strconv.Atoi(record[idx])
		}
		if idx, ok := colIndex["user_context"]; ok && idx < len(record) {
			lease.UserContext = record[idx]
		}

		// Skip empty leases
		if lease.IPAddress == "" {
			continue
		}

		leases = append(leases, lease)
	}

	return leases, nil
}

// normalizeMAC converts MAC address to standard format (aa:bb:cc:dd:ee:ff).
func normalizeMAC(mac string) string {
	// Kea may store MACs in various formats
	// Try to parse and normalize
	mac = strings.ToLower(strings.TrimSpace(mac))

	// Handle colon-separated (already standard)
	if strings.Contains(mac, ":") {
		return mac
	}

	// Handle dash-separated
	if strings.Contains(mac, "-") {
		return strings.ReplaceAll(mac, "-", ":")
	}

	// Handle no separator (aabbccddeeff)
	if len(mac) == 12 {
		return fmt.Sprintf("%s:%s:%s:%s:%s:%s",
			mac[0:2], mac[2:4], mac[4:6],
			mac[6:8], mac[8:10], mac[10:12])
	}

	return mac
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
	Expired   int
	ByNetwork map[string]int
}

// GetLeaseStats returns aggregate statistics about leases.
func (c *KeaCollector) GetLeaseStats() (*LeaseStats, error) {
	leases, err := c.GetLeases()
	if err != nil {
		return nil, err
	}

	now := time.Now()
	stats := &LeaseStats{
		Total:     len(leases),
		ByNetwork: make(map[string]int),
	}

	for _, lease := range leases {
		if lease.State == 0 && lease.Expire.After(now) {
			stats.Active++
			network := lease.GetNetwork()
			stats.ByNetwork[network]++
		} else {
			stats.Expired++
		}
	}

	return stats, nil
}

// ParseLeaseFileFromPath is a utility to parse a lease file directly.
func ParseLeaseFileFromPath(path string) ([]DHCPLease, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	collector := &KeaCollector{}
	return collector.parseLeaseFile(file)
}

// ReadLeasesWithFallback attempts to read from memfile, falling back to control socket.
func (c *KeaCollector) ReadLeasesWithFallback() ([]DHCPLease, error) {
	// Try memfile first (faster)
	leases, err := c.GetLeases()
	if err == nil {
		return leases, nil
	}

	// TODO: Implement control socket fallback
	// For now, just return the error
	return nil, err
}

// WatchLeaseFile sets up a simple polling watcher for the lease file.
// Returns a channel that receives updates when the file changes.
func (c *KeaCollector) WatchLeaseFile(interval time.Duration) (<-chan []DHCPLease, func()) {
	ch := make(chan []DHCPLease, 1)
	done := make(chan struct{})

	var lastMod time.Time

	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		defer close(ch)

		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				info, err := os.Stat(c.leaseFile)
				if err != nil {
					continue
				}

				if info.ModTime().After(lastMod) {
					lastMod = info.ModTime()
					leases, err := c.GetActiveLeases()
					if err == nil {
						select {
						case ch <- leases:
						default:
							// Channel full, skip update
						}
					}
				}
			}
		}
	}()

	stop := func() {
		close(done)
	}

	return ch, stop
}

// GetLeaseByIP finds a lease by IP address.
func (c *KeaCollector) GetLeaseByIP(ip string) (*DHCPLease, error) {
	// For efficiency, we could use the control socket API
	// For now, scan the file
	file, err := os.Open(c.leaseFile)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	// Skip header
	if scanner.Scan() {
		// Header line
	}

	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, ip+",") {
			// Found the lease, parse this line
			reader := csv.NewReader(strings.NewReader(line))
			record, err := reader.Read()
			if err != nil {
				continue
			}

			lease := DHCPLease{
				IPAddress: record[0],
			}
			if len(record) > 1 {
				lease.HWAddress = normalizeMAC(record[1])
			}
			if len(record) > 2 {
				lease.ClientID = record[2]
			}
			if len(record) > 3 {
				lease.ValidLifetime, _ = strconv.ParseInt(record[3], 10, 64)
			}
			if len(record) > 4 {
				expireUnix, _ := strconv.ParseInt(record[4], 10, 64)
				lease.Expire = time.Unix(expireUnix, 0)
			}
			if len(record) > 5 {
				lease.SubnetID, _ = strconv.Atoi(record[5])
			}
			if len(record) > 8 {
				lease.Hostname = record[8]
			}
			if len(record) > 9 {
				lease.State, _ = strconv.Atoi(record[9])
			}

			return &lease, nil
		}
	}

	return nil, fmt.Errorf("lease not found for IP: %s", ip)
}

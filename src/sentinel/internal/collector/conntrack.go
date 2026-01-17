// Package collector provides data collectors for Sentinel.
package collector

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Connection represents a tracked network connection.
type Connection struct {
	Protocol    string `json:"protocol"`
	State       string `json:"state"`
	TTL         int    `json:"ttl"`
	SrcIP       string `json:"src_ip"`
	DstIP       string `json:"dst_ip"`
	SrcPort     int    `json:"src_port"`
	DstPort     int    `json:"dst_port"`
	ReplySrcIP  string `json:"reply_src_ip,omitempty"`
	ReplyDstIP  string `json:"reply_dst_ip,omitempty"`
	ReplySrcPort int   `json:"reply_src_port,omitempty"`
	ReplyDstPort int   `json:"reply_dst_port,omitempty"`
	Packets     int64  `json:"packets,omitempty"`
	Bytes       int64  `json:"bytes,omitempty"`
	Mark        int    `json:"mark,omitempty"`
	Zone        int    `json:"zone,omitempty"`
}

// ConnectionStats provides aggregate statistics about connections.
type ConnectionStats struct {
	Total       int            `json:"total"`
	ByProtocol  map[string]int `json:"by_protocol"`
	ByState     map[string]int `json:"by_state"`
	TopSources  []IPCount      `json:"top_sources"`
	TopDests    []IPCount      `json:"top_destinations"`
}

// IPCount represents a count for an IP address.
type IPCount struct {
	IP    string `json:"ip"`
	Count int    `json:"count"`
}

// TalkerStats represents bandwidth usage for a single IP.
type TalkerStats struct {
	IP          string `json:"ip"`
	Hostname    string `json:"hostname,omitempty"`
	TotalBytes  int64  `json:"total_bytes"`
	Connections int    `json:"connections"`
}

// ConntrackCollector collects connection tracking data from netfilter conntrack.
type ConntrackCollector struct {
	conntrackPath string
	timeout       time.Duration
}

// validProtocols is the whitelist of allowed protocol values for conntrack queries.
var validProtocols = map[string]bool{
	"tcp":  true,
	"udp":  true,
	"icmp": true,
	"sctp": true,
	"gre":  true,
	"esp":  true,
	"ah":   true,
}

// NewConntrackCollector creates a new conntrack collector.
func NewConntrackCollector(timeout time.Duration) *ConntrackCollector {
	// Find conntrack binary
	conntrackPath := "/run/current-system/sw/bin/conntrack"
	if path, err := exec.LookPath("conntrack"); err == nil {
		conntrackPath = path
	}

	return &ConntrackCollector{
		conntrackPath: conntrackPath,
		timeout:       timeout,
	}
}

// GetConnections retrieves all tracked connections.
func (c *ConntrackCollector) GetConnections(ctx context.Context) ([]Connection, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, c.conntrackPath, "-L", "-o", "extended")
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	return c.parseConntrackOutput(string(output)), nil
}

// GetConnectionsByProtocol retrieves connections filtered by protocol.
func (c *ConntrackCollector) GetConnectionsByProtocol(ctx context.Context, protocol string) ([]Connection, error) {
	// Validate protocol against whitelist to prevent argument injection
	protocol = strings.ToLower(strings.TrimSpace(protocol))
	if !validProtocols[protocol] {
		return nil, fmt.Errorf("invalid protocol %q: must be one of tcp, udp, icmp, sctp, gre, esp, ah", protocol)
	}

	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, c.conntrackPath, "-L", "-p", protocol, "-o", "extended")
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	return c.parseConntrackOutput(string(output)), nil
}

// GetConnectionsByState retrieves connections filtered by state.
func (c *ConntrackCollector) GetConnectionsByState(ctx context.Context, state string) ([]Connection, error) {
	connections, err := c.GetConnections(ctx)
	if err != nil {
		return nil, err
	}

	var filtered []Connection
	for _, conn := range connections {
		if strings.EqualFold(conn.State, state) {
			filtered = append(filtered, conn)
		}
	}
	return filtered, nil
}

// GetStats retrieves aggregate connection statistics.
func (c *ConntrackCollector) GetStats(ctx context.Context) (*ConnectionStats, error) {
	connections, err := c.GetConnections(ctx)
	if err != nil {
		return nil, err
	}

	stats := &ConnectionStats{
		Total:      len(connections),
		ByProtocol: make(map[string]int),
		ByState:    make(map[string]int),
	}

	srcCounts := make(map[string]int)
	dstCounts := make(map[string]int)

	for _, conn := range connections {
		stats.ByProtocol[conn.Protocol]++
		if conn.State != "" {
			stats.ByState[conn.State]++
		}
		srcCounts[conn.SrcIP]++
		dstCounts[conn.DstIP]++
	}

	// Get top 10 sources
	stats.TopSources = getTopN(srcCounts, 10)
	stats.TopDests = getTopN(dstCounts, 10)

	return stats, nil
}

// GetCount retrieves the current connection count.
func (c *ConntrackCollector) GetCount(ctx context.Context) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, c.conntrackPath, "-C")
	output, err := cmd.Output()
	if err != nil {
		return 0, err
	}

	count, err := strconv.Atoi(strings.TrimSpace(string(output)))
	if err != nil {
		return 0, err
	}

	return count, nil
}

// GetTopTalkers retrieves the top talkers by bandwidth (internal IPs only).
// It aggregates bytes by source IP for connections originating from private IP ranges.
func (c *ConntrackCollector) GetTopTalkers(ctx context.Context, limit int) ([]TalkerStats, error) {
	connections, err := c.GetConnections(ctx)
	if err != nil {
		return nil, err
	}

	if limit <= 0 {
		limit = 10
	}

	// Aggregate bytes and connections by source IP (internal IPs only)
	talkers := make(map[string]*TalkerStats)
	for _, conn := range connections {
		// Only include internal (private) source IPs
		if !isPrivateIP(conn.SrcIP) {
			continue
		}

		if _, ok := talkers[conn.SrcIP]; !ok {
			talkers[conn.SrcIP] = &TalkerStats{IP: conn.SrcIP}
		}
		talkers[conn.SrcIP].TotalBytes += conn.Bytes
		talkers[conn.SrcIP].Connections++
	}

	// Convert to slice and sort by bytes descending
	result := make([]TalkerStats, 0, len(talkers))
	for _, t := range talkers {
		result = append(result, *t)
	}

	// Sort by TotalBytes descending
	sort.Slice(result, func(i, j int) bool {
		return result[i].TotalBytes > result[j].TotalBytes
	})

	// Limit results
	if len(result) > limit {
		result = result[:limit]
	}

	return result, nil
}

// isPrivateIP checks if an IP address is in a private range.
func isPrivateIP(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}
	return ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast()
}

// parseConntrackOutput parses the output of conntrack -L.
func (c *ConntrackCollector) parseConntrackOutput(output string) []Connection {
	var connections []Connection

	// Regex patterns for parsing conntrack output
	// Example line: ipv4     2 tcp      6 431999 ESTABLISHED src=10.0.0.112 dst=160.79.104.10 sport=35526 dport=443 src=160.79.104.10 dst=10.0.0.112 sport=443 dport=35526 [ASSURED] mark=0 use=1
	// Fields: [0]=ipv4 [1]=2 [2]=tcp [3]=6 [4]=TTL [5]=STATE or src=...
	srcIPRe := regexp.MustCompile(`src=(\S+)`)
	dstIPRe := regexp.MustCompile(`dst=(\S+)`)
	srcPortRe := regexp.MustCompile(`sport=(\d+)`)
	dstPortRe := regexp.MustCompile(`dport=(\d+)`)
	packetsRe := regexp.MustCompile(`packets=(\d+)`)
	bytesRe := regexp.MustCompile(`bytes=(\d+)`)
	markRe := regexp.MustCompile(`mark=(\d+)`)
	zoneRe := regexp.MustCompile(`zone=(\d+)`)

	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}

		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}

		conn := Connection{}

		// Parse protocol name - it's in field[2] (tcp, udp, icmp, etc.)
		// Field[0] is address family (ipv4/ipv6), field[1] is L3 proto number
		conn.Protocol = fields[2]

		// Parse TTL (fifth field, numeric) - field[4]
		if len(fields) > 4 {
			if ttl, err := strconv.Atoi(fields[4]); err == nil {
				conn.TTL = ttl
			}
		}

		// Parse state (sixth field for TCP, may not exist for UDP) - field[5]
		if len(fields) > 5 {
			state := fields[5]
			// Check if it looks like a state (all caps, not a key=value)
			if !strings.Contains(state, "=") && state == strings.ToUpper(state) {
				conn.State = state
			}
		}

		// Find all src/dst pairs - first pair is original, second is reply
		srcIPs := srcIPRe.FindAllStringSubmatch(line, -1)
		dstIPs := dstIPRe.FindAllStringSubmatch(line, -1)
		srcPorts := srcPortRe.FindAllStringSubmatch(line, -1)
		dstPorts := dstPortRe.FindAllStringSubmatch(line, -1)

		// Original direction
		if len(srcIPs) > 0 {
			conn.SrcIP = srcIPs[0][1]
		}
		if len(dstIPs) > 0 {
			conn.DstIP = dstIPs[0][1]
		}
		if len(srcPorts) > 0 {
			conn.SrcPort, _ = strconv.Atoi(srcPorts[0][1])
		}
		if len(dstPorts) > 0 {
			conn.DstPort, _ = strconv.Atoi(dstPorts[0][1])
		}

		// Reply direction
		if len(srcIPs) > 1 {
			conn.ReplySrcIP = srcIPs[1][1]
		}
		if len(dstIPs) > 1 {
			conn.ReplyDstIP = dstIPs[1][1]
		}
		if len(srcPorts) > 1 {
			conn.ReplySrcPort, _ = strconv.Atoi(srcPorts[1][1])
		}
		if len(dstPorts) > 1 {
			conn.ReplyDstPort, _ = strconv.Atoi(dstPorts[1][1])
		}

		// Parse counters if present
		if matches := packetsRe.FindStringSubmatch(line); len(matches) > 1 {
			conn.Packets, _ = strconv.ParseInt(matches[1], 10, 64)
		}
		if matches := bytesRe.FindStringSubmatch(line); len(matches) > 1 {
			conn.Bytes, _ = strconv.ParseInt(matches[1], 10, 64)
		}
		if matches := markRe.FindStringSubmatch(line); len(matches) > 1 {
			conn.Mark, _ = strconv.Atoi(matches[1])
		}
		if matches := zoneRe.FindStringSubmatch(line); len(matches) > 1 {
			conn.Zone, _ = strconv.Atoi(matches[1])
		}

		connections = append(connections, conn)
	}

	return connections
}

// getTopN returns the top N items from a count map.
func getTopN(counts map[string]int, n int) []IPCount {
	// Convert map to slice
	items := make([]IPCount, 0, len(counts))
	for ip, count := range counts {
		items = append(items, IPCount{IP: ip, Count: count})
	}

	// Sort by count descending
	sort.Slice(items, func(i, j int) bool {
		return items[i].Count > items[j].Count
	})

	// Return top N
	if len(items) > n {
		items = items[:n]
	}

	return items
}

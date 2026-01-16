// Package collector provides data collectors for Sentinel.
package collector

import (
	"bufio"
	"context"
	"encoding/json"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// FirewallLogEntry represents a parsed nftables log entry.
type FirewallLogEntry struct {
	Timestamp   time.Time `json:"timestamp"`
	Prefix      string    `json:"prefix"`
	InInterface string    `json:"in_interface,omitempty"`
	OutInterface string   `json:"out_interface,omitempty"`
	MACAddrs    string    `json:"mac_addrs,omitempty"`
	SrcIP       string    `json:"src_ip"`
	DstIP       string    `json:"dst_ip"`
	Protocol    string    `json:"protocol"`
	SrcPort     int       `json:"src_port,omitempty"`
	DstPort     int       `json:"dst_port,omitempty"`
	Length      int       `json:"length,omitempty"`
	TTL         int       `json:"ttl,omitempty"`
	ICMPType    int       `json:"icmp_type,omitempty"`
	ICMPCode    int       `json:"icmp_code,omitempty"`
	Flags       string    `json:"flags,omitempty"`
	Action      string    `json:"action"` // DROP, ACCEPT, etc. (inferred from prefix)
	Raw         string    `json:"raw,omitempty"`
}

// FirewallStats provides aggregate statistics about firewall logs.
type FirewallStats struct {
	TotalEntries    int            `json:"total_entries"`
	ByAction        map[string]int `json:"by_action"`
	ByProtocol      map[string]int `json:"by_protocol"`
	ByInInterface   map[string]int `json:"by_in_interface"`
	TopBlockedSrcs  []IPCount      `json:"top_blocked_sources"`
	TopBlockedPorts []PortCount    `json:"top_blocked_ports"`
}

// PortCount represents a count for a port number.
type PortCount struct {
	Port     int    `json:"port"`
	Protocol string `json:"protocol"`
	Count    int    `json:"count"`
}

// FirewallCollector collects firewall log data from journald.
type FirewallCollector struct {
	timeout time.Duration
}

// NewFirewallCollector creates a new firewall log collector.
func NewFirewallCollector(timeout time.Duration) *FirewallCollector {
	return &FirewallCollector{
		timeout: timeout,
	}
}

// GetLogs retrieves recent firewall log entries.
func (f *FirewallCollector) GetLogs(ctx context.Context, limit int, since string) ([]FirewallLogEntry, error) {
	ctx, cancel := context.WithTimeout(ctx, f.timeout)
	defer cancel()

	// Build journalctl command
	// Match common firewall log patterns (nftables logs contain key=value pairs like IN= OUT= SRC= DST=)
	args := []string{
		"-k",           // kernel messages
		"--no-pager",
		"-o", "json",
		"-g", "IN=.*OUT=.*SRC=.*DST=",   // grep for nftables log format (key=value pairs)
	}

	if since != "" {
		args = append(args, "--since", since)
	} else {
		// Default to last hour
		args = append(args, "--since", "1 hour ago")
	}

	if limit > 0 {
		args = append(args, "-n", strconv.Itoa(limit))
	}

	cmd := exec.CommandContext(ctx, "journalctl", args...)
	output, err := cmd.Output()
	if err != nil {
		// If grep finds nothing, journalctl returns non-zero
		// Check if output is empty
		if len(output) == 0 {
			return []FirewallLogEntry{}, nil
		}
	}

	return f.parseJournalOutput(string(output)), nil
}

// StreamLogs streams firewall logs in real-time.
// The callback is called for each new log entry.
// Returns when context is cancelled.
func (f *FirewallCollector) StreamLogs(ctx context.Context, callback func(FirewallLogEntry)) error {
	cmd := exec.CommandContext(ctx,
		"journalctl",
		"-k",
		"--no-pager",
		"-o", "json",
		"-f",           // follow
		"-g", "IN=.*OUT=.*SRC=.*DST=",   // grep for nftables log format
	)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}

	if err := cmd.Start(); err != nil {
		return err
	}

	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			cmd.Process.Kill()
			return ctx.Err()
		default:
			entry := f.parseJournalLine(scanner.Text())
			if entry != nil {
				callback(*entry)
			}
		}
	}

	return cmd.Wait()
}

// GetStats retrieves aggregate statistics from recent logs.
func (f *FirewallCollector) GetStats(ctx context.Context, since string) (*FirewallStats, error) {
	logs, err := f.GetLogs(ctx, 0, since)
	if err != nil {
		return nil, err
	}

	stats := &FirewallStats{
		TotalEntries:  len(logs),
		ByAction:      make(map[string]int),
		ByProtocol:    make(map[string]int),
		ByInInterface: make(map[string]int),
	}

	srcCounts := make(map[string]int)
	portCounts := make(map[string]int) // "protocol:port" -> count

	for _, entry := range logs {
		stats.ByAction[entry.Action]++
		stats.ByProtocol[entry.Protocol]++
		if entry.InInterface != "" {
			stats.ByInInterface[entry.InInterface]++
		}

		// Only count blocked sources
		if entry.Action == "DROP" || entry.Action == "REJECT" {
			srcCounts[entry.SrcIP]++
			if entry.DstPort > 0 {
				key := entry.Protocol + ":" + strconv.Itoa(entry.DstPort)
				portCounts[key]++
			}
		}
	}

	// Get top blocked sources
	stats.TopBlockedSrcs = getTopN(srcCounts, 10)

	// Get top blocked ports
	stats.TopBlockedPorts = getTopPorts(portCounts, 10)

	return stats, nil
}

// parseJournalOutput parses journalctl JSON output.
func (f *FirewallCollector) parseJournalOutput(output string) []FirewallLogEntry {
	var entries []FirewallLogEntry

	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		entry := f.parseJournalLine(scanner.Text())
		if entry != nil {
			entries = append(entries, *entry)
		}
	}

	return entries
}

// parseJournalLine parses a single JSON line from journalctl.
func (f *FirewallCollector) parseJournalLine(line string) *FirewallLogEntry {
	var journalEntry struct {
		Message            string `json:"MESSAGE"`
		RealtimeTimestamp  string `json:"__REALTIME_TIMESTAMP"`
	}

	if err := json.Unmarshal([]byte(line), &journalEntry); err != nil {
		return nil
	}

	// Parse the kernel message
	entry := f.parseNftablesLog(journalEntry.Message)
	if entry == nil {
		return nil
	}

	// Parse timestamp (microseconds since epoch)
	if ts, err := strconv.ParseInt(journalEntry.RealtimeTimestamp, 10, 64); err == nil {
		entry.Timestamp = time.UnixMicro(ts)
	}

	return entry
}

// parseNftablesLog parses an nftables log message.
// Handles various log prefix formats:
// - nft_drop: IN=wan0 OUT= ...
// - BLOCKED-CONN-BOGON: IN=wan0 OUT= ...
// - refused connection: IN=wan0 OUT= ...
// - WAN-SUSPICIOUS: IN=wan0 OUT= ...
func (f *FirewallCollector) parseNftablesLog(msg string) *FirewallLogEntry {
	// Check if this is a firewall log (has IN= and SRC= markers)
	if !strings.Contains(msg, "IN=") || !strings.Contains(msg, "SRC=") {
		return nil
	}

	entry := &FirewallLogEntry{
		Raw: msg,
	}

	// Extract prefix (everything before "IN=")
	if idx := strings.Index(msg, "IN="); idx > 0 {
		// Trim trailing spaces and colon from prefix
		entry.Prefix = strings.TrimRight(msg[:idx], ": ")

		// Infer action from prefix keywords
		prefix := strings.ToLower(entry.Prefix)
		if strings.Contains(prefix, "drop") || strings.Contains(prefix, "blocked") {
			entry.Action = "DROP"
		} else if strings.Contains(prefix, "reject") || strings.Contains(prefix, "refused") {
			entry.Action = "REJECT"
		} else if strings.Contains(prefix, "accept") {
			entry.Action = "ACCEPT"
		} else if strings.Contains(prefix, "suspicious") {
			entry.Action = "LOG"
		} else {
			entry.Action = "LOG"
		}
	}

	// Parse key=value pairs
	re := regexp.MustCompile(`(\w+)=(\S+)`)
	matches := re.FindAllStringSubmatch(msg, -1)

	for _, match := range matches {
		key, value := match[1], match[2]
		switch key {
		case "IN":
			entry.InInterface = value
		case "OUT":
			entry.OutInterface = value
		case "MAC":
			entry.MACAddrs = value
		case "SRC":
			entry.SrcIP = value
		case "DST":
			entry.DstIP = value
		case "PROTO":
			entry.Protocol = value
		case "SPT":
			entry.SrcPort, _ = strconv.Atoi(value)
		case "DPT":
			entry.DstPort, _ = strconv.Atoi(value)
		case "LEN":
			entry.Length, _ = strconv.Atoi(value)
		case "TTL":
			entry.TTL, _ = strconv.Atoi(value)
		case "TYPE":
			entry.ICMPType, _ = strconv.Atoi(value)
		case "CODE":
			entry.ICMPCode, _ = strconv.Atoi(value)
		}
	}

	// Parse TCP flags (they appear without =)
	tcpFlags := []string{"SYN", "ACK", "FIN", "RST", "PSH", "URG"}
	var flags []string
	for _, flag := range tcpFlags {
		if strings.Contains(msg, " "+flag+" ") || strings.HasSuffix(msg, " "+flag) {
			flags = append(flags, flag)
		}
	}
	if len(flags) > 0 {
		entry.Flags = strings.Join(flags, ",")
	}

	// Default protocol to IP if not specified
	if entry.Protocol == "" {
		entry.Protocol = "IP"
	}

	return entry
}

// getTopPorts returns the top N blocked ports.
func getTopPorts(counts map[string]int, n int) []PortCount {
	items := make([]PortCount, 0, len(counts))
	for key, count := range counts {
		parts := strings.SplitN(key, ":", 2)
		if len(parts) != 2 {
			continue
		}
		port, _ := strconv.Atoi(parts[1])
		items = append(items, PortCount{
			Protocol: parts[0],
			Port:     port,
			Count:    count,
		})
	}

	// Sort by count descending
	for i := 0; i < len(items)-1; i++ {
		for j := i + 1; j < len(items); j++ {
			if items[j].Count > items[i].Count {
				items[i], items[j] = items[j], items[i]
			}
		}
	}

	if len(items) > n {
		items = items[:n]
	}

	return items
}

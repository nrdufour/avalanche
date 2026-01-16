package collector

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// PingResult contains the results of a ping operation.
type PingResult struct {
	Host         string
	IP           string
	PacketsSent  int
	PacketsRecv  int
	PacketLoss   float64
	MinRTT       time.Duration
	AvgRTT       time.Duration
	MaxRTT       time.Duration
	Error        string
	ResponseTime []time.Duration
}

// TracerouteHop represents a single hop in a traceroute.
type TracerouteHop struct {
	Number  int
	Host    string
	IP      string
	RTT     []time.Duration
	Timeout bool
}

// TracerouteResult contains the results of a traceroute operation.
type TracerouteResult struct {
	Host  string
	Hops  []TracerouteHop
	Error string
}

// DNSResult contains the results of a DNS lookup.
type DNSResult struct {
	Query      string
	QueryType  string
	Server     string
	Answers    []DNSAnswer
	QueryTime  time.Duration
	Error      string
}

// DNSAnswer represents a single DNS answer.
type DNSAnswer struct {
	Name  string
	Type  string
	TTL   int
	Value string
}

// PortCheckResult contains the results of a port check.
type PortCheckResult struct {
	Host    string
	Port    int
	Open    bool
	Latency time.Duration
	Error   string
}

// DiagnosticsRunner executes network diagnostic commands.
type DiagnosticsRunner struct {
	allowedTargets []string
	pingTimeout    time.Duration
	traceTimeout   time.Duration
	dnsTimeout     time.Duration
	portTimeout    time.Duration
}

// NewDiagnosticsRunner creates a new diagnostics runner.
func NewDiagnosticsRunner(allowedTargets []string, pingTimeout, traceTimeout, dnsTimeout, portTimeout time.Duration) *DiagnosticsRunner {
	return &DiagnosticsRunner{
		allowedTargets: allowedTargets,
		pingTimeout:    pingTimeout,
		traceTimeout:   traceTimeout,
		dnsTimeout:     dnsTimeout,
		portTimeout:    portTimeout,
	}
}

// IsTargetAllowed checks if the target is in the allowed list.
func (d *DiagnosticsRunner) IsTargetAllowed(target string) bool {
	// Parse target (could be IP or hostname)
	targetIP := net.ParseIP(target)

	for _, allowed := range d.allowedTargets {
		// Check wildcard patterns (*.internal)
		if strings.HasPrefix(allowed, "*.") {
			suffix := allowed[1:] // Remove *
			if strings.HasSuffix(target, suffix) {
				return true
			}
		}

		// Check CIDR notation
		if strings.Contains(allowed, "/") {
			_, network, err := net.ParseCIDR(allowed)
			if err == nil && targetIP != nil && network.Contains(targetIP) {
				return true
			}
		}

		// Exact match
		if target == allowed {
			return true
		}
	}

	return false
}

// Ping executes a ping command and returns the results.
func (d *DiagnosticsRunner) Ping(ctx context.Context, host string, count int) (*PingResult, error) {
	if !d.IsTargetAllowed(host) {
		return nil, fmt.Errorf("target %q not in allowed list", host)
	}

	if count <= 0 {
		count = 4
	}
	if count > 10 {
		count = 10
	}

	result := &PingResult{
		Host:         host,
		ResponseTime: make([]time.Duration, 0),
	}

	// Create context with timeout
	ctx, cancel := context.WithTimeout(ctx, d.pingTimeout)
	defer cancel()

	// Execute ping command
	cmd := exec.CommandContext(ctx, "ping", "-c", strconv.Itoa(count), "-W", "2", host)
	output, err := cmd.CombinedOutput()

	if ctx.Err() == context.DeadlineExceeded {
		result.Error = "ping timed out"
		return result, nil
	}

	outputStr := string(output)

	// Parse ping output
	// Example: "64 bytes from 10.0.0.1: icmp_seq=1 ttl=64 time=0.123 ms"
	timeRegex := regexp.MustCompile(`time=([0-9.]+)\s*(ms|s)`)
	matches := timeRegex.FindAllStringSubmatch(outputStr, -1)

	for _, match := range matches {
		if len(match) >= 3 {
			val, _ := strconv.ParseFloat(match[1], 64)
			unit := match[2]
			var rtt time.Duration
			if unit == "s" {
				rtt = time.Duration(val * float64(time.Second))
			} else {
				rtt = time.Duration(val * float64(time.Millisecond))
			}
			result.ResponseTime = append(result.ResponseTime, rtt)
		}
	}

	result.PacketsRecv = len(result.ResponseTime)
	result.PacketsSent = count

	if result.PacketsSent > 0 {
		result.PacketLoss = float64(result.PacketsSent-result.PacketsRecv) / float64(result.PacketsSent) * 100
	}

	// Calculate RTT stats
	if len(result.ResponseTime) > 0 {
		var total time.Duration
		result.MinRTT = result.ResponseTime[0]
		result.MaxRTT = result.ResponseTime[0]

		for _, rtt := range result.ResponseTime {
			total += rtt
			if rtt < result.MinRTT {
				result.MinRTT = rtt
			}
			if rtt > result.MaxRTT {
				result.MaxRTT = rtt
			}
		}
		result.AvgRTT = total / time.Duration(len(result.ResponseTime))
	}

	// Extract resolved IP
	ipRegex := regexp.MustCompile(`PING\s+\S+\s+\(([0-9.]+)\)`)
	if match := ipRegex.FindStringSubmatch(outputStr); len(match) > 1 {
		result.IP = match[1]
	}

	if err != nil && result.PacketsRecv == 0 {
		result.Error = "host unreachable"
	}

	return result, nil
}

// Traceroute executes a traceroute command and returns the results.
func (d *DiagnosticsRunner) Traceroute(ctx context.Context, host string) (*TracerouteResult, error) {
	if !d.IsTargetAllowed(host) {
		return nil, fmt.Errorf("target %q not in allowed list", host)
	}

	result := &TracerouteResult{
		Host: host,
		Hops: make([]TracerouteHop, 0),
	}

	ctx, cancel := context.WithTimeout(ctx, d.traceTimeout)
	defer cancel()

	// Use traceroute command (or tracepath as fallback)
	cmd := exec.CommandContext(ctx, "traceroute", "-n", "-w", "2", "-m", "20", host)
	output, err := cmd.CombinedOutput()

	if ctx.Err() == context.DeadlineExceeded {
		result.Error = "traceroute timed out"
		return result, nil
	}

	if err != nil {
		// Try tracepath as fallback
		cmd = exec.CommandContext(ctx, "tracepath", "-n", host)
		output, err = cmd.CombinedOutput()
		if err != nil {
			result.Error = "traceroute failed"
			return result, nil
		}
	}

	// Parse traceroute output
	scanner := bufio.NewScanner(strings.NewReader(string(output)))

	// Skip header line
	if scanner.Scan() {
		// Header: "traceroute to host (ip), 30 hops max, 60 byte packets"
	}

	hopRegex := regexp.MustCompile(`^\s*(\d+)\s+(.+)$`)
	rttRegex := regexp.MustCompile(`([0-9.]+)\s*ms`)
	ipRegex := regexp.MustCompile(`([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)`)

	for scanner.Scan() {
		line := scanner.Text()
		match := hopRegex.FindStringSubmatch(line)
		if len(match) < 3 {
			continue
		}

		hopNum, _ := strconv.Atoi(match[1])
		hopData := match[2]

		hop := TracerouteHop{
			Number: hopNum,
			RTT:    make([]time.Duration, 0),
		}

		// Check for timeout
		if strings.Contains(hopData, "* * *") || strings.Contains(hopData, "no reply") {
			hop.Timeout = true
		} else {
			// Extract IP
			if ipMatch := ipRegex.FindString(hopData); ipMatch != "" {
				hop.IP = ipMatch
			}

			// Extract RTTs
			rttMatches := rttRegex.FindAllStringSubmatch(hopData, -1)
			for _, rttMatch := range rttMatches {
				if len(rttMatch) > 1 {
					val, _ := strconv.ParseFloat(rttMatch[1], 64)
					hop.RTT = append(hop.RTT, time.Duration(val*float64(time.Millisecond)))
				}
			}
		}

		result.Hops = append(result.Hops, hop)
	}

	return result, nil
}

// DNSLookup performs a DNS lookup using dig or nslookup.
func (d *DiagnosticsRunner) DNSLookup(ctx context.Context, query string, queryType string, server string) (*DNSResult, error) {
	if !d.IsTargetAllowed(query) && !d.IsTargetAllowed(server) {
		return nil, fmt.Errorf("target not in allowed list")
	}

	if queryType == "" {
		queryType = "A"
	}

	result := &DNSResult{
		Query:     query,
		QueryType: queryType,
		Server:    server,
		Answers:   make([]DNSAnswer, 0),
	}

	ctx, cancel := context.WithTimeout(ctx, d.dnsTimeout)
	defer cancel()

	// Build dig command
	args := []string{"+noall", "+answer", "+stats", query, queryType}
	if server != "" {
		args = append([]string{"@" + server}, args...)
	}

	start := time.Now()
	cmd := exec.CommandContext(ctx, "dig", args...)
	output, err := cmd.CombinedOutput()
	result.QueryTime = time.Since(start)

	if ctx.Err() == context.DeadlineExceeded {
		result.Error = "DNS lookup timed out"
		return result, nil
	}

	if err != nil {
		result.Error = "DNS lookup failed"
		return result, nil
	}

	// Parse dig output
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	answerRegex := regexp.MustCompile(`^(\S+)\s+(\d+)\s+IN\s+(\S+)\s+(.+)$`)

	for scanner.Scan() {
		line := scanner.Text()

		// Skip comments and empty lines
		if strings.HasPrefix(line, ";") || strings.TrimSpace(line) == "" {
			continue
		}

		match := answerRegex.FindStringSubmatch(line)
		if len(match) >= 5 {
			ttl, _ := strconv.Atoi(match[2])
			result.Answers = append(result.Answers, DNSAnswer{
				Name:  match[1],
				TTL:   ttl,
				Type:  match[3],
				Value: match[4],
			})
		}
	}

	return result, nil
}

// PortCheck checks if a TCP port is open.
func (d *DiagnosticsRunner) PortCheck(ctx context.Context, host string, port int) (*PortCheckResult, error) {
	if !d.IsTargetAllowed(host) {
		return nil, fmt.Errorf("target %q not in allowed list", host)
	}

	result := &PortCheckResult{
		Host: host,
		Port: port,
	}

	address := fmt.Sprintf("%s:%d", host, port)

	ctx, cancel := context.WithTimeout(ctx, d.portTimeout)
	defer cancel()

	start := time.Now()
	dialer := &net.Dialer{}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	result.Latency = time.Since(start)

	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			result.Error = "connection timed out"
		} else {
			result.Error = "connection refused"
		}
		result.Open = false
		return result, nil
	}

	conn.Close()
	result.Open = true

	return result, nil
}

// FormatRTT formats a round-trip time for display.
func FormatRTT(d time.Duration) string {
	if d < time.Millisecond {
		return fmt.Sprintf("%.2f µs", float64(d.Microseconds()))
	}
	return fmt.Sprintf("%.2f ms", float64(d.Microseconds())/1000)
}

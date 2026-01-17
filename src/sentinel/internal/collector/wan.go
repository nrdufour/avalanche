package collector

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// WANStats represents WAN status information.
type WANStats struct {
	PublicIP  string          `json:"public_ip"`
	Targets   []LatencyTarget `json:"targets"`
	LastCheck time.Time       `json:"last_check"`
}

// LatencyTarget represents latency measurements to a specific target.
type LatencyTarget struct {
	Name       string  `json:"name"`
	IP         string  `json:"ip"`
	Latency    float64 `json:"latency_ms"`    // Average latency in ms
	PacketLoss float64 `json:"packet_loss"`   // Packet loss percentage
	Status     string  `json:"status"`        // "healthy", "degraded", "down"
}

// WANCollector collects WAN status information.
type WANCollector struct {
	targets       []string
	cacheDuration time.Duration

	mu          sync.RWMutex
	cachedStats *WANStats
	cacheTime   time.Time
}

// NewWANCollector creates a new WAN collector.
func NewWANCollector(targets []string, cacheDuration time.Duration) *WANCollector {
	return &WANCollector{
		targets:       targets,
		cacheDuration: cacheDuration,
	}
}

// Collect gathers WAN status. Results are cached.
func (c *WANCollector) Collect(ctx context.Context) (*WANStats, error) {
	c.mu.RLock()
	if c.cachedStats != nil && time.Since(c.cacheTime) < c.cacheDuration {
		stats := c.cachedStats
		c.mu.RUnlock()
		return stats, nil
	}
	c.mu.RUnlock()

	// Collect fresh data
	stats := &WANStats{
		LastCheck: time.Now(),
	}

	// Get public IP (with timeout)
	publicIP, err := c.getPublicIP(ctx)
	if err == nil {
		stats.PublicIP = publicIP
	}

	// Get latency to targets
	stats.Targets = c.measureLatencies(ctx)

	// Cache the results
	c.mu.Lock()
	c.cachedStats = stats
	c.cacheTime = time.Now()
	c.mu.Unlock()

	return stats, nil
}

// getPublicIP fetches the public IP from icanhazip.com.
func (c *WANCollector) getPublicIP(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, "GET", "https://icanhazip.com", nil)
	if err != nil {
		return "", err
	}

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status: %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 64))
	if err != nil {
		return "", err
	}

	return strings.TrimSpace(string(body)), nil
}

// measureLatencies measures latency to all configured targets using fping.
func (c *WANCollector) measureLatencies(ctx context.Context) []LatencyTarget {
	results := make([]LatencyTarget, len(c.targets))

	for i, target := range c.targets {
		results[i] = c.measureTarget(ctx, target)
	}

	return results
}

// measureTarget measures latency to a single target using fping.
func (c *WANCollector) measureTarget(ctx context.Context, target string) LatencyTarget {
	result := LatencyTarget{
		Name:   target,
		IP:     target,
		Status: "down",
	}

	// Use fping with 3 packets, quiet mode
	// fping -c 3 -q outputs to stderr: target : xmt/rcv/%loss = 3/3/0%, min/avg/max = 1.23/1.45/1.67
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "fping", "-c", "3", "-q", target)
	output, _ := cmd.CombinedOutput() // fping writes to stderr, and returns non-zero if any packets lost

	// Parse the output
	latency, packetLoss, err := parseFpingOutput(string(output), target)
	if err != nil {
		// If fping failed completely, try ping as fallback
		latency, packetLoss, err = c.fallbackPing(ctx, target)
		if err != nil {
			return result
		}
	}

	result.Latency = latency
	result.PacketLoss = packetLoss

	// Determine status based on latency and packet loss
	result.Status = determineStatus(latency, packetLoss)

	return result
}

// parseFpingOutput parses fping output to extract latency and packet loss.
// Example output: "1.1.1.1 : xmt/rcv/%loss = 3/3/0%, min/avg/max = 8.45/9.12/10.01"
func parseFpingOutput(output, target string) (latency, packetLoss float64, err error) {
	// fping writes to stderr, one line per target
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.Contains(line, target) {
			continue
		}

		// Parse packet loss: xmt/rcv/%loss = 3/3/0%
		lossRegex := regexp.MustCompile(`(\d+)/(\d+)/(\d+)%`)
		lossMatches := lossRegex.FindStringSubmatch(line)
		if len(lossMatches) >= 4 {
			loss, _ := strconv.ParseFloat(lossMatches[3], 64)
			packetLoss = loss
		}

		// Parse latency: min/avg/max = 8.45/9.12/10.01
		latencyRegex := regexp.MustCompile(`min/avg/max = [\d.]+/([\d.]+)/[\d.]+`)
		latencyMatches := latencyRegex.FindStringSubmatch(line)
		if len(latencyMatches) >= 2 {
			avg, _ := strconv.ParseFloat(latencyMatches[1], 64)
			latency = avg
			return latency, packetLoss, nil
		}

		// If we got packet loss but no latency, all packets were lost
		if packetLoss == 100 {
			return 0, 100, nil
		}
	}

	return 0, 0, fmt.Errorf("could not parse fping output for %s", target)
}

// fallbackPing uses the standard ping command as a fallback.
func (c *WANCollector) fallbackPing(ctx context.Context, target string) (latency, packetLoss float64, err error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "ping", "-c", "3", "-W", "2", target)
	output, _ := cmd.CombinedOutput()

	// Parse ping output
	// Example: "rtt min/avg/max/mdev = 8.123/9.456/10.789/1.234 ms"
	// Example: "3 packets transmitted, 3 received, 0% packet loss"
	outputStr := string(output)

	// Parse packet loss
	lossRegex := regexp.MustCompile(`(\d+)% packet loss`)
	lossMatches := lossRegex.FindStringSubmatch(outputStr)
	if len(lossMatches) >= 2 {
		loss, _ := strconv.ParseFloat(lossMatches[1], 64)
		packetLoss = loss
	}

	// Parse latency
	latencyRegex := regexp.MustCompile(`rtt min/avg/max/mdev = [\d.]+/([\d.]+)/[\d.]+/[\d.]+ ms`)
	latencyMatches := latencyRegex.FindStringSubmatch(outputStr)
	if len(latencyMatches) >= 2 {
		avg, _ := strconv.ParseFloat(latencyMatches[1], 64)
		latency = avg
		return latency, packetLoss, nil
	}

	// If 100% packet loss, no latency info
	if packetLoss == 100 {
		return 0, 100, nil
	}

	return 0, 0, fmt.Errorf("could not parse ping output for %s", target)
}

// determineStatus determines WAN status based on latency and packet loss.
func determineStatus(latency, packetLoss float64) string {
	// Down: 100% packet loss or no response
	if packetLoss >= 100 {
		return "down"
	}

	// Degraded: any packet loss, or high latency (>100ms)
	if packetLoss > 0 || latency > 100 {
		return "degraded"
	}

	// Healthy: no packet loss and reasonable latency
	return "healthy"
}

// InvalidateCache forces the next Collect call to fetch fresh data.
func (c *WANCollector) InvalidateCache() {
	c.mu.Lock()
	c.cachedStats = nil
	c.mu.Unlock()
}

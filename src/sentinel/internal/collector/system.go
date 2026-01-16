package collector

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// SystemStats represents basic system statistics.
type SystemStats struct {
	Hostname    string
	Uptime      time.Duration
	LoadAvg1    float64
	LoadAvg5    float64
	LoadAvg15   float64
	MemTotal    uint64
	MemFree     uint64
	MemAvail    uint64
	MemUsed     uint64
	MemPercent  float64
	SwapTotal   uint64
	SwapFree    uint64
	SwapUsed    uint64
	SwapPercent float64
}

// SystemCollector collects system-level statistics.
type SystemCollector struct{}

// NewSystemCollector creates a new system collector.
func NewSystemCollector() *SystemCollector {
	return &SystemCollector{}
}

// Collect gathers system statistics.
func (c *SystemCollector) Collect() (*SystemStats, error) {
	stats := &SystemStats{}

	// Get hostname
	hostname, err := os.Hostname()
	if err == nil {
		stats.Hostname = hostname
	}

	// Get uptime
	uptime, err := readUptime()
	if err == nil {
		stats.Uptime = uptime
	}

	// Get load average
	load1, load5, load15, err := readLoadAvg()
	if err == nil {
		stats.LoadAvg1 = load1
		stats.LoadAvg5 = load5
		stats.LoadAvg15 = load15
	}

	// Get memory info
	memInfo, err := readMemInfo()
	if err == nil {
		stats.MemTotal = memInfo["MemTotal"]
		stats.MemFree = memInfo["MemFree"]
		stats.MemAvail = memInfo["MemAvailable"]
		stats.SwapTotal = memInfo["SwapTotal"]
		stats.SwapFree = memInfo["SwapFree"]

		// Calculate used memory
		if stats.MemAvail > 0 {
			stats.MemUsed = stats.MemTotal - stats.MemAvail
		} else {
			stats.MemUsed = stats.MemTotal - stats.MemFree
		}

		if stats.MemTotal > 0 {
			stats.MemPercent = float64(stats.MemUsed) / float64(stats.MemTotal) * 100
		}

		// Calculate swap usage
		if stats.SwapTotal > 0 {
			stats.SwapUsed = stats.SwapTotal - stats.SwapFree
			stats.SwapPercent = float64(stats.SwapUsed) / float64(stats.SwapTotal) * 100
		}
	}

	return stats, nil
}

// readUptime reads system uptime from /proc/uptime.
func readUptime() (time.Duration, error) {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, err
	}

	fields := strings.Fields(string(data))
	if len(fields) < 1 {
		return 0, fmt.Errorf("invalid uptime format")
	}

	seconds, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, err
	}

	return time.Duration(seconds * float64(time.Second)), nil
}

// readLoadAvg reads load averages from /proc/loadavg.
func readLoadAvg() (load1, load5, load15 float64, err error) {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0, 0, 0, err
	}

	fields := strings.Fields(string(data))
	if len(fields) < 3 {
		return 0, 0, 0, fmt.Errorf("invalid loadavg format")
	}

	load1, _ = strconv.ParseFloat(fields[0], 64)
	load5, _ = strconv.ParseFloat(fields[1], 64)
	load15, _ = strconv.ParseFloat(fields[2], 64)

	return load1, load5, load15, nil
}

// readMemInfo reads memory information from /proc/meminfo.
func readMemInfo() (map[string]uint64, error) {
	file, err := os.Open("/proc/meminfo")
	if err != nil {
		return nil, err
	}
	defer file.Close()

	result := make(map[string]uint64)
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := scanner.Text()
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}

		key := strings.TrimSuffix(fields[0], ":")
		value, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}

		// Values are in kB, convert to bytes
		result[key] = value * 1024
	}

	return result, scanner.Err()
}

// FormatUptime formats an uptime duration into a human-readable string.
func FormatUptime(d time.Duration) string {
	days := int(d.Hours()) / 24
	hours := int(d.Hours()) % 24
	minutes := int(d.Minutes()) % 60

	if days > 0 {
		return fmt.Sprintf("%dd %dh %dm", days, hours, minutes)
	}
	if hours > 0 {
		return fmt.Sprintf("%dh %dm", hours, minutes)
	}
	return fmt.Sprintf("%dm", minutes)
}

// FormatMemory formats bytes into a human-readable memory string.
func FormatMemory(bytes uint64) string {
	const (
		KB = 1024
		MB = 1024 * KB
		GB = 1024 * MB
	)

	switch {
	case bytes >= GB:
		return fmt.Sprintf("%.1f GB", float64(bytes)/float64(GB))
	case bytes >= MB:
		return fmt.Sprintf("%.1f MB", float64(bytes)/float64(MB))
	case bytes >= KB:
		return fmt.Sprintf("%.1f KB", float64(bytes)/float64(KB))
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}

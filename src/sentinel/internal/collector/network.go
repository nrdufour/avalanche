// Package collector provides data collection from various sources.
package collector

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
)

// InterfaceStats represents statistics for a network interface.
type InterfaceStats struct {
	Name      string
	IsUp      bool
	IPv4      []string // All IPv4 addresses with CIDR notation
	IPv6      []string // All IPv6 addresses with CIDR notation
	MAC       string
	RxBytes   uint64
	TxBytes   uint64
	RxPackets uint64
	TxPackets uint64
	RxErrors  uint64
	TxErrors  uint64
	Speed     int // Mbps, -1 if unknown
	MTU       int
}

// NetworkCollector collects network interface statistics.
type NetworkCollector struct {
	interfaces []string
}

// NewNetworkCollector creates a new network collector for the specified interfaces.
func NewNetworkCollector(interfaces []string) *NetworkCollector {
	return &NetworkCollector{interfaces: interfaces}
}

// Collect gathers statistics for all configured interfaces.
func (c *NetworkCollector) Collect() (map[string]*InterfaceStats, error) {
	// Get traffic stats from /proc/net/dev
	trafficStats, err := readProcNetDev()
	if err != nil {
		return nil, fmt.Errorf("reading /proc/net/dev: %w", err)
	}

	result := make(map[string]*InterfaceStats)

	for _, name := range c.interfaces {
		stats := &InterfaceStats{
			Name:  name,
			Speed: -1,
		}

		// Get interface from net package
		iface, err := net.InterfaceByName(name)
		if err != nil {
			// Interface not found
			result[name] = stats
			continue
		}

		// Check if interface is up
		stats.IsUp = (iface.Flags & net.FlagUp) != 0
		stats.MAC = iface.HardwareAddr.String()
		stats.MTU = iface.MTU

		// Get IP addresses
		addrs, err := iface.Addrs()
		if err == nil {
			for _, addr := range addrs {
				ipnet, ok := addr.(*net.IPNet)
				if !ok {
					continue
				}
				if ipnet.IP.To4() != nil {
					stats.IPv4 = append(stats.IPv4, ipnet.String())
				} else if ipnet.IP.To16() != nil {
					stats.IPv6 = append(stats.IPv6, ipnet.String())
				}
			}
		}

		// Get traffic stats
		if ts, ok := trafficStats[name]; ok {
			stats.RxBytes = ts.RxBytes
			stats.TxBytes = ts.TxBytes
			stats.RxPackets = ts.RxPackets
			stats.TxPackets = ts.TxPackets
			stats.RxErrors = ts.RxErrors
			stats.TxErrors = ts.TxErrors
		}

		// Try to get interface speed
		stats.Speed = readInterfaceSpeed(name)

		result[name] = stats
	}

	return result, nil
}

// CollectOne gathers statistics for a single interface.
func (c *NetworkCollector) CollectOne(name string) (*InterfaceStats, error) {
	stats := &InterfaceStats{
		Name:  name,
		Speed: -1,
	}

	// Get traffic stats
	trafficStats, err := readProcNetDev()
	if err != nil {
		return nil, fmt.Errorf("reading /proc/net/dev: %w", err)
	}

	// Get interface
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return stats, nil // Return empty stats for missing interface
	}

	stats.IsUp = (iface.Flags & net.FlagUp) != 0
	stats.MAC = iface.HardwareAddr.String()
	stats.MTU = iface.MTU

	// Get IP addresses
	addrs, err := iface.Addrs()
	if err == nil {
		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			if ipnet.IP.To4() != nil {
				stats.IPv4 = append(stats.IPv4, ipnet.String())
			} else if ipnet.IP.To16() != nil {
				stats.IPv6 = append(stats.IPv6, ipnet.String())
			}
		}
	}

	// Get traffic stats
	if ts, ok := trafficStats[name]; ok {
		stats.RxBytes = ts.RxBytes
		stats.TxBytes = ts.TxBytes
		stats.RxPackets = ts.RxPackets
		stats.TxPackets = ts.TxPackets
		stats.RxErrors = ts.RxErrors
		stats.TxErrors = ts.TxErrors
	}

	stats.Speed = readInterfaceSpeed(name)

	return stats, nil
}

// trafficStats holds raw traffic statistics from /proc/net/dev.
type trafficStats struct {
	RxBytes   uint64
	RxPackets uint64
	RxErrors  uint64
	TxBytes   uint64
	TxPackets uint64
	TxErrors  uint64
}

// readProcNetDev reads network statistics from /proc/net/dev.
func readProcNetDev() (map[string]*trafficStats, error) {
	file, err := os.Open("/proc/net/dev")
	if err != nil {
		return nil, err
	}
	defer file.Close()

	result := make(map[string]*trafficStats)
	scanner := bufio.NewScanner(file)

	// Skip header lines
	scanner.Scan()
	scanner.Scan()

	for scanner.Scan() {
		line := scanner.Text()

		// Format: "iface: rx_bytes rx_packets rx_errs ... tx_bytes tx_packets tx_errs ..."
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}

		name := strings.TrimSpace(parts[0])
		fields := strings.Fields(parts[1])
		if len(fields) < 16 {
			continue
		}

		stats := &trafficStats{}
		stats.RxBytes, _ = strconv.ParseUint(fields[0], 10, 64)
		stats.RxPackets, _ = strconv.ParseUint(fields[1], 10, 64)
		stats.RxErrors, _ = strconv.ParseUint(fields[2], 10, 64)
		stats.TxBytes, _ = strconv.ParseUint(fields[8], 10, 64)
		stats.TxPackets, _ = strconv.ParseUint(fields[9], 10, 64)
		stats.TxErrors, _ = strconv.ParseUint(fields[10], 10, 64)

		result[name] = stats
	}

	return result, scanner.Err()
}

// readInterfaceSpeed reads the interface speed from /sys/class/net/<iface>/speed.
func readInterfaceSpeed(name string) int {
	data, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/speed", name))
	if err != nil {
		return -1
	}

	speed, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return -1
	}

	return speed
}

// FormatBytes formats bytes into a human-readable string.
func FormatBytes(bytes uint64) string {
	const (
		KB = 1024
		MB = 1024 * KB
		GB = 1024 * MB
		TB = 1024 * GB
	)

	switch {
	case bytes >= TB:
		return fmt.Sprintf("%.2f TB", float64(bytes)/float64(TB))
	case bytes >= GB:
		return fmt.Sprintf("%.2f GB", float64(bytes)/float64(GB))
	case bytes >= MB:
		return fmt.Sprintf("%.2f MB", float64(bytes)/float64(MB))
	case bytes >= KB:
		return fmt.Sprintf("%.2f KB", float64(bytes)/float64(KB))
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}

// StatusString returns "up" or "down" based on interface state.
func (s *InterfaceStats) StatusString() string {
	if s.IsUp {
		return "up"
	}
	return "down"
}

// PrimaryIPv4 returns the first IPv4 address or "-" if none.
func (s *InterfaceStats) PrimaryIPv4() string {
	if len(s.IPv4) > 0 {
		return s.IPv4[0]
	}
	return "-"
}

// PrimaryIPv6 returns the first IPv6 address or "-" if none.
func (s *InterfaceStats) PrimaryIPv6() string {
	if len(s.IPv6) > 0 {
		return s.IPv6[0]
	}
	return "-"
}

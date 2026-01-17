package collector

import (
	"bufio"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
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
	CPUUsage    float64     `json:"cpu_usage"`
	CPUCores    int         `json:"cpu_cores"`
	Disks       []DiskStats `json:"disks"`
}

// DiskStats represents disk usage statistics for a mount point.
type DiskStats struct {
	MountPoint  string  `json:"mount_point"`
	Device      string  `json:"device,omitempty"`
	Total       uint64  `json:"total"`
	Used        uint64  `json:"used"`
	Free        uint64  `json:"free"`
	UsedPercent float64 `json:"used_percent"`
}

// SystemCollector collects system-level statistics.
type SystemCollector struct {
	diskMountPoints []string
	// For CPU usage calculation (delta between reads)
	prevCPUStats cpuStats
	prevCPUTime  time.Time
}

type cpuStats struct {
	user, nice, system, idle, iowait, irq, softirq, steal uint64
}

func (c cpuStats) total() uint64 {
	return c.user + c.nice + c.system + c.idle + c.iowait + c.irq + c.softirq + c.steal
}

func (c cpuStats) idle_total() uint64 {
	return c.idle + c.iowait
}

// NewSystemCollector creates a new system collector.
func NewSystemCollector(diskMountPoints []string) *SystemCollector {
	return &SystemCollector{
		diskMountPoints: diskMountPoints,
	}
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

	// Get CPU info
	stats.CPUCores = runtime.NumCPU()
	stats.CPUUsage = c.calculateCPUUsage()

	// Get disk stats
	stats.Disks = c.collectDiskStats()

	return stats, nil
}

// calculateCPUUsage calculates CPU usage percentage based on delta from previous reading.
func (c *SystemCollector) calculateCPUUsage() float64 {
	current, err := readCPUStats()
	if err != nil {
		return 0
	}

	now := time.Now()

	// If this is the first reading or too much time has passed, store and return 0
	if c.prevCPUTime.IsZero() || now.Sub(c.prevCPUTime) > time.Minute {
		c.prevCPUStats = current
		c.prevCPUTime = now
		return 0
	}

	// Calculate delta
	totalDelta := current.total() - c.prevCPUStats.total()
	idleDelta := current.idle_total() - c.prevCPUStats.idle_total()

	// Store current for next calculation
	c.prevCPUStats = current
	c.prevCPUTime = now

	if totalDelta == 0 {
		return 0
	}

	// CPU usage = (total - idle) / total * 100
	return float64(totalDelta-idleDelta) / float64(totalDelta) * 100
}

// readCPUStats reads CPU statistics from /proc/stat.
func readCPUStats() (cpuStats, error) {
	file, err := os.Open("/proc/stat")
	if err != nil {
		return cpuStats{}, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "cpu ") {
			fields := strings.Fields(line)
			if len(fields) < 8 {
				return cpuStats{}, fmt.Errorf("invalid cpu stat format")
			}

			var stats cpuStats
			stats.user, _ = strconv.ParseUint(fields[1], 10, 64)
			stats.nice, _ = strconv.ParseUint(fields[2], 10, 64)
			stats.system, _ = strconv.ParseUint(fields[3], 10, 64)
			stats.idle, _ = strconv.ParseUint(fields[4], 10, 64)
			stats.iowait, _ = strconv.ParseUint(fields[5], 10, 64)
			stats.irq, _ = strconv.ParseUint(fields[6], 10, 64)
			stats.softirq, _ = strconv.ParseUint(fields[7], 10, 64)
			if len(fields) > 8 {
				stats.steal, _ = strconv.ParseUint(fields[8], 10, 64)
			}

			return stats, nil
		}
	}

	return cpuStats{}, fmt.Errorf("cpu line not found in /proc/stat")
}

// collectDiskStats gathers disk usage for configured mount points.
func (c *SystemCollector) collectDiskStats() []DiskStats {
	var disks []DiskStats

	for _, mountPoint := range c.diskMountPoints {
		stat, err := getDiskStats(mountPoint)
		if err != nil {
			continue
		}
		disks = append(disks, stat)
	}

	return disks
}

// getDiskStats returns disk usage statistics for a mount point.
func getDiskStats(mountPoint string) (DiskStats, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(mountPoint, &stat); err != nil {
		return DiskStats{}, err
	}

	// Calculate sizes in bytes
	total := stat.Blocks * uint64(stat.Bsize)
	free := stat.Bfree * uint64(stat.Bsize)
	avail := stat.Bavail * uint64(stat.Bsize)

	// Used = total - free (for root), but available might be less due to reserved blocks
	used := total - free
	usedPercent := float64(0)
	if total > 0 {
		// Use (total - avail) for user-visible percentage since some blocks are reserved for root
		usedPercent = float64(total-avail) / float64(total) * 100
	}

	return DiskStats{
		MountPoint:  mountPoint,
		Total:       total,
		Used:        used,
		Free:        avail, // Report available space (user-accessible)
		UsedPercent: usedPercent,
	}, nil
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

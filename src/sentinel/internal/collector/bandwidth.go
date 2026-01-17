package collector

import (
	"bufio"
	"context"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// BandwidthSample represents a single bandwidth measurement.
type BandwidthSample struct {
	Timestamp time.Time `json:"timestamp"`
	RxBps     uint64    `json:"rx_bps"` // Bytes per second received
	TxBps     uint64    `json:"tx_bps"` // Bytes per second transmitted
}

// InterfaceHistory holds bandwidth history for a single interface.
type InterfaceHistory struct {
	Name    string            `json:"name"`
	Samples []BandwidthSample `json:"samples"`
}

// interfaceStats holds raw stats from /proc/net/dev.
type interfaceStats struct {
	rxBytes uint64
	txBytes uint64
}

// BandwidthCollector collects and stores bandwidth history.
type BandwidthCollector struct {
	interfaces []string
	sampleRate time.Duration
	retention  time.Duration

	mu        sync.RWMutex
	history   map[string]*ringBuffer // interface name -> ring buffer of samples
	prevStats map[string]interfaceStats
	prevTime  time.Time

	cancel context.CancelFunc
	done   chan struct{}
}

// ringBuffer is a simple circular buffer for samples.
type ringBuffer struct {
	data  []BandwidthSample
	start int
	count int
	size  int
}

func newRingBuffer(size int) *ringBuffer {
	return &ringBuffer{
		data: make([]BandwidthSample, size),
		size: size,
	}
}

func (r *ringBuffer) add(sample BandwidthSample) {
	idx := (r.start + r.count) % r.size
	r.data[idx] = sample
	if r.count < r.size {
		r.count++
	} else {
		r.start = (r.start + 1) % r.size
	}
}

func (r *ringBuffer) getAll() []BandwidthSample {
	result := make([]BandwidthSample, r.count)
	for i := 0; i < r.count; i++ {
		idx := (r.start + i) % r.size
		result[i] = r.data[idx]
	}
	return result
}

func (r *ringBuffer) getSince(since time.Time) []BandwidthSample {
	var result []BandwidthSample
	for i := 0; i < r.count; i++ {
		idx := (r.start + i) % r.size
		if r.data[idx].Timestamp.After(since) || r.data[idx].Timestamp.Equal(since) {
			result = append(result, r.data[idx])
		}
	}
	return result
}

// NewBandwidthCollector creates a new bandwidth collector.
func NewBandwidthCollector(interfaces []string, sampleRate, retention time.Duration) *BandwidthCollector {
	// Calculate buffer size: retention / sampleRate
	bufferSize := int(retention / sampleRate)
	if bufferSize < 1 {
		bufferSize = 1
	}

	history := make(map[string]*ringBuffer)
	for _, iface := range interfaces {
		history[iface] = newRingBuffer(bufferSize)
	}

	return &BandwidthCollector{
		interfaces: interfaces,
		sampleRate: sampleRate,
		retention:  retention,
		history:    history,
		prevStats:  make(map[string]interfaceStats),
		done:       make(chan struct{}),
	}
}

// Start begins the background sampling goroutine.
func (c *BandwidthCollector) Start(ctx context.Context) {
	ctx, c.cancel = context.WithCancel(ctx)

	go func() {
		defer close(c.done)

		// Take initial sample to establish baseline
		c.sample()

		ticker := time.NewTicker(c.sampleRate)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				c.sample()
			}
		}
	}()
}

// Stop stops the background sampling goroutine.
func (c *BandwidthCollector) Stop() {
	if c.cancel != nil {
		c.cancel()
		<-c.done
	}
}

// sample takes a single bandwidth sample.
func (c *BandwidthCollector) sample() {
	stats, err := readInterfaceStats()
	if err != nil {
		return
	}

	now := time.Now()

	c.mu.Lock()
	defer c.mu.Unlock()

	// Calculate rates if we have previous stats
	if !c.prevTime.IsZero() {
		elapsed := now.Sub(c.prevTime).Seconds()
		if elapsed > 0 {
			for _, iface := range c.interfaces {
				current, ok := stats[iface]
				if !ok {
					continue
				}

				prev, hasPrev := c.prevStats[iface]
				if !hasPrev {
					c.prevStats[iface] = current
					continue
				}

				// Calculate bytes per second
				var rxBps, txBps uint64
				if current.rxBytes >= prev.rxBytes {
					rxBps = uint64(float64(current.rxBytes-prev.rxBytes) / elapsed)
				}
				if current.txBytes >= prev.txBytes {
					txBps = uint64(float64(current.txBytes-prev.txBytes) / elapsed)
				}

				// Add to ring buffer
				if buf, ok := c.history[iface]; ok {
					buf.add(BandwidthSample{
						Timestamp: now,
						RxBps:     rxBps,
						TxBps:     txBps,
					})
				}

				c.prevStats[iface] = current
			}
		}
	}

	// Store current stats for next iteration
	for iface, stat := range stats {
		c.prevStats[iface] = stat
	}
	c.prevTime = now
}

// GetHistory returns bandwidth history for an interface.
func (c *BandwidthCollector) GetHistory(iface string, since time.Duration) *InterfaceHistory {
	c.mu.RLock()
	defer c.mu.RUnlock()

	buf, ok := c.history[iface]
	if !ok {
		return &InterfaceHistory{Name: iface, Samples: nil}
	}

	var samples []BandwidthSample
	if since > 0 {
		samples = buf.getSince(time.Now().Add(-since))
	} else {
		samples = buf.getAll()
	}

	return &InterfaceHistory{
		Name:    iface,
		Samples: samples,
	}
}

// GetAllHistory returns bandwidth history for all monitored interfaces.
func (c *BandwidthCollector) GetAllHistory(since time.Duration) []*InterfaceHistory {
	c.mu.RLock()
	defer c.mu.RUnlock()

	result := make([]*InterfaceHistory, 0, len(c.interfaces))
	sinceTime := time.Now().Add(-since)

	for _, iface := range c.interfaces {
		buf, ok := c.history[iface]
		if !ok {
			continue
		}

		var samples []BandwidthSample
		if since > 0 {
			samples = buf.getSince(sinceTime)
		} else {
			samples = buf.getAll()
		}

		result = append(result, &InterfaceHistory{
			Name:    iface,
			Samples: samples,
		})
	}

	return result
}

// readInterfaceStats reads network interface stats from /proc/net/dev.
func readInterfaceStats() (map[string]interfaceStats, error) {
	file, err := os.Open("/proc/net/dev")
	if err != nil {
		return nil, err
	}
	defer file.Close()

	stats := make(map[string]interfaceStats)
	scanner := bufio.NewScanner(file)

	// Skip header lines
	scanner.Scan() // Inter-|   Receive                                                ...
	scanner.Scan() //  face |bytes    packets errs drop fifo frame compressed ...

	for scanner.Scan() {
		line := scanner.Text()

		// Parse line: interface: rx_bytes rx_packets ... tx_bytes tx_packets ...
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			continue
		}

		ifaceName := strings.TrimSpace(parts[0])
		fields := strings.Fields(parts[1])
		if len(fields) < 10 {
			continue
		}

		rxBytes, _ := strconv.ParseUint(fields[0], 10, 64)
		txBytes, _ := strconv.ParseUint(fields[8], 10, 64)

		stats[ifaceName] = interfaceStats{
			rxBytes: rxBytes,
			txBytes: txBytes,
		}
	}

	return stats, scanner.Err()
}

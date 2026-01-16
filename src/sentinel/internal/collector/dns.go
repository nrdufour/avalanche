package collector

import (
	"context"
	"net"
	"sync"
	"time"
)

// DNSCache provides cached reverse DNS lookups.
type DNSCache struct {
	cache     map[string]cacheEntry
	mu        sync.RWMutex
	maxSize   int
	ttl       time.Duration
	timeout   time.Duration
}

type cacheEntry struct {
	hostname string
	expires  time.Time
}

// NewDNSCache creates a new DNS cache with the specified parameters.
func NewDNSCache(maxSize int, ttl, timeout time.Duration) *DNSCache {
	if maxSize <= 0 {
		maxSize = 5000
	}
	if ttl <= 0 {
		ttl = time.Hour
	}
	if timeout <= 0 {
		timeout = 500 * time.Millisecond
	}

	return &DNSCache{
		cache:   make(map[string]cacheEntry),
		maxSize: maxSize,
		ttl:     ttl,
		timeout: timeout,
	}
}

// LookupAddr returns the hostname for an IP address.
// Returns empty string if lookup fails or times out.
// Results are cached for the configured TTL.
func (d *DNSCache) LookupAddr(ipStr string) string {
	// Check cache first
	d.mu.RLock()
	if entry, ok := d.cache[ipStr]; ok && time.Now().Before(entry.expires) {
		d.mu.RUnlock()
		return entry.hostname
	}
	d.mu.RUnlock()

	// Skip private IPs - they won't have useful reverse DNS
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return ""
	}
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() {
		return ""
	}

	// Perform lookup with timeout
	ctx, cancel := context.WithTimeout(context.Background(), d.timeout)
	defer cancel()

	var hostname string
	done := make(chan struct{})
	go func() {
		names, err := net.LookupAddr(ipStr)
		if err == nil && len(names) > 0 {
			// Remove trailing dot from FQDN
			hostname = names[0]
			if len(hostname) > 0 && hostname[len(hostname)-1] == '.' {
				hostname = hostname[:len(hostname)-1]
			}
		}
		close(done)
	}()

	select {
	case <-done:
		// Lookup completed
	case <-ctx.Done():
		// Timeout
		hostname = ""
	}

	// Cache the result (even empty string to avoid repeated lookups)
	d.mu.Lock()
	// Simple eviction: clear half when full
	if len(d.cache) >= d.maxSize {
		count := 0
		for k := range d.cache {
			delete(d.cache, k)
			count++
			if count >= d.maxSize/2 {
				break
			}
		}
	}
	d.cache[ipStr] = cacheEntry{
		hostname: hostname,
		expires:  time.Now().Add(d.ttl),
	}
	d.mu.Unlock()

	return hostname
}

// LookupAddrAsync performs a non-blocking reverse DNS lookup.
// Returns immediately with cached result or empty string.
// Triggers a background lookup if not cached.
func (d *DNSCache) LookupAddrAsync(ipStr string) string {
	// Check cache first
	d.mu.RLock()
	if entry, ok := d.cache[ipStr]; ok && time.Now().Before(entry.expires) {
		d.mu.RUnlock()
		return entry.hostname
	}
	d.mu.RUnlock()

	// Trigger background lookup
	go d.LookupAddr(ipStr)

	return ""
}

// Clear removes all entries from the cache.
func (d *DNSCache) Clear() {
	d.mu.Lock()
	d.cache = make(map[string]cacheEntry)
	d.mu.Unlock()
}

// Size returns the current number of cached entries.
func (d *DNSCache) Size() int {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return len(d.cache)
}

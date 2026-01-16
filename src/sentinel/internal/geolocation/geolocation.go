// Package geolocation provides IP geolocation lookups using MaxMind GeoLite2 databases.
package geolocation

import (
	"net"
	"sync"

	"github.com/oschwald/maxminddb-golang"
)

// countryRecord is the structure for MaxMind country data.
type countryRecord struct {
	Country struct {
		ISOCode string `maxminddb:"iso_code"`
	} `maxminddb:"country"`
}

// Service provides IP geolocation lookups with caching.
type Service struct {
	reader    *maxminddb.Reader
	cache     map[string]string
	cacheMu   sync.RWMutex
	cacheSize int
	enabled   bool
}

// NewService creates a new geolocation service.
// If databasePath is empty or the database cannot be opened, the service
// will operate in disabled mode and return empty strings for all lookups.
func NewService(databasePath string, cacheSize int) *Service {
	s := &Service{
		cache:     make(map[string]string),
		cacheSize: cacheSize,
		enabled:   false,
	}

	if databasePath == "" {
		return s
	}

	reader, err := maxminddb.Open(databasePath)
	if err != nil {
		// Database not available, service will be disabled
		return s
	}

	s.reader = reader
	s.enabled = true
	return s
}

// Close closes the MaxMind database reader.
func (s *Service) Close() error {
	if s.reader != nil {
		return s.reader.Close()
	}
	return nil
}

// Enabled returns true if the geolocation service is operational.
func (s *Service) Enabled() bool {
	return s.enabled
}

// LookupCountry returns the ISO country code for an IP address.
// Returns empty string if the IP is private, invalid, or lookup fails.
func (s *Service) LookupCountry(ipStr string) string {
	if !s.enabled {
		return ""
	}

	// Check cache first
	s.cacheMu.RLock()
	if code, ok := s.cache[ipStr]; ok {
		s.cacheMu.RUnlock()
		return code
	}
	s.cacheMu.RUnlock()

	ip := net.ParseIP(ipStr)
	if ip == nil {
		return ""
	}

	// Skip private/internal IPs
	if isPrivateIP(ip) {
		return ""
	}

	// Lookup in database
	var record countryRecord
	err := s.reader.Lookup(ip, &record)
	if err != nil {
		return ""
	}

	code := record.Country.ISOCode

	// Cache the result
	s.cacheMu.Lock()
	// Simple cache eviction: clear half when full
	if len(s.cache) >= s.cacheSize {
		count := 0
		for k := range s.cache {
			delete(s.cache, k)
			count++
			if count >= s.cacheSize/2 {
				break
			}
		}
	}
	s.cache[ipStr] = code
	s.cacheMu.Unlock()

	return code
}

// LookupCountryWithFlag returns the country code and flag emoji.
// Returns empty strings if lookup fails.
func (s *Service) LookupCountryWithFlag(ipStr string) (code string, flag string) {
	code = s.LookupCountry(ipStr)
	if code == "" {
		return "", ""
	}
	return code, countryCodeToFlag(code)
}

// isPrivateIP checks if an IP is in a private/reserved range.
func isPrivateIP(ip net.IP) bool {
	if ip4 := ip.To4(); ip4 != nil {
		// 10.0.0.0/8
		if ip4[0] == 10 {
			return true
		}
		// 172.16.0.0/12
		if ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31 {
			return true
		}
		// 192.168.0.0/16
		if ip4[0] == 192 && ip4[1] == 168 {
			return true
		}
		// 127.0.0.0/8 (loopback)
		if ip4[0] == 127 {
			return true
		}
		// 169.254.0.0/16 (link-local)
		if ip4[0] == 169 && ip4[1] == 254 {
			return true
		}
		// 100.64.0.0/10 (CGNAT / Tailscale)
		if ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127 {
			return true
		}
	}

	// IPv6 private ranges
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsPrivate() {
		return true
	}

	return false
}

// countryCodeToFlag converts a 2-letter ISO country code to a flag emoji.
// Uses regional indicator symbols (U+1F1E6 to U+1F1FF).
func countryCodeToFlag(code string) string {
	if len(code) != 2 {
		return ""
	}
	// Convert each letter to regional indicator symbol
	// A = U+1F1E6, B = U+1F1E7, etc.
	first := rune(code[0])
	second := rune(code[1])

	if first < 'A' || first > 'Z' || second < 'A' || second > 'Z' {
		return ""
	}

	return string(rune(0x1F1E6+first-'A')) + string(rune(0x1F1E6+second-'A'))
}

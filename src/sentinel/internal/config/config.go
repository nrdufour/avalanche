// Package config handles configuration loading and validation for Sentinel.
package config

import (
	"fmt"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Config represents the complete application configuration.
type Config struct {
	Server     ServerConfig     `yaml:"server"`
	Auth       AuthConfig       `yaml:"auth"`
	Session    SessionConfig    `yaml:"session"`
	Services   ServicesConfig   `yaml:"services"`
	Collectors CollectorsConfig `yaml:"collectors"`
	Logging    LoggingConfig    `yaml:"logging"`
}

// ServerConfig holds HTTP server settings.
type ServerConfig struct {
	Host         string        `yaml:"host"`
	Port         int           `yaml:"port"`
	ReadTimeout  time.Duration `yaml:"read_timeout"`
	WriteTimeout time.Duration `yaml:"write_timeout"`
}

// AuthConfig holds authentication configuration.
type AuthConfig struct {
	Local LocalAuthConfig `yaml:"local"`
	OIDC  OIDCConfig      `yaml:"oidc"`
}

// LocalAuthConfig holds local username/password authentication settings.
type LocalAuthConfig struct {
	Enabled bool       `yaml:"enabled"`
	Users   []UserAuth `yaml:"users"`
}

// UserAuth represents a local user with credentials.
type UserAuth struct {
	Username     string `yaml:"username"`
	PasswordHash string `yaml:"password_hash"`
	Role         string `yaml:"role"`
}

// OIDCConfig holds OIDC/OAuth2 authentication settings.
type OIDCConfig struct {
	Enabled          bool              `yaml:"enabled"`
	Issuer           string            `yaml:"issuer"`
	ClientID         string            `yaml:"client_id"`
	ClientSecret     string            `yaml:"client_secret"`
	ClientSecretFile string            `yaml:"client_secret_file"`
	RedirectURL      string            `yaml:"redirect_url"`
	Scopes           []string          `yaml:"scopes"`
	RoleMapping      map[string]string `yaml:"role_mapping"`
}

// SessionConfig holds session management settings.
type SessionConfig struct {
	Secret     string        `yaml:"secret"`
	SecretFile string        `yaml:"secret_file"`
	Lifetime   time.Duration `yaml:"lifetime"`
	Secure     bool          `yaml:"secure"`
}

// ServicesConfig holds the list of services to monitor.
type ServicesConfig struct {
	Systemd []SystemdService `yaml:"systemd"`
}

// SystemdService represents a systemd service to monitor.
type SystemdService struct {
	Name        string `yaml:"name"`
	DisplayName string `yaml:"display_name"`
	Description string `yaml:"description"`
}

// CollectorsConfig holds data collector settings.
type CollectorsConfig struct {
	Kea       KeaConfig       `yaml:"kea"`
	AdGuard   AdGuardConfig   `yaml:"adguard"`
	Network   NetworkConfig   `yaml:"network"`
	System    SystemConfig    `yaml:"system"`
	WAN       WANConfig       `yaml:"wan"`
	Tailscale TailscaleConfig `yaml:"tailscale"`
	Bandwidth BandwidthConfig `yaml:"bandwidth"`
	LLDP      LLDPConfig      `yaml:"lldp"`
}

// WANConfig holds WAN status monitoring settings.
type WANConfig struct {
	Enabled        bool          `yaml:"enabled"`
	LatencyTargets []string      `yaml:"latency_targets"`
	CacheDuration  time.Duration `yaml:"cache_duration"`
}

// TailscaleConfig holds Tailscale monitoring settings.
type TailscaleConfig struct {
	Enabled bool `yaml:"enabled"`
}

// BandwidthConfig holds bandwidth monitoring settings.
type BandwidthConfig struct {
	Enabled    bool          `yaml:"enabled"`
	SampleRate time.Duration `yaml:"sample_rate"`
	Retention  time.Duration `yaml:"retention"`
}

// LLDPConfig holds LLDP neighbor discovery settings.
type LLDPConfig struct {
	Enabled bool `yaml:"enabled"`
}

// SystemConfig holds system resource monitoring settings.
type SystemConfig struct {
	DiskMountPoints []string `yaml:"disk_mount_points"`
}

// KeaConfig holds Kea DHCP collector settings.
type KeaConfig struct {
	ControlSocket string `yaml:"control_socket"`
	LeaseFile     string `yaml:"lease_file"`
}

// AdGuardConfig holds AdGuard Home API settings.
type AdGuardConfig struct {
	APIURL       string `yaml:"api_url"`
	Username     string `yaml:"username"`
	PasswordFile string `yaml:"password_file"`
}

// NetworkConfig holds network interface monitoring settings.
type NetworkConfig struct {
	Interfaces []NetworkInterface `yaml:"interfaces"`
}

// NetworkInterface represents a network interface to monitor.
type NetworkInterface struct {
	Name        string `yaml:"name"`
	DisplayName string `yaml:"display_name"`
	Description string `yaml:"description"`
}

// LoggingConfig holds logging settings.
type LoggingConfig struct {
	Level  string `yaml:"level"`
	Format string `yaml:"format"`
}

// Load reads and parses the configuration file.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config file: %w", err)
	}

	cfg := &Config{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parsing config file: %w", err)
	}

	// Apply defaults
	cfg.applyDefaults()

	// Load secrets from files if specified
	if err := cfg.loadSecrets(); err != nil {
		return nil, fmt.Errorf("loading secrets: %w", err)
	}

	// Validate configuration
	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("validating config: %w", err)
	}

	return cfg, nil
}

// applyDefaults sets default values for unspecified configuration options.
func (c *Config) applyDefaults() {
	// Server defaults
	if c.Server.Host == "" {
		c.Server.Host = "127.0.0.1"
	}
	if c.Server.Port == 0 {
		c.Server.Port = 8080
	}
	if c.Server.ReadTimeout == 0 {
		c.Server.ReadTimeout = 30 * time.Second
	}
	if c.Server.WriteTimeout == 0 {
		c.Server.WriteTimeout = 30 * time.Second
	}

	// Session defaults
	if c.Session.Lifetime == 0 {
		c.Session.Lifetime = 24 * time.Hour
	}

	// Logging defaults
	if c.Logging.Level == "" {
		c.Logging.Level = "info"
	}
	if c.Logging.Format == "" {
		c.Logging.Format = "json"
	}


	// System collector defaults
	if len(c.Collectors.System.DiskMountPoints) == 0 {
		c.Collectors.System.DiskMountPoints = []string{"/"}
	}

	// WAN collector defaults
	if len(c.Collectors.WAN.LatencyTargets) == 0 {
		c.Collectors.WAN.LatencyTargets = []string{"1.1.1.1", "8.8.8.8"}
	}
	if c.Collectors.WAN.CacheDuration == 0 {
		c.Collectors.WAN.CacheDuration = 5 * time.Minute
	}

	// Bandwidth collector defaults
	if c.Collectors.Bandwidth.SampleRate == 0 {
		c.Collectors.Bandwidth.SampleRate = 5 * time.Second
	}
	if c.Collectors.Bandwidth.Retention == 0 {
		c.Collectors.Bandwidth.Retention = 1 * time.Hour
	}
}

// loadSecrets reads secrets from files when file paths are specified.
func (c *Config) loadSecrets() error {
	// Load session secret from file
	if c.Session.SecretFile != "" {
		secret, err := readSecretFile(c.Session.SecretFile)
		if err != nil {
			return fmt.Errorf("reading session secret: %w", err)
		}
		c.Session.Secret = secret
	}

	// Load OIDC client secret from file
	if c.Auth.OIDC.ClientSecretFile != "" {
		secret, err := readSecretFile(c.Auth.OIDC.ClientSecretFile)
		if err != nil {
			return fmt.Errorf("reading OIDC client secret: %w", err)
		}
		c.Auth.OIDC.ClientSecret = secret
	}

	return nil
}

// readSecretFile reads a secret from a file, trimming whitespace.
func readSecretFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	// Trim whitespace (common with mounted secrets)
	return strings.TrimSpace(string(data)), nil
}

// validate checks that the configuration is valid.
func (c *Config) validate() error {
	// Must have at least one authentication method enabled
	if !c.Auth.Local.Enabled && !c.Auth.OIDC.Enabled {
		return fmt.Errorf("at least one authentication method must be enabled")
	}

	// Validate local auth if enabled
	if c.Auth.Local.Enabled {
		if len(c.Auth.Local.Users) == 0 {
			return fmt.Errorf("local auth enabled but no users configured")
		}
		for i, user := range c.Auth.Local.Users {
			if user.Username == "" {
				return fmt.Errorf("user %d: username is required", i)
			}
			if user.PasswordHash == "" {
				return fmt.Errorf("user %d (%s): password_hash is required", i, user.Username)
			}
			if user.Role == "" {
				return fmt.Errorf("user %d (%s): role is required", i, user.Username)
			}
			if !isValidRole(user.Role) {
				return fmt.Errorf("user %d (%s): invalid role %q (must be admin, operator, or viewer)", i, user.Username, user.Role)
			}
		}
	}

	// Validate OIDC if enabled
	if c.Auth.OIDC.Enabled {
		if c.Auth.OIDC.Issuer == "" {
			return fmt.Errorf("OIDC issuer is required when OIDC is enabled")
		}
		if c.Auth.OIDC.ClientID == "" {
			return fmt.Errorf("OIDC client_id is required when OIDC is enabled")
		}
		if c.Auth.OIDC.RedirectURL == "" {
			return fmt.Errorf("OIDC redirect_url is required when OIDC is enabled")
		}
	}

	// Session secret is required
	if c.Session.Secret == "" {
		return fmt.Errorf("session secret is required")
	}

	return nil
}

// isValidRole checks if the role is one of the allowed values.
func isValidRole(role string) bool {
	switch role {
	case "admin", "operator", "viewer":
		return true
	default:
		return false
	}
}

// Address returns the server address in host:port format.
func (c *Config) Address() string {
	return fmt.Sprintf("%s:%d", c.Server.Host, c.Server.Port)
}

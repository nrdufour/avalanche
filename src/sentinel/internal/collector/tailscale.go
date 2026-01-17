package collector

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"sort"
	"time"
)

// TailscalePeer represents a Tailscale peer.
type TailscalePeer struct {
	ID             string    `json:"id"`
	HostName       string    `json:"hostname"`
	DNSName        string    `json:"dns_name"`
	TailscaleIPs   []string  `json:"tailscale_ips"`
	Online         bool      `json:"online"`
	LastSeen       time.Time `json:"last_seen"`
	OS             string    `json:"os"`
	ExitNode       bool      `json:"exit_node"`
	ExitNodeOption bool      `json:"exit_node_option"`
	SubnetRouter   bool      `json:"subnet_router"`
	Subnets        []string  `json:"subnets,omitempty"`
	IsSelf         bool      `json:"is_self"`
}

// TailscaleStatus represents the overall Tailscale status.
type TailscaleStatus struct {
	BackendState string          `json:"backend_state"`
	Self         TailscalePeer   `json:"self"`
	Peers        []TailscalePeer `json:"peers"`
	MagicDNSSuffix string        `json:"magic_dns_suffix"`
}

// tailscaleStatusJSON represents the raw JSON from tailscale status --json.
type tailscaleStatusJSON struct {
	BackendState   string                    `json:"BackendState"`
	Self           tailscalePeerJSON         `json:"Self"`
	Peer           map[string]tailscalePeerJSON `json:"Peer"`
	MagicDNSSuffix string                    `json:"MagicDNSSuffix"`
	CurrentTailnet *tailscaleTailnetJSON     `json:"CurrentTailnet"`
}

type tailscalePeerJSON struct {
	ID             string    `json:"ID"`
	PublicKey      string    `json:"PublicKey"`
	HostName       string    `json:"HostName"`
	DNSName        string    `json:"DNSName"`
	OS             string    `json:"OS"`
	TailscaleIPs   []string  `json:"TailscaleIPs"`
	AllowedIPs     []string  `json:"AllowedIPs"`
	PrimaryRoutes  []string  `json:"PrimaryRoutes"`
	Online         bool      `json:"Online"`
	ExitNode       bool      `json:"ExitNode"`
	ExitNodeOption bool      `json:"ExitNodeOption"`
	LastSeen       time.Time `json:"LastSeen"`
}

type tailscaleTailnetJSON struct {
	Name            string `json:"Name"`
	MagicDNSSuffix  string `json:"MagicDNSSuffix"`
	MagicDNSEnabled bool   `json:"MagicDNSEnabled"`
}

// TailscaleCollector collects Tailscale peer information.
type TailscaleCollector struct{}

// NewTailscaleCollector creates a new Tailscale collector.
func NewTailscaleCollector() *TailscaleCollector {
	return &TailscaleCollector{}
}

// Collect gathers Tailscale status.
func (c *TailscaleCollector) Collect(ctx context.Context) (*TailscaleStatus, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "tailscale", "status", "--json")
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("running tailscale status: %w", err)
	}

	var rawStatus tailscaleStatusJSON
	if err := json.Unmarshal(output, &rawStatus); err != nil {
		return nil, fmt.Errorf("parsing tailscale status: %w", err)
	}

	status := &TailscaleStatus{
		BackendState:   rawStatus.BackendState,
		MagicDNSSuffix: rawStatus.MagicDNSSuffix,
		Self:           convertPeer(rawStatus.Self, true),
	}

	// Get magic DNS suffix from tailnet if available
	if rawStatus.CurrentTailnet != nil && rawStatus.CurrentTailnet.MagicDNSSuffix != "" {
		status.MagicDNSSuffix = rawStatus.CurrentTailnet.MagicDNSSuffix
	}

	// Convert peers
	peers := make([]TailscalePeer, 0, len(rawStatus.Peer))
	for _, p := range rawStatus.Peer {
		peers = append(peers, convertPeer(p, false))
	}

	// Sort peers: online first, then by hostname
	sort.Slice(peers, func(i, j int) bool {
		if peers[i].Online != peers[j].Online {
			return peers[i].Online // online peers first
		}
		return peers[i].HostName < peers[j].HostName
	})

	status.Peers = peers

	return status, nil
}

// convertPeer converts raw peer JSON to our TailscalePeer struct.
func convertPeer(p tailscalePeerJSON, isSelf bool) TailscalePeer {
	peer := TailscalePeer{
		ID:             p.ID,
		HostName:       p.HostName,
		DNSName:        p.DNSName,
		TailscaleIPs:   p.TailscaleIPs,
		Online:         p.Online,
		LastSeen:       p.LastSeen,
		OS:             p.OS,
		ExitNode:       p.ExitNode,
		ExitNodeOption: p.ExitNodeOption,
		IsSelf:         isSelf,
	}

	// Check if this is a subnet router by looking at routes
	// PrimaryRoutes contains CIDR ranges being advertised
	for _, route := range p.PrimaryRoutes {
		// Skip tailscale IP ranges (100.64.0.0/10)
		if route != "" && !isInTailscaleRange(route) {
			peer.SubnetRouter = true
			peer.Subnets = append(peer.Subnets, route)
		}
	}

	return peer
}

// isInTailscaleRange checks if a CIDR is in the Tailscale IP range.
func isInTailscaleRange(cidr string) bool {
	// Tailscale uses 100.64.0.0/10 (CGNAT range)
	// Also skip ::/0 and 0.0.0.0/0 which are exit node routes
	return cidr == "::/0" || cidr == "0.0.0.0/0"
}

// IsAvailable checks if Tailscale is available on this system.
func (c *TailscaleCollector) IsAvailable(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "tailscale", "version")
	return cmd.Run() == nil
}

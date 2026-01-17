// Package collector provides data collectors for Sentinel.
package collector

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// LLDPNeighbor represents an LLDP-discovered neighbor.
type LLDPNeighbor struct {
	LocalPort    string `json:"local_port"`
	SystemName   string `json:"system_name"`
	PortID       string `json:"port_id"`
	PortDesc     string `json:"port_desc,omitempty"`
	ManagementIP string `json:"management_ip,omitempty"`
	Capabilities string `json:"capabilities,omitempty"`
	ChassisID    string `json:"chassis_id,omitempty"`
}

// LLDPCollector collects LLDP neighbor discovery data.
type LLDPCollector struct {
	lldpctlPath string
	timeout     time.Duration
}

// NewLLDPCollector creates a new LLDP collector.
func NewLLDPCollector(timeout time.Duration) *LLDPCollector {
	// Find lldpctl binary
	lldpctlPath := "/run/current-system/sw/bin/lldpctl"
	if path, err := exec.LookPath("lldpctl"); err == nil {
		lldpctlPath = path
	}

	return &LLDPCollector{
		lldpctlPath: lldpctlPath,
		timeout:     timeout,
	}
}

// GetNeighbors retrieves all LLDP neighbors.
func (c *LLDPCollector) GetNeighbors(ctx context.Context) ([]LLDPNeighbor, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, c.lldpctlPath, "-f", "json")
	output, err := cmd.Output()
	if err != nil {
		// Include stderr in error for debugging
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("lldpctl failed: %w, stderr: %s", err, string(exitErr.Stderr))
		}
		return nil, fmt.Errorf("lldpctl failed: %w", err)
	}

	// Handle empty output
	if len(output) == 0 {
		return []LLDPNeighbor{}, nil
	}

	return c.parseLLDPOutput(output)
}

// GetPath returns the path to lldpctl being used.
func (c *LLDPCollector) GetPath() string {
	return c.lldpctlPath
}

// lldpctlOutput represents the JSON output structure from lldpctl.
// Format: {"lldp": {"interface": [{"ifname": {...}}, ...]}}
type lldpctlOutput struct {
	LLDP struct {
		Interface []map[string]lldpInterfaceData `json:"interface"`
	} `json:"lldp"`
}

// Alternate format: lldpctl can return lldp as a map
type lldpctlOutputMap struct {
	LLDP map[string]lldpInterfaceData `json:"lldp"`
}

// Legacy format with named interfaces
type lldpctlOutputLegacy struct {
	LLDPInterfaces []lldpInterface `json:"lldp"`
}

type lldpInterface struct {
	Name      string            `json:"name"`
	Interface lldpInterfaceData `json:"interface"`
}

type lldpInterfaceData struct {
	Via     string              `json:"via"`
	RID     string              `json:"rid"`
	Age     string              `json:"age"`
	Chassis map[string]chassis  `json:"chassis,omitempty"`
	Port    portInfo            `json:"port,omitempty"`
}

type chassis struct {
	ID          chassisID     `json:"id,omitempty"`
	Name        string        `json:"name,omitempty"`
	Descr       string        `json:"descr,omitempty"`
	Capability  []capability  `json:"capability,omitempty"`
	MgmtIP      interface{}   `json:"mgmt-ip,omitempty"` // Can be string or []string
}

type chassisID struct {
	Type  string `json:"type"`
	Value string `json:"value"`
}

type portInfo struct {
	ID    portID `json:"id,omitempty"`
	Descr string `json:"descr,omitempty"`
}

type portID struct {
	Type  string `json:"type"`
	Value string `json:"value"`
}

type capability struct {
	Type    string `json:"type"`
	Enabled bool   `json:"enabled"`
}

// parseLLDPOutput parses the JSON output from lldpctl.
func (c *LLDPCollector) parseLLDPOutput(output []byte) ([]LLDPNeighbor, error) {
	var neighbors []LLDPNeighbor

	// First try the common format: {"lldp": {"interface": [{"ifname": {...}}, ...]}}
	var result lldpctlOutput
	if err := json.Unmarshal(output, &result); err == nil && len(result.LLDP.Interface) > 0 {
		for _, ifaceMap := range result.LLDP.Interface {
			for ifaceName, ifaceData := range ifaceMap {
				neighbor := c.parseInterfaceData(ifaceName, ifaceData)
				if neighbor != nil {
					neighbors = append(neighbors, *neighbor)
				}
			}
		}
		return neighbors, nil
	}

	// Try legacy array format
	var resultLegacy lldpctlOutputLegacy
	if err := json.Unmarshal(output, &resultLegacy); err == nil && len(resultLegacy.LLDPInterfaces) > 0 {
		for _, iface := range resultLegacy.LLDPInterfaces {
			neighbor := c.parseInterfaceData(iface.Name, iface.Interface)
			if neighbor != nil {
				neighbors = append(neighbors, *neighbor)
			}
		}
		return neighbors, nil
	}

	// Try parsing as map format (different lldpctl versions)
	var resultMap lldpctlOutputMap
	if err := json.Unmarshal(output, &resultMap); err == nil && len(resultMap.LLDP) > 0 {
		for ifaceName, ifaceData := range resultMap.LLDP {
			neighbor := c.parseInterfaceData(ifaceName, ifaceData)
			if neighbor != nil {
				neighbors = append(neighbors, *neighbor)
			}
		}
		return neighbors, nil
	}

	// Try generic parsing for nested interface structure
	var generic map[string]interface{}
	if err := json.Unmarshal(output, &generic); err != nil {
		return nil, err
	}

	// Walk the structure to find interface data
	if lldp, ok := generic["lldp"].(map[string]interface{}); ok {
		// Check for "interface" array
		if ifaceArray, ok := lldp["interface"].([]interface{}); ok {
			for _, ifaceRaw := range ifaceArray {
				if ifaceMap, ok := ifaceRaw.(map[string]interface{}); ok {
					for ifaceName, ifaceDataRaw := range ifaceMap {
						if ifaceData, ok := ifaceDataRaw.(map[string]interface{}); ok {
							neighbor := c.parseGenericInterfaceData(ifaceName, ifaceData)
							if neighbor != nil {
								neighbors = append(neighbors, *neighbor)
							}
						}
					}
				}
			}
		} else {
			// Direct map format
			for ifaceName, ifaceDataRaw := range lldp {
				if ifaceData, ok := ifaceDataRaw.(map[string]interface{}); ok {
					neighbor := c.parseGenericInterfaceData(ifaceName, ifaceData)
					if neighbor != nil {
						neighbors = append(neighbors, *neighbor)
					}
				}
			}
		}
	}

	return neighbors, nil
}

// parseInterfaceData extracts neighbor info from interface data.
func (c *LLDPCollector) parseInterfaceData(localPort string, data lldpInterfaceData) *LLDPNeighbor {
	if len(data.Chassis) == 0 {
		return nil
	}

	neighbor := &LLDPNeighbor{
		LocalPort: localPort,
	}

	// Get chassis info (there should be one entry keyed by chassis name)
	for chassisName, ch := range data.Chassis {
		neighbor.SystemName = chassisName
		if ch.Name != "" {
			neighbor.SystemName = ch.Name
		}

		if ch.ID.Value != "" {
			neighbor.ChassisID = ch.ID.Value
		}

		// Parse capabilities
		var caps []string
		for _, cap := range ch.Capability {
			if cap.Enabled {
				caps = append(caps, cap.Type)
			}
		}
		if len(caps) > 0 {
			neighbor.Capabilities = strings.Join(caps, ", ")
		}

		// Parse management IP
		switch v := ch.MgmtIP.(type) {
		case string:
			neighbor.ManagementIP = v
		case []interface{}:
			if len(v) > 0 {
				if s, ok := v[0].(string); ok {
					neighbor.ManagementIP = s
				}
			}
		}
	}

	// Get port info
	if data.Port.ID.Value != "" {
		neighbor.PortID = data.Port.ID.Value
	}
	if data.Port.Descr != "" {
		neighbor.PortDesc = data.Port.Descr
	}

	return neighbor
}

// parseGenericInterfaceData handles generic JSON parsing for varied lldpctl output.
func (c *LLDPCollector) parseGenericInterfaceData(localPort string, data map[string]interface{}) *LLDPNeighbor {
	neighbor := &LLDPNeighbor{
		LocalPort: localPort,
	}

	// Look for chassis info
	if chassisRaw, ok := data["chassis"].(map[string]interface{}); ok {
		for chassisName, chassisDataRaw := range chassisRaw {
			neighbor.SystemName = chassisName
			if chassisData, ok := chassisDataRaw.(map[string]interface{}); ok {
				if name, ok := chassisData["name"].(string); ok && name != "" {
					neighbor.SystemName = name
				}
				if idMap, ok := chassisData["id"].(map[string]interface{}); ok {
					if val, ok := idMap["value"].(string); ok {
						neighbor.ChassisID = val
					}
				}
				// Parse management IP
				switch v := chassisData["mgmt-ip"].(type) {
				case string:
					neighbor.ManagementIP = v
				case []interface{}:
					if len(v) > 0 {
						if s, ok := v[0].(string); ok {
							neighbor.ManagementIP = s
						}
					}
				}
			}
		}
	}

	// Look for port info
	if portRaw, ok := data["port"].(map[string]interface{}); ok {
		if idMap, ok := portRaw["id"].(map[string]interface{}); ok {
			if val, ok := idMap["value"].(string); ok {
				neighbor.PortID = val
			}
		}
		if descr, ok := portRaw["descr"].(string); ok {
			neighbor.PortDesc = descr
		}
	}

	if neighbor.SystemName == "" && neighbor.PortID == "" {
		return nil
	}

	return neighbor
}

// IsAvailable checks if lldpctl is available.
func (c *LLDPCollector) IsAvailable() bool {
	// If it's an absolute path, check if the file exists and is executable
	if strings.HasPrefix(c.lldpctlPath, "/") {
		info, err := exec.LookPath(c.lldpctlPath)
		if err == nil && info != "" {
			return true
		}
		// Also try just running it with --version to see if it works
		cmd := exec.Command(c.lldpctlPath, "-v")
		return cmd.Run() == nil
	}
	// Otherwise check if it's in PATH
	_, err := exec.LookPath(c.lldpctlPath)
	return err == nil
}

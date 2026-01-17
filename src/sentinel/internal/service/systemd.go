// Package service provides service management capabilities.
package service

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-systemd/v22/dbus"
)

// UnitStatus represents the status of a systemd unit.
type UnitStatus struct {
	Name        string
	Description string
	LoadState   string // "loaded", "not-found", "error", etc.
	ActiveState string // "active", "inactive", "failed", etc.
	SubState    string // "running", "dead", "failed", etc.
}

// TimerStatus represents the status of a systemd timer.
type TimerStatus struct {
	Name        string
	Description string
	Active      bool
	NextRun     time.Time
	LastRun     time.Time
	Unit        string // The service unit this timer triggers
}

// SystemdManager manages systemd services via D-Bus.
type SystemdManager struct {
	conn *dbus.Conn
	mu   sync.Mutex
}

// NewSystemdManager creates a new systemd manager.
func NewSystemdManager() (*SystemdManager, error) {
	conn, err := dbus.NewWithContext(context.Background())
	if err != nil {
		return nil, fmt.Errorf("connecting to systemd: %w", err)
	}

	return &SystemdManager{conn: conn}, nil
}

// Close closes the D-Bus connection.
func (m *SystemdManager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.conn != nil {
		m.conn.Close()
		m.conn = nil
	}
}

// GetUnitStatus returns the status of a single unit.
func (m *SystemdManager) GetUnitStatus(ctx context.Context, name string) (*UnitStatus, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.conn == nil {
		return nil, fmt.Errorf("connection closed")
	}

	// Ensure the name has .service suffix if not specified
	if !strings.Contains(name, ".") {
		name = name + ".service"
	}

	units, err := m.conn.ListUnitsByNamesContext(ctx, []string{name})
	if err != nil {
		return nil, fmt.Errorf("listing unit %s: %w", name, err)
	}

	if len(units) == 0 {
		return &UnitStatus{
			Name:        name,
			LoadState:   "not-found",
			ActiveState: "inactive",
			SubState:    "dead",
		}, nil
	}

	unit := units[0]
	return &UnitStatus{
		Name:        unit.Name,
		Description: unit.Description,
		LoadState:   unit.LoadState,
		ActiveState: unit.ActiveState,
		SubState:    unit.SubState,
	}, nil
}

// GetUnitsStatus returns the status of multiple units.
func (m *SystemdManager) GetUnitsStatus(ctx context.Context, names []string) (map[string]*UnitStatus, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.conn == nil {
		return nil, fmt.Errorf("connection closed")
	}

	// Normalize names to include .service suffix
	normalized := make([]string, len(names))
	for i, name := range names {
		if !strings.Contains(name, ".") {
			normalized[i] = name + ".service"
		} else {
			normalized[i] = name
		}
	}

	units, err := m.conn.ListUnitsByNamesContext(ctx, normalized)
	if err != nil {
		return nil, fmt.Errorf("listing units: %w", err)
	}

	result := make(map[string]*UnitStatus)

	// First, mark all requested units as not-found
	for _, name := range normalized {
		result[name] = &UnitStatus{
			Name:        name,
			LoadState:   "not-found",
			ActiveState: "inactive",
			SubState:    "dead",
		}
	}

	// Update with actual status for found units
	for _, unit := range units {
		result[unit.Name] = &UnitStatus{
			Name:        unit.Name,
			Description: unit.Description,
			LoadState:   unit.LoadState,
			ActiveState: unit.ActiveState,
			SubState:    unit.SubState,
		}
	}

	return result, nil
}

// StopUnit stops a systemd unit.
func (m *SystemdManager) StopUnit(ctx context.Context, name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.conn == nil {
		return fmt.Errorf("connection closed")
	}

	if !strings.Contains(name, ".") {
		name = name + ".service"
	}

	jobCh := make(chan string, 1)

	_, err := m.conn.StopUnitContext(ctx, name, "replace", jobCh)
	if err != nil {
		return fmt.Errorf("stopping unit %s: %w", name, err)
	}

	select {
	case result := <-jobCh:
		if result != "done" {
			return fmt.Errorf("stop job failed: %s", result)
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(30 * time.Second):
		return fmt.Errorf("stop timed out")
	}
}

// StartUnit starts a systemd unit.
func (m *SystemdManager) StartUnit(ctx context.Context, name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.conn == nil {
		return fmt.Errorf("connection closed")
	}

	if !strings.Contains(name, ".") {
		name = name + ".service"
	}

	jobCh := make(chan string, 1)

	_, err := m.conn.StartUnitContext(ctx, name, "replace", jobCh)
	if err != nil {
		return fmt.Errorf("starting unit %s: %w", name, err)
	}

	select {
	case result := <-jobCh:
		if result != "done" {
			return fmt.Errorf("start job failed: %s", result)
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(30 * time.Second):
		return fmt.Errorf("start timed out")
	}
}

// IsActive returns true if the unit is in the "active" state.
func (s *UnitStatus) IsActive() bool {
	return s.ActiveState == "active"
}

// IsRunning returns true if the unit is actively running.
func (s *UnitStatus) IsRunning() bool {
	return s.ActiveState == "active" && s.SubState == "running"
}

// IsFailed returns true if the unit is in a failed state.
func (s *UnitStatus) IsFailed() bool {
	return s.ActiveState == "failed"
}

// StatusString returns a simple status string for display.
func (s *UnitStatus) StatusString() string {
	if s.LoadState == "not-found" {
		return "not-found"
	}
	if s.IsFailed() {
		return "failed"
	}
	if s.IsRunning() {
		return "running"
	}
	if s.IsActive() {
		return "active"
	}
	return "stopped"
}

// GetTimers returns the status of all systemd timers.
func (m *SystemdManager) GetTimers(ctx context.Context) ([]*TimerStatus, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.conn == nil {
		return nil, fmt.Errorf("connection closed")
	}

	// List all loaded units and filter for timers
	units, err := m.conn.ListUnitsContext(ctx)
	if err != nil {
		return nil, fmt.Errorf("listing units: %w", err)
	}

	var timers []*TimerStatus
	for _, unit := range units {
		if !strings.HasSuffix(unit.Name, ".timer") {
			continue
		}

		timer := &TimerStatus{
			Name:        unit.Name,
			Description: unit.Description,
			Active:      unit.ActiveState == "active",
			Unit:        strings.TrimSuffix(unit.Name, ".timer") + ".service",
		}

		// Get timer-specific properties
		props, err := m.conn.GetUnitTypePropertiesContext(ctx, unit.Name, "Timer")
		if err == nil {
			// NextElapseUSecRealtime is in microseconds since epoch
			if nextElapse, ok := props["NextElapseUSecRealtime"].(uint64); ok && nextElapse > 0 {
				timer.NextRun = time.UnixMicro(int64(nextElapse))
			}
			// LastTriggerUSec is in microseconds since epoch
			if lastTrigger, ok := props["LastTriggerUSec"].(uint64); ok && lastTrigger > 0 {
				timer.LastRun = time.UnixMicro(int64(lastTrigger))
			}
			// Get the actual unit this timer triggers
			if triggerUnit, ok := props["Unit"].(string); ok && triggerUnit != "" {
				timer.Unit = triggerUnit
			}
		}

		timers = append(timers, timer)
	}

	return timers, nil
}

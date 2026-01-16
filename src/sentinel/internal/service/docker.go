package service

import (
	"context"
	"fmt"
	"strings"

	"github.com/docker/docker/api/types"
	containertypes "github.com/docker/docker/api/types/container"
	"github.com/docker/docker/client"
)

// ContainerStatus represents the status of a Docker container.
type ContainerStatus struct {
	Name    string
	ID      string
	Image   string
	State   string // "running", "exited", "paused", etc.
	Status  string // Human-readable status (e.g., "Up 2 hours")
	Health  string // "healthy", "unhealthy", "starting", or empty
	Running bool
}

// DockerManager manages Docker containers.
type DockerManager struct {
	client *client.Client
}

// NewDockerManager creates a new Docker manager.
func NewDockerManager(socketPath string) (*DockerManager, error) {
	opts := []client.Opt{
		client.WithAPIVersionNegotiation(),
	}

	if socketPath != "" {
		opts = append(opts, client.WithHost(socketPath))
	}

	cli, err := client.NewClientWithOpts(opts...)
	if err != nil {
		return nil, fmt.Errorf("creating docker client: %w", err)
	}

	// Verify connection
	_, err = cli.Ping(context.Background())
	if err != nil {
		cli.Close()
		return nil, fmt.Errorf("connecting to docker: %w", err)
	}

	return &DockerManager{client: cli}, nil
}

// Close closes the Docker client connection.
func (m *DockerManager) Close() error {
	if m.client != nil {
		return m.client.Close()
	}
	return nil
}

// GetContainerStatus returns the status of a container by name.
func (m *DockerManager) GetContainerStatus(ctx context.Context, name string) (*ContainerStatus, error) {
	// List containers (including stopped ones)
	containers, err := m.client.ContainerList(ctx, containertypes.ListOptions{
		All: true,
	})
	if err != nil {
		return nil, fmt.Errorf("listing containers: %w", err)
	}

	// Find container by name
	for _, c := range containers {
		for _, containerName := range c.Names {
			// Container names start with /
			cleanName := strings.TrimPrefix(containerName, "/")
			if cleanName == name {
				status := &ContainerStatus{
					Name:    cleanName,
					ID:      c.ID[:12], // Short ID
					Image:   c.Image,
					State:   c.State,
					Status:  c.Status,
					Running: c.State == "running",
				}

				// Check health status if available
				if c.State == "running" {
					// Inspect container for health check status
					inspect, err := m.client.ContainerInspect(ctx, c.ID)
					if err == nil && inspect.State.Health != nil {
						status.Health = inspect.State.Health.Status
					}
				}

				return status, nil
			}
		}
	}

	return &ContainerStatus{
		Name:    name,
		State:   "not-found",
		Running: false,
	}, nil
}

// GetContainersStatus returns the status of multiple containers by name.
func (m *DockerManager) GetContainersStatus(ctx context.Context, names []string) (map[string]*ContainerStatus, error) {
	// List all containers
	containers, err := m.client.ContainerList(ctx, containertypes.ListOptions{
		All: true,
	})
	if err != nil {
		return nil, fmt.Errorf("listing containers: %w", err)
	}

	// Build lookup map
	containerMap := make(map[string]types.Container)
	for _, c := range containers {
		for _, containerName := range c.Names {
			cleanName := strings.TrimPrefix(containerName, "/")
			containerMap[cleanName] = c
		}
	}

	// Build result
	result := make(map[string]*ContainerStatus)
	for _, name := range names {
		if c, ok := containerMap[name]; ok {
			status := &ContainerStatus{
				Name:    name,
				ID:      c.ID[:12],
				Image:   c.Image,
				State:   c.State,
				Status:  c.Status,
				Running: c.State == "running",
			}

			// Check health if running
			if c.State == "running" {
				inspect, err := m.client.ContainerInspect(ctx, c.ID)
				if err == nil && inspect.State.Health != nil {
					status.Health = inspect.State.Health.Status
				}
			}

			result[name] = status
		} else {
			result[name] = &ContainerStatus{
				Name:    name,
				State:   "not-found",
				Running: false,
			}
		}
	}

	return result, nil
}

// RestartContainer restarts a container by name.
func (m *DockerManager) RestartContainer(ctx context.Context, name string) error {
	// Find container ID by name
	containers, err := m.client.ContainerList(ctx, containertypes.ListOptions{
		All: true,
	})
	if err != nil {
		return fmt.Errorf("listing containers: %w", err)
	}

	var containerID string
	for _, c := range containers {
		for _, containerName := range c.Names {
			cleanName := strings.TrimPrefix(containerName, "/")
			if cleanName == name {
				containerID = c.ID
				break
			}
		}
		if containerID != "" {
			break
		}
	}

	if containerID == "" {
		return fmt.Errorf("container %s not found", name)
	}

	// Restart with 10 second timeout
	timeout := 10
	return m.client.ContainerRestart(ctx, containerID, containertypes.StopOptions{
		Timeout: &timeout,
	})
}

// StopContainer stops a container by name.
func (m *DockerManager) StopContainer(ctx context.Context, name string) error {
	containers, err := m.client.ContainerList(ctx, containertypes.ListOptions{
		All: true,
	})
	if err != nil {
		return fmt.Errorf("listing containers: %w", err)
	}

	var containerID string
	for _, c := range containers {
		for _, containerName := range c.Names {
			cleanName := strings.TrimPrefix(containerName, "/")
			if cleanName == name {
				containerID = c.ID
				break
			}
		}
		if containerID != "" {
			break
		}
	}

	if containerID == "" {
		return fmt.Errorf("container %s not found", name)
	}

	timeout := 10
	return m.client.ContainerStop(ctx, containerID, containertypes.StopOptions{
		Timeout: &timeout,
	})
}

// StartContainer starts a container by name.
func (m *DockerManager) StartContainer(ctx context.Context, name string) error {
	containers, err := m.client.ContainerList(ctx, containertypes.ListOptions{
		All: true,
	})
	if err != nil {
		return fmt.Errorf("listing containers: %w", err)
	}

	var containerID string
	for _, c := range containers {
		for _, containerName := range c.Names {
			cleanName := strings.TrimPrefix(containerName, "/")
			if cleanName == name {
				containerID = c.ID
				break
			}
		}
		if containerID != "" {
			break
		}
	}

	if containerID == "" {
		return fmt.Errorf("container %s not found", name)
	}

	return m.client.ContainerStart(ctx, containerID, containertypes.StartOptions{})
}

// StatusString returns a simple status string for display.
func (s *ContainerStatus) StatusString() string {
	if s.State == "not-found" {
		return "not-found"
	}
	if s.Running {
		if s.Health == "unhealthy" {
			return "unhealthy"
		}
		return "running"
	}
	if s.State == "exited" {
		return "stopped"
	}
	return s.State
}

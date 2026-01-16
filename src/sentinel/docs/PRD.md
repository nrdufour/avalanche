# Sentinel - Gateway Management Tool PRD

## Overview

**Sentinel** is a web-based gateway management and monitoring tool for the `routy` NixOS host. It provides a unified dashboard for monitoring network services, viewing logs, managing DHCP leases, and performing network diagnostics.

**Location**: `src/sentinel/`

## Technology Stack

| Component | Choice | Rationale |
|-----------|--------|-----------|
| Language | Go 1.22+ | Performance, single binary, excellent stdlib |
| Templates | Templ | Type-safe HTML, compile-time checks |
| Interactivity | htmx | Server-side rendering, minimal JS |
| Router | chi/v5 | Lightweight, stdlib-compatible |
| Styling | Tailwind CSS | Utility-first, easy dark mode |
| Session | scs/v2 | Secure session management |
| Metrics | prometheus/client_golang | Native Prometheus integration |

## Features

### 1. Authentication
- **Local auth**: bcrypt-hashed passwords, session cookies
- **Kanidm OIDC**: Optional SSO via `auth.internal` (future)
- **Roles**: admin (full), operator (restart/view), viewer (read-only)

### 2. Dashboard
- Service health cards with real-time status (htmx polling)
- Network interface status (wan0, lan0, lab0, lab1)
- Quick stats: active leases, DNS queries, connections
- System resources (CPU, memory, uptime)

### 3. Service Management
Services to monitor/control:
| Service | Type | Can Restart | Notes |
|---------|------|-------------|-------|
| Kea DHCP4 | systemd | Yes | Primary DHCP server |
| Kea DDNS | systemd | Yes | Dynamic DNS updates |
| Knot DNS | systemd | Yes | Authoritative DNS |
| Kresd | systemd | Yes | Recursive resolver |
| AdGuard Home | systemd | Yes | DNS filtering |
| Nginx | systemd | Yes | Reverse proxy |
| Tailscale | systemd | No | VPN (restart = disconnect) |
| Omada Controller | docker | Yes | WiFi AP management |

**Capabilities**:
- View service status (running/stopped/failed)
- Restart services (with confirmation)
- View service logs (journalctl integration)
- Clear caches (DNS, AdGuard)

### 4. Utilities

#### DHCP Lease Viewer
- List all active leases across networks (lan0, lab0, lab1)
- Search by MAC address, IP, or hostname
- Show lease expiration times
- Reservation status indicator

#### Network Diagnostics
- Ping (with packet loss stats)
- Traceroute (with latency per hop)
- DNS lookup (query any DNS server)
- Port check (TCP connect test)
- Target whitelist for security

#### Firewall Log Viewer
- View blocked connections (nftables logs)
- Filter by source IP, port, protocol
- Real-time streaming via SSE
- Export capability

#### Connection Tracker
- Active NAT connections (conntrack)
- Filter by state, protocol, IP
- Connection count by source/destination
- Bandwidth estimates where available

### 5. Observability
- Prometheus metrics at `/metrics`
- Metrics exposed:
  - `sentinel_service_up{name="..."}` - Service status (1=up, 0=down)
  - `sentinel_dhcp_leases_total{network="..."}` - Active lease count
  - `sentinel_dns_queries_total` - DNS query rate
  - `sentinel_connections_total` - NAT connection count
  - `sentinel_http_requests_total` - Request metrics

### 6. UI/UX
- Dark/light mode toggle (system preference default)
- Professional design with clear visual hierarchy
- Responsive layout (tablet/desktop primary)
- htmx for dynamic updates without page reloads
- Toast notifications for actions

## Project Structure

```
src/sentinel/
├── cmd/sentinel/main.go          # Entry point
├── internal/
│   ├── config/                   # YAML config loading
│   ├── auth/                     # Local + OIDC auth
│   ├── service/                  # systemd/docker management
│   ├── collector/                # Data collectors (kea, knot, etc.)
│   ├── handler/                  # HTTP handlers
│   ├── middleware/               # Auth, logging, recovery
│   └── metrics/                  # Prometheus metrics
├── templates/
│   ├── layouts/                  # Base templates
│   ├── components/               # Reusable UI components
│   ├── pages/                    # Full page templates
│   └── partials/                 # htmx partial responses
├── static/
│   ├── css/                      # Tailwind output
│   └── js/                       # htmx + theme toggle
├── go.mod
├── Makefile
├── config.example.yaml
└── README.md
```

## Configuration (YAML)

```yaml
server:
  host: "127.0.0.1"
  port: 8080

auth:
  local:
    enabled: true
    users:
      - username: admin
        password_hash: "$2a$12$..."
        role: admin
  oidc:
    enabled: false
    issuer: "https://auth.internal/oauth2/openid/sentinel"

services:
  systemd:
    - name: kea-dhcp4-server
      display_name: "Kea DHCP4"
      can_restart: true
    # ... more services

collectors:
  kea:
    control_socket: "/run/kea/kea-dhcp4-ctrl.sock"
  adguard:
    api_url: "http://127.0.0.1:3003"
  network:
    interfaces: [wan0, lan0, lab0, lab1, tailscale0]

diagnostics:
  allowed_targets:
    - "*.internal"
    - "10.0.0.0/8"

metrics:
  enabled: true
  path: "/metrics"
```

## Security Model

### Privilege Requirements
Sentinel runs as dedicated `sentinel` user with:
- `CAP_NET_ADMIN` - conntrack, network diagnostics
- `CAP_NET_RAW` - ping, traceroute
- Groups: `systemd-journal` (logs), `kea` (leases)

### Network Security
- Bind to localhost only (nginx reverse proxy for TLS)
- CSRF protection on all POST requests
- Rate limiting on login (10 attempts/minute)
- Session cookies: secure, httponly, samesite=strict

## NixOS Integration

### Package
Add to `nixos/pkgs/sentinel/default.nix` using `buildGoModule`.

### Module
Create `nixos/modules/nixos/services/sentinel.nix`:
- Declarative configuration via `services.sentinel.settings`
- systemd service with security hardening
- Automatic nginx virtualhost at `sentinel.internal`
- SOPS integration for secrets

### Deployment on routy
```nix
# nixos/hosts/routy/sentinel.nix
services.sentinel = {
  enable = true;
  settings = {
    # ... configuration
  };
};
```

## Implementation Phases

### Phase 1: Foundation
- [ ] Initialize Go project with module structure
- [ ] Set up Templ + htmx + Tailwind build pipeline
- [ ] Implement YAML configuration loading
- [ ] Implement local authentication (bcrypt + sessions)
- [ ] Create base UI layout with dark/light mode
- [ ] Create login page

### Phase 2: Service Monitoring
- [ ] Implement systemd D-Bus integration
- [ ] Implement Docker API integration (Omada)
- [ ] Create dashboard page with service cards
- [ ] Add service restart functionality
- [ ] Add journalctl log viewer
- [ ] Add network interface status

### Phase 3: Network Utilities
- [ ] Implement Kea lease file parser
- [ ] Create DHCP lease viewer page
- [ ] Implement network diagnostic tools (ping, traceroute, dig)
- [ ] Integrate AdGuard Home API
- [ ] Add DNS cache clear functionality

### Phase 4: Firewall & Connections
- [ ] Implement conntrack integration
- [ ] Create connection tracker page
- [ ] Implement nftables log parsing
- [ ] Create firewall log viewer
- [ ] Add real-time log streaming (SSE)

### Phase 5: Production Ready
- [ ] Add Prometheus metrics endpoint
- [ ] Implement Kanidm OIDC (optional)
- [ ] Create NixOS package
- [ ] Create NixOS module
- [ ] Deploy to routy
- [ ] Write documentation

## Verification Plan

### Local Development Testing
```bash
cd src/sentinel
make build
./sentinel -config config.example.yaml
# Access http://localhost:8080
```

### Integration Testing on routy
1. Build and deploy NixOS configuration
2. Verify nginx proxy at `https://sentinel.internal`
3. Test login with local credentials
4. Verify all services show correct status
5. Test service restart (non-critical service first)
6. Verify DHCP leases display correctly
7. Test network diagnostics
8. Verify Prometheus metrics at `/metrics`

### Metrics Verification
```bash
curl -s https://sentinel.internal/metrics | grep sentinel_
```

## Files to Create

1. `src/sentinel/go.mod` - Go module definition
2. `src/sentinel/cmd/sentinel/main.go` - Entry point
3. `src/sentinel/internal/config/config.go` - Configuration
4. `src/sentinel/internal/auth/local.go` - Local auth
5. `src/sentinel/internal/auth/session.go` - Session management
6. `src/sentinel/internal/service/systemd.go` - systemd integration
7. `src/sentinel/internal/handler/dashboard.go` - Dashboard handler
8. `src/sentinel/templates/layouts/base.templ` - Base layout
9. `src/sentinel/templates/pages/login.templ` - Login page
10. `src/sentinel/templates/pages/dashboard.templ` - Dashboard page
11. `src/sentinel/static/css/styles.css` - Tailwind styles
12. `src/sentinel/Makefile` - Build commands
13. `src/sentinel/config.example.yaml` - Example config
14. `nixos/pkgs/sentinel/default.nix` - Nix package
15. `nixos/modules/nixos/services/sentinel.nix` - NixOS module
16. `nixos/hosts/routy/sentinel.nix` - routy deployment

## Dependencies

```go
// go.mod
require (
    github.com/a-h/templ v0.2.x
    github.com/go-chi/chi/v5 v5.x
    github.com/coreos/go-systemd/v22 v22.x
    github.com/prometheus/client_golang v1.x
    github.com/alexedwards/scs/v2 v2.x
    github.com/rs/zerolog v1.x
    golang.org/x/crypto latest
    gopkg.in/yaml.v3 v3.x
    github.com/ti-mo/conntrack v0.x
    github.com/docker/docker v24.x
)
```

## Open Questions (Resolved)

| Question | Decision |
|----------|----------|
| Project name | **sentinel** |
| Auth approach | Local + optional OIDC |
| Control depth | Basic (view + restart + cache clear) |
| Tech stack | Go + htmx + Templ |
| Utilities | All four (diagnostics, DHCP, firewall, conntrack) |
| Metrics | Yes, Prometheus endpoint |

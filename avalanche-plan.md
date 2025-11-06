# Project Avalanche

> "Started with a snowflake, became an avalanche"

## History: The Snow-Themed Evolution

### The Beginning: snowflake
A friend's project that inspired the naming theme - a NixOS flake that started it all.

### Phase 1: snowy (The Laptop)
- **Created:** First NixOS flake experience
- **Purpose:** Personal laptop configuration (calypso - ASUS ROG Strix)
- **Architecture:** Simple, single-host flake
- **Features:**
  - Direct `nixosSystem` configuration
  - Inline unstable overlay
  - Hardware quirks from `nixos-hardware`
  - VSCode extensions integration
- **Location:** `/home/ndufour/Documents/code/projects/ops/snowy`

### Phase 2: snowpea (The Servers)
- **Created:** To manage home ARM-based SBCs
- **Name Origin:** "Pea" is small (like a Raspberry Pi 3, the first machines)
- **Purpose:** Fleet management for home infrastructure
- **Architecture:** Sophisticated multi-host flake
  - Custom `mkNixosConfig` helper function
  - Profile-based system (hardware + roles)
  - Reusable modules and overlays
- **Machines:** 15+ hosts
  - **Standalone servers:** eagle, mysecrets, possum, beacon, routy, cardinal
  - **K3s controllers:** opi01-03 (Orange Pi 5 Plus)
  - **K3s workers:** raccoon00-05 (Raspberry Pi 4)
- **Key Services on `mysecrets` (RPi 4, 8GB):**
  - step-ca (PKI/certificate authority)
  - Vaultwarden (password management)
  - Kanidm (identity management/SSO)
  - knot-dns (DNS)
- **Location:** `/home/ndufour/Documents/code/projects/ops/snowpea`

### Phase 3: home-ops (The Kubernetes Layer)
- **Purpose:** GitOps-managed Kubernetes cluster
- **Status:** Migrating from Flux to ArgoCD
- **Architecture:**
  - `base/` - Application definitions and Kustomize bases
  - `clusters/` - Cluster-specific configurations
  - Infrastructure components: cert-manager, networking, security, observability
- **Secrets:** SOPS with Age encryption, migrating to External Secrets Operator with Bitwarden
- **Location:** `/home/ndufour/Documents/code/projects/ops/home-ops`

### Phase 4: Cloud Infrastructure (Planned)
- **Purpose:** Hetzner Cloud and VPS management
- **Approach:** NixOS-first, Terraform where needed
- **Status:** Not yet created

## The Problem: Fragmentation

### Current Pain Points
1. **Context switching:** Constantly jumping between 3+ repositories
2. **Interdependencies:** Changes in NixOS machines impact K8s, and vice versa
3. **Shared secrets:** SOPS keys and secrets scattered across repos
4. **Mental overhead:** No single view of "the infrastructure"
5. **Historical accidents:** Repository boundaries were based on timeline, not architecture

### The Catalyst: IRC Bot DDOS Protection

**Problem:** marmithon IRC bot exposes home IP, vulnerable to DDOS attacks (has happened before)

**Initial thought:** Use gluetun VPN (similar to qbittorrent setup)

**Better solution discovered:** Tailscale exit nodes
- VPS acts as exit node
- IRC bot routes traffic through VPS
- Home IP never exposed to IRC network
- More reliable than commercial VPN
- No IP blocking issues from IRC networks

**This led to:** Identity and SSO considerations

## The Solution: Comprehensive Identity & Network Architecture

### Architecture Overview

```
┌────────────────────────────────────────────────────────┐
│ mysecrets (RPi 4, 8GB) - NixOS Infrastructure Services │
│  - step-ca (PKI)                                        │
│  - Vaultwarden (passwords)                              │
│  - Kanidm (✓ DEPLOYED - identity/SSO)                  │
└───────────────────┬────────────────────────────────────┘
                    │ OIDC
         ┌──────────┴──────────┐
         │                     │
    [Tailscale]           [K8s Services]
    (network auth)        (app SSO via
         │                oauth2-proxy)
         │
    ┌────┴─────────────────────────────┐
    │                                   │
[Your devices]              [K8s Cluster]
                                   │
                                   ├─ Tailscale Operator
                                   ├─ IRC Bot (marmithon)
                                   │  └─> routes via exit node
                                   └─ Other apps

[VPS - Cheap cloud server]
└─ Tailscale exit node
   (IRC sees this IP, not home IP)
```

### Components

#### 1. Tailscale Network Layer
- **Purpose:** Secure mesh network with exit node support
- **Initial Auth:** Gmail (pragmatic start)
- **Future Auth:** Kanidm OIDC (full self-hosted)
- **Exit Node:** VPS (~$5/month Hetzner/DigitalOcean)
- **Migration Path:** Gmail → Kanidm is supported by Tailscale

#### 2. Kanidm Identity Provider (✓ DEPLOYED)
- **Deployment:** NixOS on `mysecrets` Pi (alongside step-ca and Vaultwarden)
- **Access:** `https://auth.internal` (users: `username@auth.internal`)
- **Purpose:**
  - OIDC/OAuth2 provider for Tailscale
  - SSO for web applications
  - Multi-user support (you + wife)
- **Benefits:**
  - Single login for all services
  - Self-hosted identity
  - No chicken-and-egg problem (runs on separate Pi, not in K8s)
  - Lightweight (SQLite, no Redis/PostgreSQL complexity)
- **Documentation:** `docs/kanidm-user-management.md`

#### 3. Tailscale Kubernetes Operator
- **Deployment:** ArgoCD-managed in K8s cluster
- **Purpose:** Kubernetes-native Tailscale integration
- **Features:**
  - No manual sidecar configuration
  - Annotation-based routing
  - Exit node support for pods
- **Use Cases:**
  - IRC bot privacy/DDOS protection
  - Future services needing IP protection
  - Secure remote access

#### 4. Exit Node Strategy
- **Primary Use:** IRC bot (marmithon)
- **Implementation:** VPS running Tailscale as exit node
- **Configuration:** Pod annotation routes traffic through exit node
- **Benefits:**
  - Home IP never exposed
  - DDOS attacks hit VPS, not home
  - IRC networks don't block VPS IPs (unlike commercial VPNs)

### Why This Architecture Works

**Separation of Concerns:**
- Identity (Kanidm) runs on stable, separate hardware
- Network (Tailscale) can fail without breaking identity
- Applications (K8s) can restart without affecting auth

**Incremental Migration:**
- Start with Gmail → Tailscale (quick win)
- Deploy Kanidm when ready ✓
- Migrate Tailscale auth to Kanidm later
- Add service SSO gradually

**Self-Hosted with Pragmatism:**
- Keep Tailscale on Gmail if preferred (one cloud dependency)
- Or go full self-hosted with Kanidm
- Choice preserved, not locked in

## The Realization: Time to Consolidate

### Why Now?
- Added Kanidm ✓ (NixOS in avalanche)
- About to add Tailscale operator (K8s in home-ops)
- Cloud infrastructure coming (would be 4th repo!)
- Pain of context-switching finally outweighs migration effort

### The Vision: avalanche

**One unified repository for all infrastructure**

```
avalanche/
├── nixos/              # All NixOS configs (snowy + snowpea merged)
│   ├── hosts/
│   │   ├── calypso/        # Laptop (from snowy)
│   │   ├── mysecrets/      # Pi: step-ca, vaultwarden, kanidm ✓
│   │   ├── eagle/          # Pi: Forgejo
│   │   ├── possum/         # Pi: Garage S3, backups
│   │   ├── raccoon00-05/   # K8s workers (RPi 4)
│   │   ├── opi01-03/       # K8s controllers (Orange Pi 5+)
│   │   ├── beacon/         # x86 server
│   │   ├── routy/          # x86 server
│   │   └── cardinal/       # x86 server
│   ├── profiles/
│   │   ├── global.nix
│   │   ├── hw-*.nix        # Hardware profiles
│   │   ├── role-*.nix      # Role profiles
│   │   └── role-workstation.nix  # NEW: for laptop
│   ├── modules/nixos/
│   └── lib/
├── kubernetes/         # K8s GitOps (from home-ops)
│   ├── base/
│   │   ├── apps/
│   │   ├── infra/
│   │   │   └── tailscale/  # NEW: Tailscale operator
│   │   └── components/
│   ├── clusters/
│   │   └── main/
│   └── docs/
├── cloud/             # Hetzner/VPS infrastructure
│   ├── nixos/         # NixOS-based VPS configs
│   └── terraform/     # Where NixOS isn't suitable
├── secrets/           # Unified SOPS secrets
│   ├── nixos/
│   ├── kubernetes/
│   └── cloud/
├── docs/
│   └── migration/     # Document the consolidation process
├── .sops.yaml         # Unified SOPS configuration
├── flake.nix          # NixOS flake (all machines)
├── flake.lock
├── justfile           # Unified task runner
└── README.md          # The story: snowflake → avalanche
```

### Benefits of Consolidation

**Operational:**
- Single `git clone` for entire infrastructure
- One SOPS configuration, one Age key
- Cross-repository changes in single PR
- Unified CI/CD pipeline
- One git history showing system evolution

**Mental Model:**
- One place to look for everything
- Clear understanding of dependencies
- Easier onboarding (for future you, or collaborators)

**Technical:**
- Share NixOS modules across all machines
- Consistent profiles and patterns
- Easier to maintain standards

## Implementation Phases

### Phase 1: Foundation (Priority)
1. **Create `avalanche` repository**
   - Start fresh (keep old repos as archives)
   - Set up flake structure
   - Configure unified SOPS

2. **Merge NixOS configurations**
   - Migrate snowpea servers (15+ hosts)
   - Migrate snowy laptop (calypso)
   - Unify profiles and modules
   - Adapt laptop to use profile system

3. **Migrate Kubernetes**
   - Move home-ops content
   - Preserve ArgoCD structure
   - Update paths and references

### Phase 2: Identity & Network (In Progress)
1. **✓ Deploy Kanidm** (Changed from Authentik - official NixOS support)
   - ✓ Add to `mysecrets` NixOS config
   - ✓ Configure with step-ca TLS certificates
   - ✓ Set up at `https://auth.internal`
   - ✓ Create initial users
   - ✓ Document user management procedures
   - TODO: Set up initial OAuth2 clients

2. **Set up Tailscale**
   - Create tailnet (Gmail auth initially)
   - Provision VPS as exit node
   - Add wife as user

3. **Deploy Tailscale Operator**
   - Add to `kubernetes/base/infra/tailscale/`
   - Create ArgoCD application
   - Configure OAuth secrets via ExternalSecrets

4. **Protect IRC Bot**
   - Annotate marmithon deployment
   - Configure exit node routing
   - Test DDOS protection

### Phase 3: Identity Migration (Optional)
1. **Migrate Tailscale to Kanidm**
   - Configure Kanidm as OIDC provider
   - Contact Tailscale support for migration
   - Update user authentication

2. **Service SSO**
   - Deploy oauth2-proxy or similar
   - Integrate Home Assistant
   - Add other services gradually

### Phase 4: Cloud Infrastructure
1. **VPS Management**
   - NixOS configurations for cloud VMs
   - Exit node formalized
   - Other cloud services as needed

2. **Terraform (where needed)**
   - Resource provisioning
   - Infrastructure that doesn't fit NixOS model

## Design Decisions

### Flake Structure
- **Adopt snowpea's `mkNixosConfig` pattern** for all machines
- Laptop becomes just another host with `role-workstation.nix`
- Consistent approach across all NixOS hosts

### Secrets Management
- **Continue SOPS with Age** for NixOS secrets
- **External Secrets Operator** for K8s (already in progress)
- Unified `.sops.yaml` at repository root

### Deployment
- **NixOS:** `just nix-deploy <hostname>` (from snowpea pattern)
- **Kubernetes:** ArgoCD automatic sync
- **Cloud:** Mix of NixOS deployments and Terraform

### Repository Retention
- Keep `snowy`, `snowpea`, and `home-ops` as read-only archives
- Reference in avalanche README
- Preserve git history for reference

## Open Questions

### Multi-User SSO Details
- Which services need SSO first?
- Guest access requirements?
- Per-service authorization vs simple authentication?

### Cloud Infrastructure Scope
- What will run in Hetzner Cloud?
- Exit node only, or more services?
- Cost/benefit of cloud vs home resources?

### Monorepo Concerns
- How to handle large repo size over time?
- CI/CD performance with everything in one place?
- Blast radius management (one mistake affects everything)?

## Next Steps

Current status: Phase 2 (Identity & Network) in progress

1. **✓ Repository consolidation** (Phase 1 Complete)
   - ✓ Created `avalanche` repository
   - ✓ Merged NixOS configs
   - ✓ Working unified infrastructure

2. **Identity & network implementation** (Phase 2 In Progress)
   - ✓ Deployed Kanidm on `mysecrets` at `https://auth.internal`
   - ✓ Created user management documentation
   - ✓ Set up Tailscale network (routy, calypso, mysecrets connected)
   - ✓ Provisioned Hetzner VPS as Tailscale exit node
   - ✓ Created automation scripts for VPS management (provision/deprovision/update-ip)
   - ✓ SOPS-encrypted secrets for Tailscale auth key
   - ✓ Firewall protecting VPS (SSH from home IP only)
   - ✓ Tested exit node functionality
   - TODO: Deploy Tailscale operator in K8s

3. **IRC bot protection** (Phase 2 Remaining)
   - Deploy Tailscale Kubernetes operator
   - Configure marmithon to use exit node
   - Test and validate DDOS protection

## Resources & References

### Project Locations (Current)
- **snowy:** `/home/ndufour/Documents/code/projects/ops/snowy`
- **snowpea:** `/home/ndufour/Documents/code/projects/ops/snowpea`
- **home-ops:** `/home/ndufour/Documents/code/projects/ops/home-ops`

### Key Technologies
- **NixOS:** Declarative system configuration
- **SOPS:** Secrets management with Age encryption
- **Tailscale:** Mesh VPN with exit node support
- **Kanidm:** Self-hosted identity provider (Rust-based, lightweight)
- **ArgoCD:** GitOps for Kubernetes
- **K3s:** Lightweight Kubernetes

### Documentation
- Tailscale Kubernetes Operator: https://tailscale.com/kb/1236/kubernetes-operator
- Tailscale SSO Providers: https://tailscale.com/kb/1013/sso-providers
- Tailscale Exit Nodes: https://tailscale.com/kb/1103/exit-nodes
- Kanidm Documentation: https://kanidm.github.io/kanidm/stable/
- Kanidm User Management: `docs/kanidm-user-management.md`
- VPS Management Scripts: `cloud/scripts/README.md`

### VPS Management (Hetzner Cloud)
- **Location:** `cloud/scripts/`
- **Scripts:**
  - `provision-exit-node.sh` - Create VPS with Tailscale exit node
  - `deprovision-exit-node.sh` - Destroy VPS and firewall
  - `update-home-ip.sh` - Update firewall when home IP changes
- **Server Type:** CPX11 (€3.85/month, 2 vCPU, 2GB RAM)
- **Secrets:** `secrets/cloud/secrets.sops.yaml` (SOPS-encrypted Tailscale auth key)

## The Story

What started as a snowflake (a friend's NixOS flake) became snowy (a personal laptop config), grew into snowpea (a fleet of tiny servers), expanded to home-ops (a Kubernetes cluster), and is now becoming an avalanche - an unstoppable, unified infrastructure that encompasses everything from laptops to servers to cloud resources.

The fragmentation that came from organic growth is being consolidated into a single, cohesive system. The infrastructure that started small now has momentum, scale, and comprehensive identity and network security.

**avalanche** - because infrastructure that starts with a single snowflake doesn't stay small for long.

---

*Document created: 2025-11-01*
*Last updated: 2025-11-06 - Tailscale exit node provisioned on Hetzner VPS*

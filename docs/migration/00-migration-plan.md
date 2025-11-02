# Avalanche Migration Plan

This document tracks the migration from separate repositories (snowy, snowpea, home-ops) into the unified avalanche monorepo.

## Migration Date

Started: 2025-11-02

## Source Repositories

- **snowy**: `/home/ndufour/Documents/code/projects/ops/snowy` (laptop config)
- **snowpea**: `/home/ndufour/Documents/code/projects/ops/snowpea` (server fleet)
- **home-ops**: `/home/ndufour/Documents/code/projects/ops/home-ops` (Kubernetes)

## Phase 1: Foundation

### Objectives
1. Create repository structure
2. Set up flake.nix for all NixOS hosts
3. Configure unified SOPS
4. Migrate NixOS configurations
5. Migrate Kubernetes manifests

### Progress

#### Step 1: Repository Structure ✅
**Date:** 2025-11-02

Created directory structure:
```
avalanche/
├── nixos/
│   ├── hosts/
│   ├── profiles/
│   ├── modules/nixos/
│   └── lib/
├── kubernetes/
│   ├── base/{apps,infra,components}
│   ├── clusters/main/
│   └── docs/
├── cloud/
│   ├── nixos/
│   └── terraform/
├── secrets/
│   ├── nixos/
│   ├── kubernetes/
│   └── cloud/
└── docs/migration/
```

Actions taken:
- Initialized git repository
- Created README.md with project overview
- Created .gitignore for Nix/secrets
- Created migration documentation structure

#### Step 2: Flake Structure (In Progress)
**Date:** 2025-11-02

Next steps:
- Analyze snowpea's `mkNixosConfig` pattern
- Create flake.nix with inputs
- Set up lib/ helper functions
- Prepare for host migrations

#### Step 3: SOPS Configuration (Pending)

#### Step 4: NixOS Migration (Pending)

#### Step 5: Kubernetes Migration (Pending)

## Migration Strategy

### NixOS Approach
- Adopt snowpea's profile-based system for all hosts
- Laptop (calypso) becomes `role-workstation.nix`
- All hosts use `mkNixosConfig` pattern
- Merge and deduplicate modules

### Secrets Strategy
- Unified `.sops.yaml` at repo root
- Separate Age keys for nixos/kubernetes/cloud
- Maintain existing encryption where possible

### Testing Strategy
- Build configurations without deploying first
- Deploy to non-critical hosts for validation
- Keep old repos available during transition
- Document any breaking changes

## Risk Mitigation

### Rollback Plan
- Old repositories remain untouched during migration
- Can revert to old configs if issues arise
- Test builds before actual deployments

### Communication
- Document all breaking changes
- Keep change log of modifications
- Note any manual steps required

## Post-Migration Tasks

- [ ] Update bookmarks/scripts pointing to old repos
- [ ] Archive old repositories (mark as read-only)
- [ ] Update deployment automation
- [ ] Verify all secrets are accessible
- [ ] Confirm all hosts can build successfully

## Notes & Decisions

### Design Decisions
- **Monorepo structure**: Benefits outweigh complexity for this use case
- **Profile-based NixOS**: Consistent pattern across all machines
- **ArgoCD**: Keep existing K8s deployment strategy
- **SOPS**: Continue with Age, unify configuration

### Open Questions
- [ ] Should we preserve git history from old repos?
- [ ] How to handle ongoing changes during migration?
- [ ] Test infrastructure for validation?

---

*Last updated: 2025-11-02*

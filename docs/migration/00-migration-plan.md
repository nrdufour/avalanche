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

#### Step 2: Flake Structure ✅
**Date:** 2025-11-02

Actions completed:
- Created flake.nix with all inputs from snowpea + snowy
- Implemented mkNixosConfig pattern from snowpea
- Set up lib/ and overlays/ structure
- Added all 14 active snowpea hosts to flake

See: docs/migration/01-nixos-base-migration.md

#### Step 3: SOPS Configuration ✅
**Date:** 2025-11-02

Actions completed:
- Copied .sops.yaml from snowpea with all Age keys
- Copied secrets/ directory structure
- Fixed .gitignore to allow .sops.yaml files
- Added workstation-calypso Age key
- All secrets properly encrypted and accessible

See: docs/migration/01-nixos-base-migration.md

#### Step 4: Snowy Integration ✅
**Date:** 2025-11-02

Actions completed:
- Created role-workstation.nix profile importing core personalities
- Copied calypso host configuration from snowy
- Migrated complete personalities/ structure (base, laptop, development, ham, chat, backups, knowledge)
- Integrated with mkNixosConfig pattern using nixos-hardware
- Resolved configuration conflicts using lib.mkDefault
- All 15 hosts (14 servers + 1 workstation) pass validation

See: docs/migration/03-snowy-workstation-migration.md

#### Step 5: Kubernetes Migration ✅
**Date:** 2025-11-02

Actions completed:
- Copied complete home-ops structure to kubernetes/
- Merged justfiles with proper k8s- prefix
- Updated all ArgoCD Application paths (kubernetes/base/, kubernetes/clusters/)
- Updated all ArgoCD Application repoURLs (home-ops.git → avalanche.git)
- Updated Flux GitRepository URL (home-ops.git → avalanche.git)
- Updated all Flux Kustomization paths (./kubernetes/kubernetes/main/)
- Merged Kubernetes tools into default.nix
- Created Forgejo workflow for automated flake.lock updates

See: docs/migration/04-kubernetes-migration.md

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

- [x] Update deployment automation (justfile with k8s- commands)
- [x] Verify all secrets are accessible (SOPS configured)
- [x] Confirm all hosts can build successfully (15 hosts pass validation)
- [x] Created Forgejo workflow for automated flake updates
- [ ] Update bookmarks/scripts pointing to old repos
- [ ] Archive old repositories (mark as read-only)
- [ ] Test Kubernetes deployments with new paths
- [ ] Migrate remaining Flux manifests to ArgoCD

## Notes & Decisions

### Design Decisions
- **Monorepo structure**: Benefits outweigh complexity for this use case
- **Profile-based NixOS**: Consistent pattern across all machines
- **ArgoCD**: Keep existing K8s deployment strategy
- **SOPS**: Continue with Age, unify configuration

### Open Questions
- [x] Should we preserve git history from old repos? **Decision: Fresh start, old repos archived**
- [x] How to handle ongoing changes during migration? **Decision: Disable workflows in old repos once stable**
- [x] Test infrastructure for validation? **Decision: nix flake check + manual deployments**

## Migration Status Summary

**Phase 1: Foundation** ✅ COMPLETE

All three source repositories successfully migrated into avalanche:
- **snowpea** (14 server hosts) → `nixos/` ✅
- **snowy** (1 workstation) → `nixos/personalities/` + `calypso` ✅
- **home-ops** (Kubernetes) → `kubernetes/` ✅

Total: 15 NixOS hosts + complete Kubernetes GitOps infrastructure

---

*Last updated: 2025-11-02*

# NixOS Autoupgrade Schedule

Each NixOS host runs `nixos-upgrade.timer` nightly to pull the latest `flake.lock` from `forge.internal/nemo/avalanche` and rebuild. Times are staggered into tiers so the flake source (hawk) and gateway (routy) settle before the bulk of the fleet starts pulling, and so storage hosts upgrade before the noisy worker tier.

## Cascade

| Time   | Host(s)                                     | Jitter   | Role                                    |
|--------|---------------------------------------------|----------|-----------------------------------------|
| 00:00  | (CI) `bump-flake` workflow                  | —        | pushes new `flake.lock` to forge        |
| 01:30  | hawk                                        | —        | flake source (forge.internal)           |
| 02:00  | routy                                       | —        | gateway (DNS, DHCP, AdGuardHome, Kea)   |
| 02:30  | cardinal, possum                            | —        | storage / x86 servers                   |
| 02:30  | muninn                                      | +0–10min | hermes-agent host                       |
| 03:00  | opi01-03, raccoon00-05                      | +0–30min | k3s controllers + workers               |

Plus, after the upgrade window:

| Time  | Job                                           | Notes                                    |
|-------|-----------------------------------------------|------------------------------------------|
| 04:00 | `influxdb2-backup` CronJob (Kubernetes)       | runs after the fleet has settled         |

## Why this ordering

1. **Bump first** — the `bump-flake.yaml` Forgejo workflow updates `flake.lock` at 00:00 (04:00 UTC) so every host pulls a fresh lock during its slot.
2. **hawk first (01:30)** — hawk hosts `forge.internal`. Upgrading it earliest means the rest of the fleet pulls the flake from a settled instance during their own slots.
3. **routy second (02:00)** — routy is the gateway and DNS resolver. Its reboot causes a brief network blip; running it before everything else means the blip happens while the rest of the fleet is idle, not while they're mid-`nix-rebuild`.
4. **Storage tier (02:30)** — cardinal and possum are stateful (Garage, Minio, NFS, ZFS, restic targets). They upgrade before the workers so any storage hiccup is over before workloads on the k3s fleet might notice.
5. **muninn at 02:30 + 10min jitter** — rides with the storage tier but with a small jitter so its reboot doesn't perfectly overlap with theirs.
6. **k3s fleet at 03:00 + 30min jitter** — the bulk of the fleet (3 controllers + 6 workers) spreads across a 30-minute window via `system.autoUpgrade.randomizedDelaySec`. This avoids the thundering-herd DNS failure observed on 2026-04-22.

## Where it's configured

- Per-host `dates` and (where relevant) `randomizedDelaySec`: `nixos/hosts/<host>/default.nix` for hawk, routy, cardinal, possum, muninn, beacon.
- Fleet jitter for the k3s tier: `nixos/profiles/role-k3s-worker.nix` and `nixos/profiles/role-k3s-controller.nix` (each sets `system.autoUpgrade.randomizedDelaySec = "30min"`).
- Globally, `nix.settings.connect-timeout = 30` in `nixos/profiles/global/nix.nix` — bumped from 5s after the 2026-04-22 incident so transient DNS blips during the upgrade window don't fail the github.com flake fetches.
- The Kubernetes InfluxDB backup CronJob: `kubernetes/base/apps/home-automation/influxdb2/backup-cronjob.yaml`.

## Background

This layout replaces a single 03:00 slot for all 14 hosts (no jitter). On 2026-04-22, three raccoons failed `nixos-upgrade.service` with `Resolving timed out after 5000 milliseconds` while routy was rebooting and could not serve DNS. See `project_nixos_upgrade_stagger.md` (memory) for the full incident write-up. Still TODO from that plan: optionally mirror small flake inputs (sops-nix, etc.) on `forge.internal/Mirrors/` the way `nixpkgs` already is.

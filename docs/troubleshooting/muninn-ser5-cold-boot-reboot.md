# Beelink SER5 Cold-Boot Reboot Loop at Early Stage 2

## Incident: 2026-04-18

### Summary

During initial NixOS bring-up of `muninn` (a Beelink SER5, AMD Ryzen 5), every
attempt to boot the flake-built generation ended in a hard hardware reset
within ~1 second of stage 2 starting. The user sees 4–5 lines of systemd
output on the console, then the machine instantly resets and re-enters the
systemd-boot menu. No kernel panic, no MCE, no log entries on disk — the
reset happens before `systemd-journald` can flush anything to persistent
storage, so the crashed boots do not appear in `journalctl --list-boots` at
all.

The vanilla `/etc/nixos/configuration.nix` install (without our flake) booted
fine. The flake-built generation booted fine via **live** `switch-to-configuration`
(kernel stays running, only userspace swaps), but failed on every cold boot
or reboot.

### Root Cause

Beelink SER5 hardware has a documented power-delivery issue where rapid CPU
core state transitions under the `amd-pstate-epp` driver cause instant
hardware resets. This is the same root cause as
[`hawk-qemu-arm64-reboots.md`](./hawk-qemu-arm64-reboots.md), but with a
different trigger:

- **hawk**: triggered only under heavy load (QEMU ARM64 emulation).
- **muninn**: triggered at cold-boot during early stage 2, presumably because
  systemd spins up many services in parallel, pushing the CPU into rapid
  boost transitions before userspace can tame it.

The difference is likely due to BIOS/firmware baseline differences between
the two machines — hawk has been through BIOS updates over time; muninn
came out of the box with a different UEFI and behaves more aggressively at
boot.

### Why the Existing hawk Fix Wasn't Enough

The hawk fix writes `0` to `/sys/devices/system/cpu/cpufreq/boost` via
`systemd.tmpfiles.rules`:

```nix
systemd.tmpfiles.rules = [
  "w /sys/devices/system/cpu/cpufreq/boost - - - - 0"
];
```

This runs via `systemd-tmpfiles-setup.service` early in stage 2 — but **not
early enough** for muninn. By the time tmpfiles fires, the parallel service
activation has already driven the CPU into a boost transition that the
hardware can't handle, and the machine resets.

Additionally, the `amd-pstate-epp` driver ignores the common
`amd_pstate.no_boost=1` kernel parameter, so that doesn't help either.

### The Fix

Switch the AMD P-state driver to **passive mode** via kernel command line:

```nix
boot.kernelParams = [ "amd_pstate=passive" ];
```

In passive mode, the boost control becomes effective at kernel init time —
before any userspace runs. Combined with the existing tmpfiles rule
(belt-and-suspenders for the running system), the machine boots reliably.

Full NixOS config fragment (in `nixos/hosts/muninn/default.nix`):

```nix
boot.kernelParams = [ "amd_pstate=passive" ];
systemd.tmpfiles.rules = [
  "w /sys/devices/system/cpu/cpufreq/boost - - - - 0"
];
```

### Verification

After deploying generation 7 with the kernel param:

- **Three consecutive reboots** all booted cleanly, including a full
  power-cycle (RAM/firmware state fully cleared).
- `/proc/cmdline` confirms `amd_pstate=passive` is present.
- `/sys/devices/system/cpu/amd_pstate/status` reads `passive`.
- `/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver` reads `amd-pstate`.
- `/sys/devices/system/cpu/cpufreq/boost` reads `0`.
- `systemctl is-system-running` reports `running`.

### Why Generations Appeared as "Clean Shutdowns" in the Journal

A curious-looking detail in diagnosis: every boot visible in `journalctl
--list-boots` ended with a clean `systemd-shutdown` sequence, including
short boots from what the user described as failed ones. This is because
journald can only persist entries that were actually written to disk
during that boot. When the hardware resets within ~1 second of stage 2
starting, journald never gets to flush anything — so the crashed boot
leaves **no trace at all**. What the journal shows as "the previous boot"
is actually the next generation systemd-boot fell through to, which
booted fine and was later rebooted cleanly by the user.

If future diagnosis hits this class of issue and the journal looks "clean"
on every prior boot, consider that the crashed boot may have left no record
at all.

### Related

- [`hawk-qemu-arm64-reboots.md`](./hawk-qemu-arm64-reboots.md) — same hardware
  quirk, different trigger (runtime QEMU load vs cold-boot).
- Beelink community reports:
  [SER5 Max crashes](https://bbs.bee-link.com/d/9082-ser5-max-6800u-crashes),
  [crash under load](https://bbs.bee-link.com/d/8466-pc-crash-while-under-load-ser5-max-6800u-32gb-1tb).

### Open Question: Should hawk Adopt the Kernel Param Too?

hawk is the same hardware family and has no crashes today, but its fix
relies solely on the tmpfiles rule. If hawk's BIOS behavior ever drifts
(e.g., after a future BIOS update), it could become vulnerable to the
same cold-boot crash. Adopting `amd_pstate=passive` on hawk as defensive
hygiene is low-effort and wouldn't change behavior in any observable way
— the tmpfiles rule would still enforce boost=0 the same way. Not urgent,
but worth considering next time hawk is being touched.

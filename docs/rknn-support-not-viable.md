# RKNN NPU Support - Not Viable

## Summary

RKNPU (Rockchip Neural Processing Unit) kernel driver support cannot be implemented with current constraints.

## Technical Blocker

**Linux kernel 6.17 (current in nixpkgs 25.05) does NOT contain RKNPU kernel driver support.**

Investigation of official kernel source (https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git):
- v6.17: No RKNPU driver, no accelerator framework support for Rockchip
- RKNPU driver was only submitted to mainline in June 2024 for kernel 6.18+
- Kernel 6.18 has not been released yet

## Why Each Option Is Not Viable

### Option 1: Standard nixpkgs Kernel
- ❌ linux_6_17 lacks RKNPU config options entirely
- ❌ No `CONFIG_ROCKCHIP_RKNPU` exists in 6.17 source
- ❌ Kernel 6.18+ with RKNPU support not yet available in nixpkgs

### Option 2: Vendor Kernel
- ❌ Explicitly rejected due to maintenance concerns
- Would be the only currently viable path but conflicts with project requirements

### Option 3: Out-of-Tree Module
- ❌ Complex and impractical
- Kernel version mismatches likely
- Not a recommended approach for embedded systems

## Conclusion

RKNN NPU support is not feasible with current constraints (standard nixpkgs kernel + no vendor kernel).

Viable paths would require:
1. Kernel 6.18+ in nixpkgs (future)
2. Accepting vendor kernel trade-offs (rejected)
3. Waiting for mainline kernel maturation

## References

- Kernel commit analysis: https://blog.tomeuvizoso.net/2024/06/rockchip-npu-update-4-kernel-driver-for.html
- Investigation date: 2025-11-15

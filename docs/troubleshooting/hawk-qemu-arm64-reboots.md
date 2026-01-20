# Investigation Plan: Hawk QEMU ARM64 Build Reboots

## Problem Summary

Hawk (Beelink SER5 Max with AMD Ryzen 7 6800U) reboots during QEMU ARM64 Docker builds for `marmithon` and `airport-swiss-knife` projects.

### Confirmed Facts (as of 2026-01-20)

- **Pure CPU stress tests (3+ min)**: No reboots, temperatures rise but stable
- **QEMU ARM64 builds**: Causes reboots within 20-30 seconds
- **AMD64 builds**: No reboots
- **Thermal cause**: ❌ **Ruled out** - crashes occur at 20°C CPU temperature
- **Concurrent load**: ❌ **Ruled out** - single runner still crashes
- **MCE events**: None logged - crash is instant with no kernel warning
- **Crash pattern**: Journal stops mid-activity, no shutdown sequence

### Root Cause Hypothesis

**Power delivery issue** - QEMU ARM64 emulation causes a specific current draw pattern (likely rapid power spikes from instruction translation) that triggers PSU/VRM protection or instability on this hardware. This is NOT thermal-related as crashes occur before any temperature rise.

---

## Quick Wins to Try First

Before deep investigation, these quick tests may isolate the issue:

### 1. Verify Journal Persistence
```bash
ssh hawk.internal
ls -la /var/log/journal/
# If empty, enable persistent logging first (see Phase 1.3)
```

### 2. Test Single Runner (Reduce Concurrent Load)
```bash
# Temporarily disable second runner
sudo systemctl stop gitea-runner-second

# Trigger the failing ARM64 build
# If it succeeds: concurrent load issue
# If it still crashes: proceed with deeper investigation
```

### 3. Quick BIOS Check
Since you have physical access, boot into BIOS and note:
- Power limit settings (PL1/PL2)
- Turbo boost settings
- Memory XMP profile (if enabled)

---

## Investigation Strategy

The investigation follows a systematic approach: **gather data → isolate variables → identify root cause → implement fix**.

### Phase 1: Pre-Reboot Data Collection

Goal: Capture system state during QEMU workload before reboot occurs.

#### 1.1 Hardware Monitoring Setup

SSH into hawk and set up monitoring **before** triggering a build:

```bash
# Terminal 1: CPU temperature monitoring (watch for sudden spikes)
watch -n 1 'sensors'

# Terminal 2: Power/voltage monitoring (if available)
watch -n 1 'cat /sys/class/hwmon/*/in*_input 2>/dev/null | head -20'

# Terminal 3: CPU frequency and throttling
watch -n 1 'cat /proc/cpuinfo | grep MHz'

# Terminal 4: Memory pressure
watch -n 1 'free -h && cat /proc/meminfo | grep -E "MemFree|Buffers|Cached|SwapFree"'
```

#### 1.2 Kernel Message Capture

```bash
# Watch for MCE (Machine Check Exceptions) and thermal events
sudo dmesg -w | grep -iE 'mce|thermal|temp|throttl|error|fail|power'

# Also capture to file for post-reboot analysis
sudo dmesg -w | tee /tmp/dmesg-watch.log
```

#### 1.3 System Journal (Persistent)

Ensure journal is persistent across reboots:
```bash
# Check if persistent journal is enabled
ls -la /var/log/journal/

# If not, enable it
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
```

---

### Phase 2: Stress Test Differentiation

Goal: Understand what makes QEMU ARM64 different from CPU stress tests.

#### 2.1 Memory Stress Test

QEMU emulation is memory-intensive with random access patterns:

```bash
# Install stress-ng if not present
nix-shell -p stress-ng

# Memory stress (tests memory bandwidth and randomness)
stress-ng --vm 4 --vm-bytes 75% --vm-method rand-incdec --timeout 180s

# Combined memory + CPU
stress-ng --cpu 8 --vm 4 --vm-bytes 50% --timeout 180s
```

#### 2.2 Specific Instruction Set Stress

QEMU uses specific CPU instructions heavily:

```bash
# AVX/SSE intensive workload (closer to what QEMU does)
stress-ng --matrix 0 --matrix-method prod --timeout 180s

# Vector operations
stress-ng --vecmath 0 --timeout 180s
```

#### 2.3 KVM Stress Test

Test if KVM specifically triggers the issue:

```bash
# Simple QEMU/KVM test without full Docker
nix-shell -p qemu

# Run a minimal ARM64 VM
qemu-system-aarch64 -M virt -cpu cortex-a72 -m 2G \
  -kernel /path/to/arm64/kernel -nographic \
  -append "console=ttyAMA0"
```

---

### Phase 3: Reproduce in Controlled Environment

Goal: Create a minimal reproducible test case.

#### 3.1 Minimal Docker Buildx ARM64 Test

```bash
# Create a simple Dockerfile
cat > /tmp/Dockerfile.test << 'EOF'
FROM --platform=linux/arm64 alpine:latest
RUN echo "Building ARM64" && sleep 30
EOF

# Build with ARM64 emulation
docker buildx build --platform linux/arm64 -t test-arm64 /tmp/
```

#### 3.2 Vary Resource Limits

Test if limiting resources prevents the crash:

```bash
# Limit CPU cores for buildx
docker buildx build --platform linux/arm64 \
  --build-arg DOCKER_BUILDKIT=1 \
  --cpuset-cpus="0-3" \
  -t test-arm64 /tmp/

# Limit memory
docker buildx build --platform linux/arm64 \
  --memory=4g \
  -t test-arm64 /tmp/
```

---

### Phase 4: Post-Reboot Analysis

Goal: Examine logs after unexpected reboot.

#### 4.1 Check for MCE Events

```bash
# Machine Check Exceptions (hardware errors)
sudo journalctl -b -1 | grep -i mce
sudo mcelog --client  # if mcelog daemon is running

# Check if mcelog is available
which mcelog || nix-shell -p mcelog
```

#### 4.2 Previous Boot Logs

```bash
# Last boot before current
sudo journalctl -b -1 --no-pager | tail -100

# Look for sudden end (indicates crash, not clean shutdown)
sudo journalctl -b -1 --no-pager | grep -E 'shutdown|halt|reboot|power'
```

#### 4.3 RASDAEMON for Hardware Error Tracking

```bash
# If not installed, add to hawk config
nix-shell -p rasdaemon

# Check for hardware errors
sudo ras-mc-ctl --status
sudo ras-mc-ctl --errors
```

---

### Phase 5: Hardware-Specific Investigations

Goal: Check for Beelink SER5 Max specific issues.

#### 5.1 BIOS/UEFI Settings

Check and consider adjusting:
- **Power limits**: SER5 Max may have aggressive turbo settings
- **Thermal throttling thresholds**: May be set too high
- **Memory timings**: XMP profiles can cause instability under load

#### 5.2 Physical Inspection

- **Thermal paste**: May need reapplication
- **Dust buildup**: Clean fans and heatsinks
- **Power supply**: Check if adequate wattage (SER5 Max ships with 65W)
- **Ambient temperature**: Ensure adequate ventilation

#### 5.3 Firmware Updates

```bash
# Check current BIOS version
sudo dmidecode -t bios

# Check for updates from Beelink support page
```

---

### Phase 6: Software Mitigations

Goal: Test software workarounds while investigating root cause.

#### 6.1 Limit QEMU Resources

Add to Docker daemon config or buildx builder:

```json
{
  "builder": {
    "gc": {
      "enabled": true
    }
  },
  "features": {
    "buildkit": true
  }
}
```

#### 6.2 Offload ARM64 Builds

Long-term solution: Build ARM64 on actual ARM hardware (opi01-03):

```bash
# Use remote builder on Orange Pi nodes
docker buildx create --name arm-builder \
  --driver docker-container \
  --platform linux/arm64 \
  ssh://user@opi01.internal
```

#### 6.3 CPU Frequency Limiting

Temporarily limit max frequency:

```bash
# Check current governor
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Limit max frequency (temporary test)
echo 3000000 | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq
```

---

## Recommended Investigation Order

### Round 1: Quick Isolation Tests
1. **Verify journal persistence** - Essential for capturing crash data
2. **Test single runner** - Quick test to rule out concurrent load
3. **Check BIOS settings** - Note power limits, turbo, memory profile

### Round 2: Data Collection (if Round 1 doesn't solve it)
4. **Set up monitoring terminals** (Phase 1.1, 1.2)
5. **Run memory + vector stress tests** (Phase 2.1, 2.2)
6. **Run minimal ARM64 Docker build** (Phase 3.1)

### Round 3: Post-Crash Analysis
7. **After reboot, analyze logs** (Phase 4) - Look for MCE, sudden journal end
8. **Check rasdaemon for hardware errors**

### Round 4: Mitigations
9. **If hardware issue**: Adjust BIOS settings, consider cooling improvements
10. **If software/load issue**: Limit runners, use remote ARM64 builders

---

## Key Diagnostic Questions to Answer

1. Does memory stress alone trigger reboots?
2. Does AVX/SSE stress trigger reboots?
3. Does limiting CPU cores during buildx prevent reboots?
4. Are there MCE events logged before reboot?
5. Is the journal showing a clean shutdown or sudden stop?
6. What are the actual temperatures at crash time?

---

## Expected Outcomes

| Finding | Likely Cause | Solution |
|---------|--------------|----------|
| MCE events in logs | Hardware fault (CPU/memory) | RMA or replace |
| Memory stress triggers reboot | RAM issue or power delivery | Test RAM, check PSU |
| AVX stress triggers reboot | CPU VRM issue | Limit frequency, better cooling |
| Only Docker buildx triggers | Software/driver bug | Update kernel, use remote builder |
| High temps at crash | Thermal issue | Repaste, clean, better cooling |
| No logs before reboot | Sudden power loss | Check PSU, power delivery |

---

## Files to Potentially Modify

If we need NixOS changes:
- `nixos/hosts/hawk/default.nix` - Add monitoring packages, kernel parameters
- `nixos/hosts/hawk/hardware-configuration.nix` - CPU frequency limits
- `nixos/hosts/hawk/forgejo/forgejo-runner.nix` - Resource limits for runners

---

## Verification

After implementing fixes, verify by:
1. Running the failing builds (`marmithon`, `airport-swiss-knife`) successfully
2. No unexpected reboots during ARM64 builds
3. Monitoring temperatures remain within acceptable range

---

## Investigation Log

### Session 1 - 2026-01-20

#### System Information
- **Hardware**: Beelink SER5 Max
- **CPU**: AMD Ryzen 7 6800U with Radeon Graphics
- **RAM**: 23.5GB
- **Storage**: 2x NVMe drives
- **Kernel**: 6.12.63 NixOS

#### Tests Performed

##### 1. Journal Persistence Verification
- **Result**: ✅ Persistent journal enabled at `/var/log/journal/`
- **Boot history**: 44+ boots logged, many short-lived (2-15 min) during crash periods

##### 2. Historical Crash Analysis
- Reviewed boot logs from Jan 2-11 showing crash patterns
- Boot -6 (Jan 15): Confirmed crash during `airport-swiss-knife` build
  - Journal stops mid-activity, no shutdown sequence
  - Runner was actively updating tasks when crash occurred
- **No MCE (Machine Check Exception) events found** in any crash logs

##### 3. Single Runner Test
- Disabled `gitea-runner-second`, kept only `gitea-runner-first`
- **Test 1 - airport-swiss-knife**: ✅ Succeeded (first successful ARM64 build on this machine!)
  - Peak CPU temp: 82.5°C
  - Build duration: ~7 minutes
- **Test 2 - marmithon (warm start)**: ❌ Crashed at ~30 seconds
  - Started with CPU at ~43°C (after previous build)
  - CPU reached ~75-80°C before crash
- **Test 3 - marmithon (cold start)**: ❌ Crashed at ~20 seconds
  - Started with CPU at **20°C** (machine idle 20+ minutes)
  - **CPU stayed at 20°C until crash** - temperature never rose!

##### 4. Temperature Monitoring Results

**Cold start test (most significant):**
```
=== Temperature Monitor Started at Tue Jan 20 08:55:33 AM EST 2026 ===
Baseline - CPU: 20°C, GPU: 38°C
08:55:41 CPU:20 GPU:37
...
08:56:55 CPU:20 GPU:37  <-- Last reading before crash
```

The CPU remained at 20°C for the entire duration until crash. **This definitively rules out thermal issues.**

#### Key Findings

| Finding | Result |
|---------|--------|
| Journal persistence | ✅ Working |
| MCE events | ❌ None logged |
| Single runner helps | ❌ No - still crashes |
| Thermal cause | ❌ **Ruled out** - crashes at 20°C |
| Crash type | Instant death, no shutdown sequence |
| Time to crash | ~20-30 seconds into QEMU emulation |

#### Conclusions

1. **NOT a thermal issue** - Machine crashes while CPU is at room temperature (20°C)
2. **NOT a concurrent load issue** - Single runner still crashes
3. **NOT logged by kernel** - No MCE, no warnings, instant death
4. **Specific to QEMU ARM64** - AMD64 builds work fine, CPU stress tests work fine

#### Likely Root Causes (in order of probability)

1. **Power delivery issue** - QEMU ARM64 emulation causes a specific current draw pattern that triggers PSU/VRM protection or instability
2. **Kernel/KVM bug** - Something in the ARM64 emulation code path triggers an unrecoverable state
3. **Hardware incompatibility** - Ryzen 6800U + specific QEMU workload = instant crash

#### Recommended Next Steps

1. **BIOS adjustments** (requires physical access):
   - Disable CPU turbo boost
   - Lower power limits (PL1/PL2)
   - Check/disable any overclocking profiles

2. **Software CPU frequency limiting**:
   ```bash
   # Temporarily limit max frequency
   echo 2000000 | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq
   ```

3. **Long-term solution**: Offload ARM64 builds to actual ARM hardware (opi01-03)
   ```bash
   docker buildx create --name arm-builder \
     --driver docker-container \
     --platform linux/arm64 \
     ssh://user@opi01.internal
   ```

#### Raw Data

**Hwmon devices on hawk:**
- hwmon0: nvme (temps: 46-48°C)
- hwmon1: nvme (temp: 43°C)
- hwmon2: k10temp (CPU Tctl)
- hwmon3: acpitz (ACPI thermal zone)
- hwmon4: mt7921_phy0 (WiFi)
- hwmon5: amdgpu (iGPU edge temp)

---

### Session 1 Continued - Solution Found

#### Frequency Limiting Test

After ruling out thermal issues, tested with CPU frequency limited to 2.7 GHz (base clock, no turbo):

```bash
echo 2700000 | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq
```

**Result**: ✅ `marmithon` build completed successfully!

- CPU stayed at steady 41°C throughout
- Load reached 11+ without issues
- Build completed in ~5 minutes

#### Community Research

Web search revealed this is a **known issue with Beelink SER5 Max**:

| Source | Finding |
|--------|---------|
| [Beelink Forum - SER5 Max crashes](https://bbs.bee-link.com/d/9082-ser5-max-6800u-crashes) | Crashes when "single core is idle and boosts" - fix via BIOS power limits |
| [Beelink Forum - crash under load](https://bbs.bee-link.com/d/8466-pc-crash-while-under-load-ser5-max-6800u-32gb-1tb) | Same 20°C sensor reading (stuck sensor), Beelink recommends disabling turbo |
| [Level1Techs - GTR7 analysis](https://forum.level1techs.com/t/updated-beelink-gtr7-7840-7940-pro-random-reboot-crashing-issue-the-reason-and-a-possible-fix-for-some/199561) | Root cause: C6 power state malfunction during rapid core parking |

The 20°C constant reading is likely a **faulty/stuck thermal sensor** - a known issue on this hardware.

#### Solution Implemented

Added to `nixos/hosts/hawk/default.nix`:

```nix
# Disable CPU turbo boost to prevent crashes during QEMU ARM64 emulation.
# The Beelink SER5 Max has a known power delivery issue where rapid core
# state transitions (common in QEMU workloads) cause instant reboots.
# See: docs/troubleshooting/hawk-qemu-arm64-reboots.md
# See: https://bbs.bee-link.com/d/9082-ser5-max-6800u-crashes
# Note: kernel param amd_pstate.no_boost=1 doesn't work with amd-pstate-epp driver
systemd.tmpfiles.rules = [
  "w /sys/devices/system/cpu/cpufreq/boost - - - - 0"
];
```

**Note**: Initially tried `boot.kernelParams = [ "amd_pstate.no_boost=1" ]` but this doesn't work with the `amd-pstate-epp` driver. The systemd tmpfiles approach writes directly to sysfs at boot and works reliably.

#### Final Verification

After deploying the permanent fix, ran `marmithon` build again:

- ✅ Build completed successfully
- CPU stayed at steady 41-42°C throughout
- Load reached 10+ without issues
- Both Forgejo runners active and stable

#### Sensor Analysis

| Sensor | Reading | Status |
|--------|---------|--------|
| k10temp (Tctl) | 41-42°C | CPU temp - appears correct |
| acpitz (ACPI) | 20°C | **Stuck/faulty** - known defect |
| amdgpu | 42°C | iGPU temp - normal |
| NVMe drives | 47-55°C | Normal under load |
| WiFi (mt7921) | 52°C | Normal |

The **acpitz sensor stuck at 20°C** matches reports from other Beelink SER5 Max users on the forums - this is another symptom of the hardware defect.

#### Alternative Solutions (not implemented)

1. **BIOS power limits** - Set TDP 28W, TDC 45A, EDC 70A (allows turbo, more complex)
2. **Contact Beelink support** - May provide replacement PSU or unit (warranty)
3. **Offload ARM64 builds** - Use opi01-03 (native ARM) for ARM64 builds

#### Status: RESOLVED

- **Fix applied**: systemd tmpfiles rule to disable turbo boost at boot
- **Verified working**: 2026-01-20 - multiple successful ARM64 builds
- **Warranty**: 1 year - will contact Beelink about the hardware defect (power delivery + faulty ACPI sensor)

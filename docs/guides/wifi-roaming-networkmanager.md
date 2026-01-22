# WiFi Roaming Configuration with NetworkManager

This guide explains how to control WiFi roaming behavior on Linux using NetworkManager, particularly useful when you have multiple access points or a mesh network.

## Overview

When multiple APs broadcast the same SSID, NetworkManager (via wpa_supplicant) will automatically roam between them based on signal strength. This can cause issues:

- Flip-flopping between APs with similar signal strength
- Unnecessary switches between 2.4GHz and 5GHz bands
- Brief connection drops during roaming

## Diagnosing Roaming Issues

### Check current connection

```bash
nmcli dev wifi list --rescan yes
```

The `*` indicates your current connection. Note the BSSID, channel, and signal strength.

### View roaming history

```bash
sudo dmesg | grep wlp
```

Look for patterns like:
```
wlp3s0: disconnect from AP xx:xx:xx for new auth to yy:yy:yy
```

### Identify your BSSIDs

Dual-band APs typically have sequential MAC addresses:
- `50:91:E3:68:08:C4` - 2.4GHz (lower channels: 1-11)
- `50:91:E3:68:08:C5` - 5GHz (higher channels: 36, 149, etc.)

## Configuration Options

### Option 1: Lock to 5GHz band only

Best when 5GHz coverage is adequate. Prevents slow 2.4GHz connections.

```bash
nmcli connection modify "YourSSID" wifi.band a
```

Values:
- `a` = 5GHz only
- `bg` = 2.4GHz only
- `""` (empty) = automatic (default)

### Option 2: Lock to specific BSSID

Forces connection to one specific AP. Use when one AP clearly has better signal at your location.

```bash
nmcli connection modify "YourSSID" wifi.bssid 50:91:E3:68:08:C5
```

### Option 3: Adjust roaming sensitivity

Configure background scanning to reduce roaming aggressiveness:

```bash
nmcli connection modify "YourSSID" 802-11-wireless.bgscan "simple:60:-65:86400"
```

Format: `simple:short_interval:signal_threshold:long_interval`
- `60` - scan every 60 seconds when signal is weak
- `-65` - only consider roaming if signal drops below -65 dBm
- `86400` - scan every 86400 seconds (24h) when signal is good

## Applying Changes

After modifying settings, reconnect:

```bash
nmcli connection down "YourSSID" && nmcli connection up "YourSSID"
```

## Reverting Changes

### Reset band to automatic

```bash
nmcli connection modify "YourSSID" wifi.band ""
```

### Remove BSSID lock

```bash
nmcli connection modify "YourSSID" wifi.bssid ""
```

### Remove bgscan setting

```bash
nmcli connection modify "YourSSID" 802-11-wireless.bgscan ""
```

## Viewing Current Settings

```bash
nmcli connection show "YourSSID" | grep -E "^wifi\.|^802-11-wireless\."
```

Key fields:
- `802-11-wireless.band` - frequency band restriction
- `802-11-wireless.bssid` - locked BSSID (if any)
- `802-11-wireless.seen-bssids` - all BSSIDs this connection has used

## Troubleshooting

### WiFi won't connect after band lock

The locked band may not be available. Revert to automatic:

```bash
nmcli connection modify "YourSSID" wifi.band ""
nmcli connection up "YourSSID"
```

### Finding your connection name

```bash
nmcli connection show --active | grep wifi
```

### Check if settings were applied

```bash
nmcli connection show "YourSSID" | grep band
```

## Signal Strength Reference

| dBm | Quality | Description |
|-----|---------|-------------|
| -30 | Excellent | Maximum achievable |
| -50 | Excellent | Very strong |
| -60 | Good | Reliable connection |
| -70 | Fair | Acceptable for most uses |
| -80 | Poor | May have issues |
| -90 | Unusable | Connection will drop |

## References

- [NetworkManager Documentation](https://networkmanager.dev/docs/)
- [wpa_supplicant bgscan](https://wiki.archlinux.org/title/wpa_supplicant#Roaming)

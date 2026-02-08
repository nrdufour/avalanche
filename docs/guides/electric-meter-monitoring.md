# Electric Meter Monitoring Setup Guide

## Background

- **Meter**: Landis+Gyr FOCUS FAXRe-SD (2023)
- **RF Module**: Gridstream RF (proprietary, encrypted — incompatible with rtlamr)
- **ZigBee HAN**: Present on meter but PSE&G does not provision HAN devices for customers
- **Solution**: Refoss EM16P with CT clamps on the main legs inside the breaker panel

## What to Buy

| Item | Notes |
|------|-------|
| **Refoss EM16P** | Smart energy monitor with open local API. 2x 200A mains CTs + 16x 60A branch CTs included. Wi-Fi (2.4 GHz) with external antenna. ~$200 on Amazon. |

**Important**: Get the **EM16P** model (with the "P"), not the base EM16. The "P" version has the open local API, MQTT support, and web UI. The base EM16 without "P" is cloud-only.

The EM16P comes with everything you need — mains CTs, branch CTs, and the external Wi-Fi antenna.

**Note on 250A service**: The included mains CTs are rated for 200A. Your panel is rated 250A, but typical residential draw is 30-80A under normal load. The 200A CTs will handle your actual usage — they would only clip readings if you somehow drew over 200A sustained, which is extremely unlikely in normal use.

## What to Tell the Electrician

> I need a Refoss EM16P energy monitor installed in my breaker panel. Here's what's involved:
>
> 1. Turn off the main breaker
> 2. Mount the Refoss EM16P inside the panel — it's designed for US NEMA load centers, keep it at least 2 inches from live parts (excluding insulated components)
> 3. Clip the two 200A split-core CT clamps around the two main hot legs (L1 and L2)
> 4. Optionally clip additional 60A branch CTs on individual circuits (up to 16)
> 5. Drill or punch a small hole in the panel to route the external Wi-Fi antenna cable outside the panel — the antenna must be outside the metal enclosure for signal
> 6. Connect the antenna cable to the labeled jack on the monitor
> 7. Connect all CT leads to the monitor

This should take 30-60 minutes. No wires need to be cut — the CTs are split-core and just clip around existing conductors. The unit lives inside the panel; only the antenna routes outside.

**Why an electrician**: Even with the main breaker off, the service entrance wires from the meter remain live (they're upstream of the main breaker). The mains CTs need to clip onto these 250A conductors. An electrician knows how to work safely around live service entrance wiring — not worth the risk for a 30-minute job.

**Panel type**: US NEMA load center, 250A service, split-phase 240V.

## Refoss EM16P Setup

### 1. Initial Configuration

1. Download the Refoss app for initial Wi-Fi setup
2. Connect the EM16P to your 2.4 GHz Wi-Fi network
3. Once connected, note the device's IP address (assign a static IP/DHCP reservation on routy)
4. Access the local web UI at the device's IP address
5. Configure MQTT to point at `mqtt.internal:1883` (Mosquitto broker in the `home-automation` namespace)

After initial setup via the app, you can manage everything locally — no cloud account required for ongoing operation.

### 2. Local Communication

The EM16P supports multiple local protocols out of the box (no firmware hacking needed):
- **Native HA integration** (core) — auto-discovery on your LAN
- **MQTT** — broker available at `mqtt.internal:1883`
- **Local Web UI** — for configuration and status monitoring
- **Local HTTP API** — for custom automation

## Home Assistant Configuration

Home Assistant runs in the K3s cluster (`home-automation` namespace) and is accessible at `https://ha.internal`.

- **Deployment**: `kubernetes/base/apps/home-automation/home-assistant/`
- **Config storage**: NFS on `possum.internal:/tank/NFS/ha` mounted at `/config`
- **Database**: CNPG PostgreSQL 16 cluster (`hass-16-db`, 3 instances on opi01-03)
- **MQTT broker**: Mosquitto at `mqtt.internal:1883` (same namespace)

### 1. Integration Setup

The Refoss integration is a **native core integration** — no HACS or custom components needed.

- Go to **Settings > Devices & Services > Add Integration**
- Search for **Refoss**
- The device should auto-discover on your network
- If not, enter the device's IP address manually
- HA will create entities for all configured CT channels

### 2. Entities Created

The EM16P will create entities for each CT input:

- `sensor.em16p_channel_1_power` — real-time watts (L1 mains)
- `sensor.em16p_channel_2_power` — real-time watts (L2 mains)
- `sensor.em16p_channel_1_energy` — cumulative kWh (L1 mains)
- `sensor.em16p_channel_2_energy` — cumulative kWh (L2 mains)
- Additional entities for each branch circuit CT connected
- Voltage, current, and power factor sensors per channel

(Exact entity names depend on your HA instance and device naming.)

### 3. Energy Dashboard

Go to **Settings > Dashboards > Energy**:

- Under **Electricity grid > Grid consumption**, add both mains energy sensors:
  - `sensor.em16p_channel_1_energy`
  - `sensor.em16p_channel_2_energy`
- If monitoring branch circuits via the 60A CTs, add them under **Individual devices**
- Set your electricity cost (PSE&G rate) for cost tracking

### 4. Total Home Power Sensor (Optional)

Create a template sensor in `configuration.yaml` (on the NFS share at `possum.internal:/tank/NFS/ha/configuration.yaml`) to combine both legs into a single whole-home wattage reading:

```yaml
template:
  - sensor:
      - name: "Whole Home Power"
        unit_of_measurement: "W"
        device_class: power
        state_class: measurement
        state: >
          {{ states('sensor.em16p_channel_1_power') | float(0)
           + states('sensor.em16p_channel_2_power') | float(0) }}
```

## Cross-Referencing with Z-Wave Per-Circuit Data

Z-Wave devices are managed via the Z-Wave controller in the `home-automation` namespace. Since you already monitor individual circuits via Z-Wave, you can create a sensor that shows "unmonitored" load:

```yaml
template:
  - sensor:
      - name: "Unmonitored Load"
        unit_of_measurement: "W"
        device_class: power
        state_class: measurement
        state: >
          {{ states('sensor.whole_home_power') | float(0)
           - states('sensor.zwave_circuit_1_power') | float(0)
           - states('sensor.zwave_circuit_2_power') | float(0)
           - states('sensor.zwave_circuit_3_power') | float(0) }}
```

Replace the Z-Wave sensor names with your actual entity IDs. This helps identify phantom loads or circuits you're not yet monitoring.

With the EM16P's 16 branch circuit CTs, you could also monitor circuits that don't have Z-Wave devices — giving you even more coverage.

## Future: PSE&G HAN Access

Worth periodically checking if PSE&G enables ZigBee HAN provisioning. If they do:
- Buy a **Rainforest Eagle-200** (~$100-150)
- Call PSE&G to request HAN provisioning (provide the device MAC + install code)
- HA has a native `rainforest_eagle` integration
- This would give you billing-grade meter data directly from the utility meter

You can also advocate for this by filing a comment with the **NJ Board of Public Utilities** (https://nj.gov/bpu/) — their AMI approval included data access requirements.

## Quick Reference

| Item | Detail |
|------|--------|
| Meter type | Landis+Gyr FOCUS FAXRe-SD |
| Service | 250A, 240V split-phase |
| Utility | PSE&G, West Orange NJ |
| Solution | Refoss EM16P + electrician install |
| HA instance | `https://ha.internal` |
| HA integration | Native Refoss integration (core) |
| MQTT broker | `mqtt.internal:1883` |
| HA config path | `possum.internal:/tank/NFS/ha` |
| K8s namespace | `home-automation` |
| Product page | https://refoss.net/products/smart-energy-monitor-em16p |

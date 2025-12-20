# ADR-001: Extended NUT Data Mapping

## Status

Accepted (Partially Implemented)

## Context

The `fake_battery_nut` kernel module exposes NUT UPS data through the Linux power_supply subsystem. Initially conceived as a way to show UPS stats in btop, we discovered a more significant value proposition:

**NUT claims USB devices exclusively, preventing UPower from seeing UPS hardware natively. This module bridges NUT to UPower, enabling desktop power management integration.**

### Data Flow

```
UPS Hardware
     │
     ▼
NUT (usbhid-ups driver claims USB exclusively)
     │
     ▼
upsc queries ───► nut-to-fakebattery daemon
                          │
                          ▼
                  /dev/fake_battery_nut
                          │
                          ▼
                  kernel module
                          │
                          ▼
              /sys/class/power_supply/
                          │
                          ▼
                      UPower
                          │
                          ▼
              Desktop Environment (KDE/GNOME)
```

### Why This Matters

Without this bridge:
- NUT works fine for monitoring and scripted shutdown
- UPower cannot see the UPS (`ups_hiddev*` doesn't exist)
- Desktop environments have no idea a UPS exists
- No battery icon, no low-power warnings, no auto-hibernate

With this bridge:
- Desktop sees UPS as a battery via `/sys/class/power_supply/BAT0`
- KDE/GNOME show battery status, respond to power events
- System can auto-hibernate when UPS battery is critical
- btop also works (the original goal)

### Currently Mapped (v1.1.0)

| NUT Field | Control Command | power_supply Property |
|-----------|-----------------|----------------------|
| battery.charge | capacity | BAT0/capacity |
| battery.runtime | time | BAT0/time_to_empty_avg |
| battery.voltage | voltage | BAT0/voltage_now |
| ups.status (OL/OB) | status, charging | BAT0/status, AC0/online |
| (settable) | temp | BAT0/temp |

## Decision Drivers

1. **Desktop integration** - UPower/KDE/GNOME can respond to UPS events
2. **power_supply API constraints** - Limited to properties the kernel API supports
3. **Simplicity** - Single battery device, clean UPower integration
4. **The btop irony** - btop only shows `BAT= 100%` anyway

## Problem: BAT1 Pollution (Resolved)

The original design exposed two batteries:
- BAT0: UPS battery charge %
- BAT1: UPS load % (semantically wrong - load isn't a battery)

UPower's `DisplayDevice` averaged both, causing incorrect readings:
- BAT0: 100%, BAT1: 21% → DisplayDevice: ~34% (wrong!)

**Resolution:** Removed BAT1 entirely. Load monitoring available via `upsc` directly.

## Options Considered

### Option A: Minimal Extension ✓ Implemented

Single battery (BAT0) with settable temperature:

| Field | Command | Notes |
|-------|---------|-------|
| capacity | capacity=N | 0-100% |
| runtime | time=N | seconds |
| voltage | voltage=N | microvolts |
| temperature | temp=N | tenths of °C (260 = 26.0°C) |
| status | status=N | 0=discharging, 1=charging, 2=full |
| AC online | charging=N | 0=offline, 1=online |

### Option B: Sysfs Extension (Rejected)

Custom sysfs attributes for all NUT data. Too complex, non-standard attributes may confuse tools.

### Option C: Companion Daemon (Rejected)

JSON/socket daemon for full NUT data. Doesn't help desktop integration - UPower needs power_supply devices.

### Option D: Temperature from hwmon (Deferred)

The daemon could read ambient temperature from system sensors. Currently left as settable placeholder (defaults to 26.0°C). Most consumer UPS units don't report temperature anyway.

## Consequences

### Positive

- Clean UPower integration (single battery, accurate %)
- Desktop environments can auto-hibernate on low UPS battery
- Simplified kernel module (removed BAT1 complexity)
- Temperature now displays correctly (was showing 2.6°C, now 26.0°C)

### Negative

- Lost load % monitoring in btop (use `upsc` or other NUT tools)
- Temperature is placeholder unless daemon sets it

### Neutral

- UPower sees device as "battery" not "UPS" (kernel's POWER_SUPPLY_TYPE_UPS isn't handled by UPower)

## Implementation Notes

Changes in v1.1.0:
- Removed BAT1 (load meter) - fixes UPower DisplayDevice pollution
- Simplified control interface (removed numbered suffixes: `capacity0` → `capacity`)
- Fixed temperature unit bug (26 → 260 tenths of °C)
- Added `temp=N` control command

## The Preserved Irony

We wrote a kernel module because btop doesn't have plugins. btop displays `BAT= 100%`. But accidentally, we built the missing bridge between NUT and desktop power management that nobody else bothered to make.

The walnut-powered PC image remains canonical.

## References

- [Linux power_supply class documentation](https://www.kernel.org/doc/html/latest/power/power_supply_class.html)
- [NUT variable naming](https://networkupstools.org/docs/developer-guide.chunked/apas01.html)
- [UPower Reference Manual](https://upower.freedesktop.org/docs/UPower.html)

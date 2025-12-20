# Project Context: fake-battery-nut

## The Origin Story

This project was born from the most relatable of problems: **a gaming PC tripping a UPS alarm**.

The user upgraded to a beastly rig:
- AMD Ryzen 9 9950X3D
- AMD RX 7900 XTX (24GB VRAM)
- 128GB RAM
- Samsung Odyssey 57" super ultrawide (7680x2160 @ 120Hz)

When they fired up Minecraft with Distant Horizons and shaders maxed out, their UPS started screaming. The alarm was going off because the load exceeded capacity.

## The Journey

### Phase 1: Diagnosis
We plugged in a USB cable that had been ignored for 4 years and discovered the UPS was a CyberPower CST135XLU rated at only **810W real power**. The gaming rig was pulling **123% load** (about 1000W) during gameplay.

### Phase 2: The $0 Fix
Instead of buying a $600+ UPS, we simply moved the monitor to a separate smaller UPS. Load dropped to **93%** - just under the alarm threshold. Problem solved for $0.

### Phase 3: The Over-Engineering Begins
The user wanted to monitor UPS data in btop. btop doesn't have NUT support and reads from `/sys/class/power_supply/`.

The UPS doesn't expose itself as a kernel power_supply device.

So we built a kernel module to bridge the gap.

### Phase 4: This Project
We forked [linux-fake-battery-module](https://github.com/hoelzro/linux-fake-battery-module) and enhanced it to:
- Accept more control commands (time, voltage, status)
- Rename the device to `/dev/fake_battery_nut`
- Label batteries as "UPS Battery" and "UPS Load"
- Set up DKMS for kernel update survival

A daemon script reads from NUT and writes to the kernel module. btop now shows UPS stats as battery info.

## The Irony

The user mentioned they have a **bus conversion** with:
- Twin 3kVA Victron Quattro inverters (split-phase)
- 20kWh Nissan Leaf battery pack
- 3kW solar panels

This off-grid power system provided perfect power for years. But their house in Wichita has flickering lights and surges.

The bus power system sits idle while they nurse an overloaded consumer UPS.

## Files

- `fake_battery_nut.c` - Kernel module source
- `Makefile` - Build the module
- `dkms.conf` - DKMS configuration
- `nut-to-fakebattery.sh` - Daemon to feed NUT data to kernel module
- `fake-battery-nut.service` - systemd service for the daemon
- `PKGBUILD` - AUR package build script

## Usage Summary

```bash
# Load module
sudo modprobe fake_battery_nut

# Start daemon
sudo systemctl start fake-battery-nut

# Check values
cat /sys/class/power_supply/BAT0/capacity  # UPS battery %
cat /sys/class/power_supply/BAT1/capacity  # UPS load %
```

## Lessons Learned

1. Sometimes the $0 fix is the best fix
2. Plug in your UPS USB cable
3. btop is not extensible
4. Kernel modules are surprisingly approachable
5. Always document why, not just what

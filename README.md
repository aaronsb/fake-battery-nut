# fake-battery-nut

A Linux kernel module that exposes NUT (Network UPS Tools) data as standard `/sys/class/power_supply/` devices, making UPS information visible to tools like btop, KDE Plasma, and other system monitors that read battery status.

## Why?

Many system monitors (btop, KDE battery widget, etc.) read battery info from the Linux power_supply subsystem at `/sys/class/power_supply/`. UPS devices connected via NUT don't appear there - they're only accessible through NUT's own tools.

This module creates virtual battery devices that a userspace daemon can update with NUT data, bridging the gap.

## The Origin Story

This project was born when a gaming PC (Ryzen 9950X3D, RX 7900 XTX, 57" ultrawide) started tripping UPS overload alarms while running Minecraft with shaders. After plugging in a USB cable that had been ignored for 4 years, we discovered the UPS was running at 123% capacity.

The fix? Move the monitor to a different UPS. $0 solution. Problem solved.

But then: "I want to see UPS stats in btop."

btop doesn't support NUT. So we wrote a kernel module.

### The Duality of Engineering

**Power delivery:**
```
Wall → 1350VA UPS → surge-only outlet → 450VA mini UPS → monitor
                  → battery outlet → gaming PC (93% load)
```
*"eh, the cords are beefy, it's probably fine"*

**Monitoring:**
```
UPS → USB HID → NUT daemon → upsc → bash script →
/dev/fake_battery_nut → custom kernel module →
/sys/class/power_supply/ → btop
```
*"we need proper kernel-level integration for the data to show up correctly"*

One is an extension cord chain held together by vibes. The other is a DKMS-managed kernel module with systemd integration, published on GitHub, ready for AUR.

## Components

- **fake_battery_nut.ko** - Kernel module creating BAT0, BAT1, AC0 in `/sys/class/power_supply/`
- **/dev/fake_battery_nut** - Control interface for updating values
- **nut-to-fakebattery** - Daemon that reads NUT and writes to the kernel module

## Installation

### From AUR (Arch Linux)

```bash
yay -S fake-battery-nut-dkms
```

### Manual Installation

```bash
# Build
make

# Install module
sudo make install

# Or use DKMS
sudo cp -r . /usr/src/fake-battery-nut-1.0.0
sudo dkms add fake-battery-nut/1.0.0
sudo dkms build fake-battery-nut/1.0.0
sudo dkms install fake-battery-nut/1.0.0

# Install daemon
sudo install -m755 nut-to-fakebattery.sh /usr/bin/nut-to-fakebattery
sudo install -m644 fake-battery-nut.service /etc/systemd/system/

# Enable
echo "fake_battery_nut" | sudo tee /etc/modules-load.d/fake-battery-nut.conf
sudo systemctl enable --now fake-battery-nut
```

## Configuration

Edit `/etc/systemd/system/fake-battery-nut.service` to set your UPS:

```ini
Environment=NUT_UPS=myups@localhost
```

## Control Interface

Write to `/dev/fake_battery_nut` to set values:

```bash
echo "capacity0=100" | sudo tee /dev/fake_battery_nut  # BAT0 capacity %
echo "capacity1=45" | sudo tee /dev/fake_battery_nut   # BAT1 capacity %
echo "time0=1800" | sudo tee /dev/fake_battery_nut     # Runtime in seconds
echo "voltage0=24000000" | sudo tee /dev/fake_battery_nut  # Voltage in µV
echo "status0=2" | sudo tee /dev/fake_battery_nut      # 0=discharge, 1=charge, 2=full
echo "charging=1" | sudo tee /dev/fake_battery_nut     # AC online status
```

## Data Mapping

| BAT0 (UPS Battery) | BAT1 (UPS Load) |
|--------------------|-----------------|
| capacity = battery.charge | capacity = ups.load |
| time_to_empty = battery.runtime | - |
| voltage = battery.voltage | voltage = input.voltage |
| status = ups.status | - |

## Requirements

- Linux kernel headers
- NUT (nut package)
- bc (for voltage conversion in daemon)

## License

GPL v2 (same as original linux-fake-battery-module)

## Credits

Based on [linux-fake-battery-module](https://github.com/hoelzro/linux-fake-battery-module) by Rob Hoelz.

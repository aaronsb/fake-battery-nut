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
- Label the supply as "UPS Battery" (with AC0 for mains)
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
cat /sys/class/power_supply/AC0/online     # 1=mains, 0=on battery
```

On systems that already have a real `BAT0`, load with custom names:
`modprobe fake_battery_nut battery_name=BAT_UPS ac_name=AC_UPS`.

## Lessons Learned

1. Sometimes the $0 fix is the best fix
2. Plug in your UPS USB cable
3. btop is not extensible
4. Kernel modules are surprisingly approachable
5. Always document why, not just what

## Releasing

`aaronsb/arch-repo` publishes this project. It reads `./PKGBUILD` from the
default branch, builds it in a clean container, lints with namcap, signs, and
pushes to the AUR (`fake-battery-nut-dkms`) and the `[aaronsb]` pacman
repository.

```bash
make package                          # clean-chroot build + namcap; fails on a namcap error
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
gh release create vX.Y.Z --generate-notes
```

Nothing here talks to the AUR. `publish-aur.sh` is gone: two writers to one AUR
ref is how a PKGBUILD and its `.SRCINFO` drift apart.

### Fields arch-repo owns

It overwrites all four before publishing, so a value set here is only wrong
until it does. Do not maintain them, and do not commit a `.SRCINFO` — the one
that used to be tracked still declared `license = GPL2` long after the recipe
said otherwise.

| Field | Where it really comes from |
|---|---|
| `pkgver` | the newest published GitHub release |
| `pkgrel` | arch-repo's count of how many times it packaged that release |
| `sha256sums` | computed from the release artifact |
| `.SRCINFO` | regenerated at publish |

This project's own version lives in `dkms.conf` — `PACKAGE_VERSION`. Bump that
when you release, and `make version` will report it.

### A packaging fix needs no release

Change the recipe on the default branch and push. arch-repo ships the
difference as a `pkgrel` bump — `1.2.0-1` becomes `1.2.0-2`, resetting to `-1`
at the next real release.

This is safe for DKMS. `dkms.conf` is installed out of the extracted tarball,
not the repository tree, so `v1.2.0`'s tarball already carries
`PACKAGE_VERSION="1.2.0"` and it lands in `/usr/src/fake-battery-nut-1.2.0`
where DKMS looks for it. A `pkgrel` bump leaves `pkgver` alone, so the directory
and the file stay in agreement.

### The module build lives in `Kbuild`, not `Makefile`

`Kbuild` carries the `obj-m` line and is what `package()` installs into
`/usr/src` for DKMS. `dkms.conf`'s `MAKE[0]` invokes kbuild with `M=<dir>`, and
kbuild reads `Kbuild` before `Makefile` — which is what leaves this
repository's `Makefile` free for developer and packaging targets that have no
business in `/usr/src`.

The full contract: https://github.com/aaronsb/arch-repo/blob/main/docs/packaging-contract.md

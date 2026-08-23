#!/bin/bash
# fake-battery-nut installer / updater
#
# Safe to re-run: force-rebuilds the DKMS module for the same version,
# reloads it into the running kernel, and refreshes the daemon/service.
set -e

VERSION="1.2.1"
DKMS_NAME="fake-battery-nut"
MODULE="fake_battery_nut"
SERVICE="fake-battery-nut.service"
SRCDIR="/usr/src/${DKMS_NAME}-${VERSION}"

echo "=== Installing fake-battery-nut v${VERSION} ==="

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo $0)"
    exit 1
fi

# Check dependencies
echo "Checking dependencies..."
if ! command -v upsc &> /dev/null; then
    echo "ERROR: NUT not installed. Install with: pacman -S nut"
    exit 1
fi

if ! getent group nut &> /dev/null; then
    echo "ERROR: nut group not found (expected from the nut package)"
    exit 1
fi

if ! getent passwd nut &> /dev/null; then
    echo "ERROR: nut user not found (expected from the nut package)"
    exit 1
fi

if ! command -v bc &> /dev/null; then
    echo "ERROR: bc not installed. Install with: pacman -S bc"
    exit 1
fi

if ! command -v dkms &> /dev/null; then
    echo "ERROR: DKMS not installed. Install with: pacman -S dkms"
    exit 1
fi

if ! pacman -Q linux-headers &> /dev/null; then
    echo "ERROR: linux-headers not installed. Install with: pacman -S linux-headers"
    exit 1
fi

# Preserve drop-in config; only restart later if it was already running.
SERVICE_WAS_ACTIVE=0
if systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    SERVICE_WAS_ACTIVE=1
fi

# Daemon holds /dev/fake_battery_nut open — stop it before rmmod.
echo "Stopping service (if running)..."
systemctl stop "$SERVICE" 2>/dev/null || true

echo "Unloading module (if loaded)..."
if lsmod | grep -q "^${MODULE} "; then
    if ! rmmod "$MODULE"; then
        echo "ERROR: could not unload $MODULE (is something else using it?)"
        exit 1
    fi
fi

# Refresh sources and force a clean DKMS rebuild for this same version.
# Without remove+re-add, `dkms build` may reuse a stale .ko when VERSION is unchanged.
echo "Installing DKMS module..."
mkdir -p "$SRCDIR"
cp fake_battery_nut.c "$SRCDIR/"
cp Kbuild "$SRCDIR/"
cp dkms.conf "$SRCDIR/"

dkms remove -m "$DKMS_NAME" -v "$VERSION" --all 2>/dev/null || true
dkms add -m "$DKMS_NAME" -v "$VERSION"
dkms build -m "$DKMS_NAME" -v "$VERSION"
dkms install -m "$DKMS_NAME" -v "$VERSION" --force

# Auto-load module on boot
echo "Configuring module autoload..."
echo "$MODULE" > /etc/modules-load.d/fake-battery-nut.conf

echo "Loading module..."
modprobe "$MODULE"

# Install daemon
echo "Installing daemon..."
install -Dm755 nut-to-fakebattery.sh /usr/bin/nut-to-fakebattery

# Install systemd service (does not touch systemctl edit drop-ins)
echo "Installing systemd service..."
install -Dm644 fake-battery-nut.service /etc/systemd/system/fake-battery-nut.service

# Restrict control device to root and the nut group (daemon runs as nut)
echo "Setting up udev rule..."
cat > /etc/udev/rules.d/99-fake-battery-nut.rules << 'EOF'
KERNEL=="fake_battery_nut", GROUP="nut", MODE="0660"
EOF
udevadm control --reload-rules
udevadm trigger --name-match=fake_battery_nut 2>/dev/null || true

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable "$SERVICE"

if [ "$SERVICE_WAS_ACTIVE" -eq 1 ]; then
    echo "Restarting service..."
    systemctl start "$SERVICE"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "To configure your UPS:"
echo "  sudo systemctl edit fake-battery-nut"
echo "  # [Service]"
echo "  # Environment=NUT_UPS=yourups@host"
echo "  # Environment=BATTERY_CAPACITY_AH=9   # pack size in Ah (default 9)"
echo "  # Environment=POWER_NOW_DIVIDER=10    # scale Watts for UPower (default 1)"
echo ""
echo "Then start the service (if not already running):"
echo "  sudo systemctl start fake-battery-nut"
echo ""
echo "If desktop battery health is stuck at 0%, refresh UPower:"
echo "  sudo systemctl restart upower"
echo ""
echo "Check status:"
echo "  cat /sys/class/power_supply/BAT0/capacity"
echo "  cat /sys/class/power_supply/BAT0/manufacturer"
echo "  cat /sys/class/power_supply/AC0/online"

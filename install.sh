#!/bin/bash
# fake-battery-nut installer
set -e

VERSION="1.2.1"
SRCDIR="/usr/src/fake-battery-nut-${VERSION}"

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

# Install DKMS module
echo "Installing DKMS module..."
mkdir -p "$SRCDIR"
cp fake_battery_nut.c "$SRCDIR/"
cp Makefile "$SRCDIR/"
cp dkms.conf "$SRCDIR/"

dkms add -m fake-battery-nut -v "$VERSION" 2>/dev/null || true
dkms build -m fake-battery-nut -v "$VERSION"
dkms install -m fake-battery-nut -v "$VERSION" --force

# Auto-load module on boot
echo "Configuring module autoload..."
echo "fake_battery_nut" > /etc/modules-load.d/fake-battery-nut.conf

# Load module now
modprobe fake_battery_nut 2>/dev/null || insmod "$(modinfo -n fake_battery_nut)"

# Install daemon
echo "Installing daemon..."
install -Dm755 nut-to-fakebattery.sh /usr/bin/nut-to-fakebattery

# Install systemd service
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
systemctl enable fake-battery-nut

echo ""
echo "=== Installation complete ==="
echo ""
echo "To configure your UPS:"
echo "  sudo systemctl edit fake-battery-nut"
echo "  # [Service]"
echo "  # Environment=NUT_UPS=yourups@host"
echo ""
echo "Then start the service:"
echo "  sudo systemctl start fake-battery-nut"
echo ""
echo "Check status:"
echo "  cat /sys/class/power_supply/BAT0/capacity"
echo "  cat /sys/class/power_supply/AC0/online"

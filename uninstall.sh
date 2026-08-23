#!/bin/bash
# fake-battery-nut uninstaller
set -e

VERSION="1.2.1"

echo "=== Uninstalling fake-battery-nut ==="

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo $0)"
    exit 1
fi

# Stop and disable service
echo "Stopping service..."
systemctl stop fake-battery-nut 2>/dev/null || true
systemctl disable fake-battery-nut 2>/dev/null || true

# Unload module
echo "Unloading module..."
rmmod fake_battery_nut 2>/dev/null || true

# Remove from DKMS
echo "Removing DKMS module..."
dkms remove fake-battery-nut/"$VERSION" --all 2>/dev/null || true

# Remove files
echo "Removing files..."
rm -f /usr/bin/nut-to-fakebattery
rm -f /etc/systemd/system/fake-battery-nut.service
rm -rf /etc/systemd/system/fake-battery-nut.service.d
rm -f /etc/modules-load.d/fake-battery-nut.conf
rm -f /etc/udev/rules.d/99-fake-battery-nut.rules
rm -rf /usr/src/fake-battery-nut-"$VERSION"

# Reload
systemctl daemon-reload
udevadm control --reload-rules 2>/dev/null || true

echo ""
echo "=== Uninstallation complete ==="

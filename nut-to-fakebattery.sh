#!/bin/bash
# nut-to-fakebattery - Feed NUT UPS data to fake_battery_nut kernel module
#
# This daemon reads data from NUT and writes it to /dev/fake_battery_nut
# so that tools like btop and desktop environments (via UPower) can see
# UPS battery status.

DEVICE="/dev/fake_battery_nut"
UPS="${NUT_UPS:-cyberpower@localhost}"

log() {
    logger -t nut-to-fakebattery "$@"
}

# Wait for device to appear
while [ ! -e "$DEVICE" ]; do
    log "Waiting for $DEVICE..."
    sleep 2
done

log "Starting NUT to fake_battery_nut bridge for $UPS"

while true; do
    # Get all values in one upsc call
    DATA=$(upsc "$UPS" 2>/dev/null)

    if [ -n "$DATA" ]; then
        BATTERY=$(echo "$DATA" | grep "^battery.charge:" | cut -d: -f2 | tr -d ' ')
        RUNTIME=$(echo "$DATA" | grep "^battery.runtime:" | cut -d: -f2 | tr -d ' ')
        VOLTAGE=$(echo "$DATA" | grep "^battery.voltage:" | cut -d: -f2 | tr -d ' ')
        TEMP=$(echo "$DATA" | grep "^ups.temperature:" | cut -d: -f2 | tr -d ' ')
        STATUS=$(echo "$DATA" | grep "^ups.status:" | cut -d: -f2 | tr -d ' ')

        # Convert voltage to microvolts (NUT reports in V)
        if [ -n "$VOLTAGE" ]; then
            VOLTAGE_UV=$(echo "$VOLTAGE * 1000000" | bc | cut -d. -f1)
        fi

        # Convert temp to decidegrees (NUT reports in °C)
        if [ -n "$TEMP" ]; then
            TEMP_DD=$(echo "$TEMP * 10" | bc | cut -d. -f1)
        fi

        # Determine status value (0=discharging, 1=charging, 2=full)
        STATUS_VAL=2  # Default to full/online
        case "$STATUS" in
            *OB*) STATUS_VAL=0 ;;  # On Battery = discharging
            *CHRG*) STATUS_VAL=1 ;; # Charging
        esac

        # Determine AC status
        AC_STATUS=1
        if [[ "$STATUS" == *"OB"* ]]; then
            AC_STATUS=0
        fi

        # Write to kernel module
        {
            [ -n "$BATTERY" ] && echo "capacity=$BATTERY"
            [ -n "$RUNTIME" ] && echo "time=$RUNTIME"
            [ -n "$TEMP_DD" ] && echo "temp=$TEMP_DD"
            [ -n "$VOLTAGE_UV" ] && echo "voltage=$VOLTAGE_UV"
            echo "status=$STATUS_VAL"
            echo "charging=$AC_STATUS"
        } > "$DEVICE" 2>/dev/null
    fi

    sleep 2
done

#!/bin/bash
# nut-to-fakebattery - Feed NUT UPS data to fake_battery_nut kernel module
#
# This daemon reads data from NUT and writes it to /dev/fake_battery_nut
# so that tools like btop and desktop environments (via UPower) can see
# UPS battery status.

DEVICE="/dev/fake_battery_nut"
UPS="${NUT_UPS:-cyberpower@localhost}"
# After this many consecutive failed upsc polls, mark AC offline so desktops
# do not keep trusting a stale "online/full" reading during an outage.
MAX_FAILURES=3
INT_MAX=2147483647

log() {
    logger -t nut-to-fakebattery -- "$@"
}

write_device() {
    local data

    # Slurp stdin, then one open/write so the whole update is one payload.
    data=$(cat) || return 1
    if ! printf '%s' "$data" > "$DEVICE"; then
        log "Failed to write to $DEVICE"
        return 1
    fi
}

# NUT may report floats (e.g. 100.0); the kernel control interface wants ints.
int_field() {
    local raw="$1"
    raw="${raw%%.*}"
    raw="$(printf '%s' "$raw" | tr -cd '0-9-')"
    if [ -n "$raw" ] && [ "$raw" != "-" ] && [ "$raw" != "--" ]; then
        printf '%s' "$raw"
    fi
}

# Clamp to 0..100 so an out-of-range charge cannot abort the whole write.
clamp_capacity() {
    local n="$1"
    [ -z "$n" ] && return
    if [ "$n" -lt 0 ] 2>/dev/null; then
        printf '0'
    elif [ "$n" -gt 100 ] 2>/dev/null; then
        printf '100'
    else
        printf '%s' "$n"
    fi
}

# Clamp to 0..INT_MAX to match kernel validation.
clamp_nonneg_int() {
    local n="$1"
    [ -z "$n" ] && return
    if [ "$n" -lt 0 ] 2>/dev/null; then
        printf '0'
    elif [ "$n" -gt "$INT_MAX" ] 2>/dev/null; then
        printf '%s' "$INT_MAX"
    else
        printf '%s' "$n"
    fi
}

# True if haystack contains needle as a whole whitespace-delimited token.
# Avoids DISCHRG falsely matching CHRG.
status_has() {
    local needle="$1"
    local haystack="$2"

    case " $haystack " in
        *" $needle "*) return 0 ;;
        *) return 1 ;;
    esac
}

# First matching "key: value" line from the current upsc dump in DATA.
# Fixed-string prefix match so dots in NUT keys are not regex wildcards.
nut_get() {
    local key="$1"
    local line val

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "${key}:"*)
                val="${line#${key}:}"
                val="${val#"${val%%[![:space:]]*}"}"
                val="${val%"${val##*[![:space:]]}"}"
                printf '%s' "$val"
                return 0
                ;;
        esac
    done <<< "$DATA"
}

enter_failsafe() {
    local reason="${1:-update failed}"

    if [ "$in_failsafe" -eq 0 ]; then
        log "${reason} for $MAX_FAILURES polls; marking UPS on-battery (failsafe)"
    fi
    # Retry every poll until the failsafe write succeeds.
    if {
        echo "status=0"
        echo "charging=0"
    } | write_device; then
        in_failsafe=1
    fi
}

# Wait until the device exists and is writable by this process (udev may
# apply GROUP=nut shortly after the misc device appears).
waited=0
while [ ! -w "$DEVICE" ]; do
    log "Waiting for writable $DEVICE..."
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge 60 ]; then
        log "Timed out waiting for writable $DEVICE"
        exit 1
    fi
done

log "Starting NUT to fake_battery_nut bridge for $UPS"

fail_count=0
in_failsafe=0

while true; do
    # Get all values in one upsc call
    DATA=$(upsc "$UPS" 2>/dev/null) || true

    # Whitespace-only output is not usable UPS data.
    if [ -n "${DATA//[[:space:]]/}" ]; then
        BATTERY=$(clamp_capacity "$(int_field "$(nut_get battery.charge)")")
        RUNTIME=$(clamp_nonneg_int "$(int_field "$(nut_get battery.runtime)")")
        VOLTAGE=$(nut_get battery.voltage)
        # Normalize whitespace so token matching works with tabs/multi-spaces.
        STATUS=$(nut_get ups.status | sed 's/[[:space:]]\+/ /g')

        if [ -z "$STATUS" ]; then
            # Charge without status is not enough to claim online/mains.
            fail_count=$((fail_count + 1))
            if [ "$fail_count" -ge "$MAX_FAILURES" ]; then
                enter_failsafe "ups.status missing"
            fi
        else
            VOLTAGE_UV=
            if [[ "$VOLTAGE" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                VOLTAGE_UV=$(printf '%s\n' "$VOLTAGE * 1000000" | bc | cut -d. -f1)
                VOLTAGE_UV=$(clamp_nonneg_int "$(int_field "$VOLTAGE_UV")")
            fi

            # status: 0=discharging, 1=charging, 2=full, 3=not charging
            # NOCOMM = data path lost; do not keep reporting online/full.
            STATUS_VAL=3
            AC_STATUS=1
            if status_has OB "$STATUS" || status_has FSD "$STATUS" || \
               status_has OFF "$STATUS" || status_has NOCOMM "$STATUS"; then
                STATUS_VAL=0
                AC_STATUS=0
            elif status_has CHRG "$STATUS"; then
                STATUS_VAL=1
            elif [ -n "$BATTERY" ] && [ "$BATTERY" -ge 98 ] 2>/dev/null; then
                STATUS_VAL=2
            else
                STATUS_VAL=3
            fi

            if {
                [ -n "$BATTERY" ] && echo "capacity=$BATTERY"
                [ -n "$RUNTIME" ] && echo "time=$RUNTIME"
                [ -n "$VOLTAGE_UV" ] && echo "voltage=$VOLTAGE_UV"
                echo "status=$STATUS_VAL"
                echo "charging=$AC_STATUS"
            } | write_device; then
                if [ "$in_failsafe" -ne 0 ]; then
                    log "NUT connectivity restored for $UPS"
                    in_failsafe=0
                fi
                fail_count=0
            else
                # NUT looked fine but the control device write failed.
                fail_count=$((fail_count + 1))
                if [ "$fail_count" -ge "$MAX_FAILURES" ]; then
                    enter_failsafe "control device write failed"
                fi
            fi
        fi
    else
        fail_count=$((fail_count + 1))
        if [ "$fail_count" -ge "$MAX_FAILURES" ]; then
            enter_failsafe "NUT unreachable"
        fi
    fi

    sleep 2
done

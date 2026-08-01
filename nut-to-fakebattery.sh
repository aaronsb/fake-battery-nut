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

# Write a control payload to the device. Pass -q to skip failure logging
# (used for best-effort identity updates on older modules).
write_device() {
    local data
    local quiet=0

    if [ "${1:-}" = "-q" ]; then
        quiet=1
        shift
    fi

    # Slurp stdin, then one open/write so the whole update is one payload.
    # Suppress bash's "printf: write error" — we log failures ourselves.
    data=$(cat) || return 1
    if ! { printf '%s' "$data" > "$DEVICE"; } 2>/dev/null; then
        [ "$quiet" -eq 0 ] && log "Failed to write to $DEVICE"
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

# First non-empty nut_get among the given keys (prefer earlier keys).
nut_get_first() {
    local key val
    for key in "$@"; do
        val=$(nut_get "$key")
        if [ -n "$val" ]; then
            printf '%s' "$val"
            return 0
        fi
    done
    return 1
}

# Printable ASCII only, max 63 chars — matches kernel string prop limits.
sanitize_string_prop() {
    local raw="$1"
    local cleaned

    cleaned=$(printf '%s' "$raw" | tr -cd '[:print:]')
    cleaned="${cleaned#"${cleaned%%[![:space:]]*}"}"
    cleaned="${cleaned%"${cleaned##*[![:space:]]}"}"
    if [ -z "$cleaned" ]; then
        return 1
    fi
    printf '%s' "${cleaned:0:63}"
}

# Map NUT battery.type to POWER_SUPPLY_TECHNOLOGY_* enum values.
# PbAc (lead-acid) has no kernel enum → Unknown (0).
map_technology() {
    local t
    t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$t" in
        pbac|leadacid|lead-acid|"lead acid") printf '0' ;;  # UNKNOWN
        nimh) printf '1' ;;
        li|lion|li-ion|liion|lithium*|lithium-ion) printf '2' ;;  # LION
        lipo|li-po|lipolymer|li-polymer) printf '3' ;;  # LIPO
        life|lifepo4|li-fe|lithium-iron*) printf '4' ;;  # LiFe
        nicd|ni-cd) printf '5' ;;
        limn|li-mn) printf '6' ;;
        *) return 1 ;;
    esac
}

# Map ups.status tokens to POWER_SUPPLY_HEALTH_*.
# Default GOOD when no fault tokens are present.
map_health() {
    local st="$1"

    if status_has RB "$st"; then
        printf '3'   # DEAD — replace battery
    elif status_has OVER "$st"; then
        printf '8'   # OVERCURRENT — overload
    elif status_has CAL "$st"; then
        printf '9'   # CALIBRATION_REQUIRED
    else
        printf '1'   # GOOD
    fi
}

# Convert a NUT voltage/float string to microvolts (integer), or empty.
volts_to_uv() {
    local raw="$1"
    local uv

    if [[ ! "$raw" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        return 1
    fi
    uv=$(printf '%s\n' "$raw * 1000000" | bc | cut -d. -f1)
    clamp_nonneg_int "$(int_field "$uv")"
}

# Approximate load power in microwatts: load% * realpower.nominal * 1e4.
# Empty if either input is missing/unusable.
power_now_uw() {
    local load="$1"
    local nominal_w="$2"
    local uw

    load=$(int_field "$load")
    nominal_w=$(int_field "$nominal_w")
    [ -n "$load" ] && [ -n "$nominal_w" ] || return 1
    [ "$load" -ge 0 ] 2>/dev/null && [ "$load" -le 100 ] 2>/dev/null || return 1

    uw=$(printf '%s\n' "$load * $nominal_w * 10000" | bc | cut -d. -f1)
    clamp_nonneg_int "$(int_field "$uw")"
}

# Parse NUT date (YYYY/MM/DD or YYYY-MM-DD) into year month day on stdout.
# Prints nothing and fails if unusable (caller keeps kernel defaults).
parse_mfr_date() {
    local raw="$1"
    local y m d

    raw=$(printf '%s' "$raw" | tr -cd '0-9/-')
    if [[ "$raw" =~ ^([0-9]{4})[/-]([0-9]{1,2})[/-]([0-9]{1,2})$ ]]; then
        y="${BASH_REMATCH[1]}"
        m="${BASH_REMATCH[2]}"
        d="${BASH_REMATCH[3]}"
        # Strip leading zeros for decimal arithmetic safety.
        m=$((10#$m))
        d=$((10#$d))
        if [ "$y" -ge 1980 ] 2>/dev/null && [ "$y" -le 9999 ] 2>/dev/null && \
           [ "$m" -ge 1 ] 2>/dev/null && [ "$m" -le 12 ] 2>/dev/null && \
           [ "$d" -ge 1 ] 2>/dev/null && [ "$d" -le 31 ] 2>/dev/null; then
            printf '%s %s %s' "$y" "$m" "$d"
            return 0
        fi
    fi
    return 1
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
            VOLTAGE_UV=$(volts_to_uv "$VOLTAGE" || true)
            VOLTAGE_MAX_UV=$(volts_to_uv "$(nut_get battery.voltage.nominal)" || true)
            VOLTAGE_MIN_UV=$(volts_to_uv "$(nut_get_first battery.voltage.low battery.voltage.minimum)" || true)
            AC_VOLTAGE_UV=$(volts_to_uv "$(nut_get input.voltage)" || true)
            ALERT_MIN=$(clamp_capacity "$(int_field "$(nut_get battery.charge.low)")")
            POWER_NOW=$(power_now_uw "$(nut_get ups.load)" "$(nut_get ups.realpower.nominal)" || true)

            MANUFACTURER=$(sanitize_string_prop "$(nut_get_first device.mfr ups.mfr)" || true)
            MODEL=$(sanitize_string_prop "$(nut_get_first device.model ups.model)" || true)
            SERIAL=$(sanitize_string_prop "$(nut_get_first device.serial ups.serial)" || true)
            TECHNOLOGY=$(map_technology "$(nut_get battery.type)" || true)
            HEALTH=$(map_health "$STATUS")

            MFR_YEAR= MFR_MONTH= MFR_DAY=
            if MFR_DATE=$(parse_mfr_date "$(nut_get_first battery.mfr.date ups.mfr.date)"); then
                read -r MFR_YEAR MFR_MONTH MFR_DAY <<< "$MFR_DATE"
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

            # Optional / identity fields in a separate quiet write: older modules
            # reject unknown keys with EINVAL and would abort a combined payload.
            if [ -n "${MANUFACTURER}${MODEL}${SERIAL}${TECHNOLOGY}${HEALTH}${ALERT_MIN}${POWER_NOW}${VOLTAGE_MAX_UV}${VOLTAGE_MIN_UV}${AC_VOLTAGE_UV}${MFR_YEAR}" ]; then
                {
                    [ -n "$MANUFACTURER" ] && echo "manufacturer=$MANUFACTURER"
                    [ -n "$MODEL" ] && echo "model=$MODEL"
                    [ -n "$SERIAL" ] && echo "serial=$SERIAL"
                    [ -n "$TECHNOLOGY" ] && echo "technology=$TECHNOLOGY"
                    [ -n "$HEALTH" ] && echo "health=$HEALTH"
                    [ -n "$ALERT_MIN" ] && echo "capacity_alert_min=$ALERT_MIN"
                    [ -n "$POWER_NOW" ] && echo "power_now=$POWER_NOW"
                    [ -n "$VOLTAGE_MAX_UV" ] && echo "voltage_max_design=$VOLTAGE_MAX_UV"
                    [ -n "$VOLTAGE_MIN_UV" ] && echo "voltage_min_design=$VOLTAGE_MIN_UV"
                    [ -n "$AC_VOLTAGE_UV" ] && echo "ac_voltage=$AC_VOLTAGE_UV"
                    [ -n "$MFR_YEAR" ] && echo "manufacture_year=$MFR_YEAR"
                    [ -n "$MFR_MONTH" ] && echo "manufacture_month=$MFR_MONTH"
                    [ -n "$MFR_DAY" ] && echo "manufacture_day=$MFR_DAY"
                } | write_device -q || true
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

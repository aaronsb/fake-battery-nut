/*
 * fake_battery_nut - Kernel module to expose NUT UPS data as power_supply
 *
 * Based on linux-fake-battery-module by Rob Hoelz
 * Modified to support NUT (Network UPS Tools) data passthrough
 *
 * Control interface: /dev/fake_battery_nut
 * Commands:
 *   capacity=N            - Set battery capacity (0-100) - maps to UPS battery charge
 *   time=N                - Set time_to_empty in seconds - maps to UPS runtime
 *   voltage=N             - Set voltage in microvolts
 *   voltage_max_design=N  - Set design max voltage in microvolts
 *   voltage_min_design=N  - Set design min voltage in microvolts
 *   temp=N                - Set temperature in tenths of °C (e.g., 260 = 26.0°C)
 *   status=N              - Set status (0=discharging, 1=charging, 2=full, 3=not charging)
 *   charging=N            - Set AC online status (0=offline, 1=online)
 *   ac_voltage=N          - Set AC input voltage in microvolts
 *   manufacturer=S        - Set manufacturer string
 *   model=S               - Set model name string
 *   serial=S              - Set serial number string
 *   technology=N          - Set technology (0=Unknown .. 6=LiMn)
 *   health=N              - Set health (power_supply health enum)
 *   capacity_alert_min=N  - Set low-capacity alert threshold (0-100%)
 *   charge_full=N         - Set full/design charge in microamp-hours
 *   power_now=N           - Set instantaneous power in microwatts
 *   manufacture_year=N    - Set manufacture year (0=unknown)
 *   manufacture_month=N   - Set manufacture month (0=unknown, 1-12)
 *   manufacture_day=N     - Set manufacture day (0=unknown, 1-31)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 */

#include <linux/ctype.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/limits.h>
#include <linux/math64.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/power_supply.h>
#include <linux/string.h>
#include <linux/uaccess.h>

static int
fake_battery_get_property(struct power_supply *psy,
        enum power_supply_property psp,
        union power_supply_propval *val);

static int
fake_ac_get_property(struct power_supply *psy,
        enum power_supply_property psp,
        union power_supply_propval *val);

#define FAKE_STRING_PROP_LEN 64
/*
 * Default full charge in µAh (9 Ah). Typical for small consumer UPS packs;
 * override at runtime via charge_full= (daemon: BATTERY_CAPACITY_AH).
 */
#define FAKE_CHARGE_FULL_UAH_DEFAULT (9 * 1000000)

static struct battery_status {
    int status;
    int capacity_level;
    int capacity;
    int capacity_alert_min;
    int charge_full; /* µAh; design and current-full use the same value */
    int time_left;
    int voltage;
    int voltage_max_design;
    int voltage_min_design;
    int power_now;
    int temp;
    int technology;
    int health;
    int manufacture_year;
    int manufacture_month;
    int manufacture_day;
    char manufacturer[FAKE_STRING_PROP_LEN];
    char model_name[FAKE_STRING_PROP_LEN];
    char serial_number[FAKE_STRING_PROP_LEN];
} fake_battery_status = {
    .status = POWER_SUPPLY_STATUS_FULL,
    .capacity_level = POWER_SUPPLY_CAPACITY_LEVEL_FULL,
    .capacity = 100,
    .capacity_alert_min = 15,
    .charge_full = FAKE_CHARGE_FULL_UAH_DEFAULT,
    .time_left = 3600,
    .voltage = 24000000,            /* 24V in microvolts */
    .voltage_max_design = 24000000, /* match typical 24V UPS pack */
    /* Must be non-zero: UPower estimates Wh as charge*voltage_min_design,
     * so 0 here makes Capacity (battery health %) report as 0. */
    .voltage_min_design = 24000000,
    .power_now = 0,
    .temp = 260,                    /* 26.0°C in tenths */
    .technology = POWER_SUPPLY_TECHNOLOGY_LION,
    .health = POWER_SUPPLY_HEALTH_GOOD,
    .manufacture_year = 0,
    .manufacture_month = 0,
    .manufacture_day = 0,
    .manufacturer = "NUT",
    .model_name = "UPS Battery",
    .serial_number = "NUT-UPS",
};

static int ac_status = 1;
static int ac_voltage; /* µV; 0 = unknown */

static DEFINE_MUTEX(status_lock);

/* Overridable to avoid colliding with a real laptop BAT0/AC0 */
#define FAKE_PSY_NAME_LEN 32
static char battery_name[FAKE_PSY_NAME_LEN] = "BAT0";
static char ac_name[FAKE_PSY_NAME_LEN] = "AC0";

module_param_string(battery_name, battery_name, sizeof(battery_name), 0444);
MODULE_PARM_DESC(battery_name,
                 "power_supply name for the UPS battery (default: BAT0)");
module_param_string(ac_name, ac_name, sizeof(ac_name), 0444);
MODULE_PARM_DESC(ac_name,
                 "power_supply name for AC/mains (default: AC0)");

static char *fake_ac_supplies[] = {
    battery_name,
};

static enum power_supply_property fake_battery_properties[] = {
    POWER_SUPPLY_PROP_STATUS,
    POWER_SUPPLY_PROP_CHARGE_TYPE,
    POWER_SUPPLY_PROP_HEALTH,
    POWER_SUPPLY_PROP_PRESENT,
    POWER_SUPPLY_PROP_TECHNOLOGY,
    POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN,
    POWER_SUPPLY_PROP_CHARGE_FULL,
    POWER_SUPPLY_PROP_CHARGE_NOW,
    POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN,
    POWER_SUPPLY_PROP_ENERGY_FULL,
    POWER_SUPPLY_PROP_ENERGY_NOW,
    POWER_SUPPLY_PROP_CAPACITY,
    POWER_SUPPLY_PROP_CAPACITY_LEVEL,
    POWER_SUPPLY_PROP_CAPACITY_ALERT_MIN,
    POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG,
    POWER_SUPPLY_PROP_TIME_TO_FULL_NOW,
    POWER_SUPPLY_PROP_MODEL_NAME,
    POWER_SUPPLY_PROP_MANUFACTURER,
    POWER_SUPPLY_PROP_SERIAL_NUMBER,
    POWER_SUPPLY_PROP_TEMP,
    POWER_SUPPLY_PROP_VOLTAGE_NOW,
    POWER_SUPPLY_PROP_VOLTAGE_MAX_DESIGN,
    POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN,
    POWER_SUPPLY_PROP_POWER_NOW,
    POWER_SUPPLY_PROP_MANUFACTURE_YEAR,
    POWER_SUPPLY_PROP_MANUFACTURE_MONTH,
    POWER_SUPPLY_PROP_MANUFACTURE_DAY,
    POWER_SUPPLY_PROP_SCOPE,
};

static enum power_supply_property fake_ac_properties[] = {
    POWER_SUPPLY_PROP_ONLINE,
    POWER_SUPPLY_PROP_VOLTAGE_NOW,
};

static struct power_supply_desc descriptions[] = {
    {
        .name = battery_name,
        .type = POWER_SUPPLY_TYPE_BATTERY,
        .properties = fake_battery_properties,
        .num_properties = ARRAY_SIZE(fake_battery_properties),
        .get_property = fake_battery_get_property,
    },

    {
        .name = ac_name,
        .type = POWER_SUPPLY_TYPE_MAINS,
        .properties = fake_ac_properties,
        .num_properties = ARRAY_SIZE(fake_ac_properties),
        .get_property = fake_ac_get_property,
    },
};

static struct power_supply_config configs[] = {
    { },
    {
        .supplied_to = fake_ac_supplies,
        .num_supplicants = ARRAY_SIZE(fake_ac_supplies),
    },
};

static struct power_supply *supplies[sizeof(descriptions) / sizeof(descriptions[0])];

static void
notify_supplies(void)
{
    power_supply_changed(supplies[0]);
    power_supply_changed(supplies[1]);
}

static ssize_t
control_device_read(struct file *file, char *buffer, size_t count, loff_t *ppos)
{
    static char *message =
        "fake_battery_nut: capacity, time, voltage, voltage_max_design, "
        "voltage_min_design, temp, status, charging, ac_voltage, "
        "manufacturer, model, serial, technology, health, "
        "capacity_alert_min, charge_full, power_now, manufacture_year, "
        "manufacture_month, manufacture_day\n";
    size_t message_len = strlen(message);

    (void)file;

    if(count < message_len) {
        return -EINVAL;
    }

    if(*ppos != 0) {
        return 0;
    }

    if(copy_to_user(buffer, message, message_len)) {
        return -EFAULT;
    }

    *ppos = message_len;

    return message_len;
}

static bool
key_matches(const char *line, const char *eq, const char *key)
{
    size_t len = strlen(key);

    return (size_t)(eq - line) == len && !strncmp(line, key, len);
}

static bool
line_is_blank(const char *line)
{
    return *skip_spaces(line) == '\0';
}

static void
strip_trailing_cr(char *line)
{
    size_t len = strlen(line);

    if(len > 0 && line[len - 1] == '\r') {
        line[len - 1] = '\0';
    }
}

static int
set_string_prop(char *dest, size_t dest_size, const char *value)
{
    const char *end;
    size_t len;
    size_t i;

    value = skip_spaces(value);
    end = value + strlen(value);
    while(end > value && isspace((unsigned char)end[-1])) {
        end--;
    }
    len = end - value;
    if(len == 0 || len >= dest_size) {
        return -EINVAL;
    }
    for(i = 0; i < len; i++) {
        if(!isprint((unsigned char)value[i])) {
            return -EINVAL;
        }
    }
    memcpy(dest, value, len);
    dest[len] = '\0';
    return 0;
}

static int
parse_int_value(const char *value_p, long *value)
{
    const char *end;
    char number[32];
    size_t len;

    /* Reject trailing non-number junk (kstrtol is strict; trim spaces only). */
    end = value_p + strlen(value_p);
    while(end > value_p && isspace((unsigned char)end[-1])) {
        end--;
    }
    if(end == value_p) {
        return -EINVAL;
    }

    len = end - value_p;
    if(len >= sizeof(number)) {
        return -EINVAL;
    }
    memcpy(number, value_p, len);
    number[len] = '\0';
    return kstrtol(number, 10, value);
}

/* µWh = µAh * µV / 1e6; clamp to INT_MAX for power_supply intval. */
static int
charge_voltage_to_uwh(int charge_uah, int voltage_uv)
{
    u64 uwh;

    if(charge_uah <= 0 || voltage_uv <= 0) {
        return 0;
    }
    uwh = div_u64((u64)charge_uah * (u64)voltage_uv, 1000000ULL);
    if(uwh > (u64)INT_MAX) {
        return INT_MAX;
    }
    return (int)uwh;
}

static int
charge_now_uah(const struct battery_status *battery)
{
    return (int)div_u64((u64)battery->capacity * (u64)battery->charge_full, 100ULL);
}

static int
handle_control_line(const char *line, int *ac_online, int *ac_volt,
                    struct battery_status *battery)
{
    const char *eq;
    const char *value_p;
    long value;
    int ret;

    line = skip_spaces(line);

    eq = strchr(line, '=');
    if(!eq || eq == line) {
        return -EINVAL;
    }

    value_p = skip_spaces(eq + 1);

    /* String identity fields (fallback defaults remain until first valid set). */
    if(key_matches(line, eq, "manufacturer")) {
        return set_string_prop(battery->manufacturer,
                               sizeof(battery->manufacturer), value_p);
    }
    if(key_matches(line, eq, "model")) {
        return set_string_prop(battery->model_name,
                               sizeof(battery->model_name), value_p);
    }
    if(key_matches(line, eq, "serial")) {
        return set_string_prop(battery->serial_number,
                               sizeof(battery->serial_number), value_p);
    }

    ret = parse_int_value(value_p, &value);
    if(ret) {
        return ret;
    }

    if(key_matches(line, eq, "capacity")) {
        if(value < 0 || value > 100) {
            return -EINVAL;
        }
        battery->capacity = (int)value;
        /* Auto-update capacity_level based on capacity */
        if(value >= 98) {
            battery->capacity_level = POWER_SUPPLY_CAPACITY_LEVEL_FULL;
        } else if(value >= 70) {
            battery->capacity_level = POWER_SUPPLY_CAPACITY_LEVEL_HIGH;
        } else if(value >= 30) {
            battery->capacity_level = POWER_SUPPLY_CAPACITY_LEVEL_NORMAL;
        } else if(value >= 5) {
            battery->capacity_level = POWER_SUPPLY_CAPACITY_LEVEL_LOW;
        } else {
            battery->capacity_level = POWER_SUPPLY_CAPACITY_LEVEL_CRITICAL;
        }
    } else if(key_matches(line, eq, "capacity_alert_min")) {
        if(value < 0 || value > 100) {
            return -EINVAL;
        }
        battery->capacity_alert_min = (int)value;
    } else if(key_matches(line, eq, "charge_full")) {
        /* µAh; must yield >0.01 Wh at design voltage for UPower health. */
        if(value < 1 || value > INT_MAX) {
            return -EINVAL;
        }
        battery->charge_full = (int)value;
    } else if(key_matches(line, eq, "time")) {
        if(value < 0 || value > INT_MAX) {
            return -EINVAL;
        }
        battery->time_left = (int)value;
    } else if(key_matches(line, eq, "voltage")) {
        if(value < 0 || value > INT_MAX) {
            return -EINVAL;
        }
        battery->voltage = (int)value;
    } else if(key_matches(line, eq, "voltage_max_design")) {
        if(value < 0 || value > INT_MAX) {
            return -EINVAL;
        }
        battery->voltage_max_design = (int)value;
    } else if(key_matches(line, eq, "voltage_min_design")) {
        if(value < 0 || value > INT_MAX) {
            return -EINVAL;
        }
        battery->voltage_min_design = (int)value;
    } else if(key_matches(line, eq, "power_now")) {
        if(value < 0 || value > INT_MAX) {
            return -EINVAL;
        }
        battery->power_now = (int)value;
    } else if(key_matches(line, eq, "temp")) {
        /* Tenths of °C; allow a wide but finite sensor range */
        if(value < -400 || value > 2000) {
            return -EINVAL;
        }
        battery->temp = (int)value;
    } else if(key_matches(line, eq, "status")) {
        switch(value) {
            case 0:
                battery->status = POWER_SUPPLY_STATUS_DISCHARGING;
                break;
            case 1:
                battery->status = POWER_SUPPLY_STATUS_CHARGING;
                break;
            case 2:
                battery->status = POWER_SUPPLY_STATUS_FULL;
                break;
            case 3:
                battery->status = POWER_SUPPLY_STATUS_NOT_CHARGING;
                break;
            default:
                return -EINVAL;
        }
    } else if(key_matches(line, eq, "charging")) {
        if(value != 0 && value != 1) {
            return -EINVAL;
        }
        *ac_online = (int)value;
    } else if(key_matches(line, eq, "ac_voltage")) {
        if(value < 0 || value > INT_MAX) {
            return -EINVAL;
        }
        *ac_volt = (int)value;
    } else if(key_matches(line, eq, "technology")) {
        switch(value) {
            case POWER_SUPPLY_TECHNOLOGY_UNKNOWN:
            case POWER_SUPPLY_TECHNOLOGY_NiMH:
            case POWER_SUPPLY_TECHNOLOGY_LION:
            case POWER_SUPPLY_TECHNOLOGY_LIPO:
            case POWER_SUPPLY_TECHNOLOGY_LiFe:
            case POWER_SUPPLY_TECHNOLOGY_NiCd:
            case POWER_SUPPLY_TECHNOLOGY_LiMn:
                battery->technology = (int)value;
                break;
            default:
                return -EINVAL;
        }
    } else if(key_matches(line, eq, "health")) {
        switch(value) {
            case POWER_SUPPLY_HEALTH_UNKNOWN:
            case POWER_SUPPLY_HEALTH_GOOD:
            case POWER_SUPPLY_HEALTH_OVERHEAT:
            case POWER_SUPPLY_HEALTH_DEAD:
            case POWER_SUPPLY_HEALTH_OVERVOLTAGE:
            case POWER_SUPPLY_HEALTH_UNSPEC_FAILURE:
            case POWER_SUPPLY_HEALTH_COLD:
            case POWER_SUPPLY_HEALTH_WATCHDOG_TIMER_EXPIRE:
            case POWER_SUPPLY_HEALTH_SAFETY_TIMER_EXPIRE:
            case POWER_SUPPLY_HEALTH_OVERCURRENT:
            case POWER_SUPPLY_HEALTH_CALIBRATION_REQUIRED:
                battery->health = (int)value;
                break;
            default:
                return -EINVAL;
        }
    } else if(key_matches(line, eq, "manufacture_year")) {
        if(value < 0 || value > 9999) {
            return -EINVAL;
        }
        battery->manufacture_year = (int)value;
    } else if(key_matches(line, eq, "manufacture_month")) {
        if(value < 0 || value > 12) {
            return -EINVAL;
        }
        battery->manufacture_month = (int)value;
    } else if(key_matches(line, eq, "manufacture_day")) {
        if(value < 0 || value > 31) {
            return -EINVAL;
        }
        battery->manufacture_day = (int)value;
    } else {
        return -EINVAL;
    }

    return 0;
}

static ssize_t
control_device_write(struct file *file, const char *buffer, size_t count, loff_t *ppos)
{
    char kbuffer[1024];
    char *buffer_cursor;
    char *newline;
    size_t bytes_left;
    int status;
    int updated = 0;

    (void)file;
    (void)ppos;

    if(count == 0) {
        return 0;
    }

    if(count >= sizeof(kbuffer)) {
        pr_err("fake_battery_nut: write too large (limit %zu bytes)\n",
               sizeof(kbuffer) - 1);
        return -EINVAL;
    }

    if(copy_from_user(kbuffer, buffer, count)) {
        pr_err("fake_battery_nut: bad copy_from_user\n");
        return -EFAULT;
    }
    kbuffer[count] = '\0';

    /* ppos is ignored: each write is an independent update fragment. */
    mutex_lock(&status_lock);

    buffer_cursor = kbuffer;
    bytes_left = count;

    while(bytes_left > 0) {
        newline = memchr(buffer_cursor, '\n', bytes_left);
        if(newline) {
            *newline = '\0';
            strip_trailing_cr(buffer_cursor);
            if(!line_is_blank(buffer_cursor)) {
                status = handle_control_line(buffer_cursor, &ac_status,
                                             &ac_voltage, &fake_battery_status);
                if(status) {
                    mutex_unlock(&status_lock);
                    if(updated) {
                        notify_supplies();
                    }
                    return status;
                }
                updated = 1;
            }
            bytes_left -= (newline - buffer_cursor) + 1;
            buffer_cursor = newline + 1;
        } else {
            /* Accept a final line without a trailing newline */
            strip_trailing_cr(buffer_cursor);
            if(!line_is_blank(buffer_cursor)) {
                status = handle_control_line(buffer_cursor, &ac_status,
                                             &ac_voltage, &fake_battery_status);
                if(status) {
                    mutex_unlock(&status_lock);
                    if(updated) {
                        notify_supplies();
                    }
                    return status;
                }
                updated = 1;
            }
            break;
        }
    }

    mutex_unlock(&status_lock);

    if(updated) {
        notify_supplies();
    }

    return count;
}

static const struct file_operations control_device_ops = {
    .owner = THIS_MODULE,
    .read = control_device_read,
    .write = control_device_write,
};

static struct miscdevice control_device = {
    MISC_DYNAMIC_MINOR,
    "fake_battery_nut",
    &control_device_ops,
};

static int
fake_battery_get_property(struct power_supply *psy,
        enum power_supply_property psp,
        union power_supply_propval *val)
{
    struct battery_status status;
    int ret = 0;

    mutex_lock(&status_lock);
    status = fake_battery_status;

    switch (psp) {
        case POWER_SUPPLY_PROP_MANUFACTURER:
            /* Persistent buffers; core sprintf()s immediately after return. */
            val->strval = fake_battery_status.manufacturer;
            break;
        case POWER_SUPPLY_PROP_MODEL_NAME:
            val->strval = fake_battery_status.model_name;
            break;
        case POWER_SUPPLY_PROP_SERIAL_NUMBER:
            val->strval = fake_battery_status.serial_number;
            break;
        case POWER_SUPPLY_PROP_STATUS:
            val->intval = status.status;
            break;
        case POWER_SUPPLY_PROP_CHARGE_TYPE:
            val->intval = POWER_SUPPLY_CHARGE_TYPE_FAST;
            break;
        case POWER_SUPPLY_PROP_HEALTH:
            val->intval = status.health;
            break;
        case POWER_SUPPLY_PROP_PRESENT:
            val->intval = 1;
            break;
        case POWER_SUPPLY_PROP_TECHNOLOGY:
            val->intval = status.technology;
            break;
        case POWER_SUPPLY_PROP_SCOPE:
            val->intval = POWER_SUPPLY_SCOPE_SYSTEM;
            break;
        case POWER_SUPPLY_PROP_CAPACITY_LEVEL:
            val->intval = status.capacity_level;
            break;
        case POWER_SUPPLY_PROP_CAPACITY:
            val->intval = status.capacity;
            break;
        case POWER_SUPPLY_PROP_CAPACITY_ALERT_MIN:
            val->intval = status.capacity_alert_min;
            break;
        case POWER_SUPPLY_PROP_CHARGE_NOW:
            val->intval = charge_now_uah(&status);
            break;
        case POWER_SUPPLY_PROP_CHARGE_FULL_DESIGN:
        case POWER_SUPPLY_PROP_CHARGE_FULL:
            val->intval = status.charge_full;
            break;
        case POWER_SUPPLY_PROP_ENERGY_NOW:
            val->intval = charge_voltage_to_uwh(charge_now_uah(&status),
                                               status.voltage_max_design);
            break;
        case POWER_SUPPLY_PROP_ENERGY_FULL_DESIGN:
        case POWER_SUPPLY_PROP_ENERGY_FULL:
            /* Prefer ENERGY_* so UPower Capacity/health bypasses charge quirks. */
            val->intval = charge_voltage_to_uwh(status.charge_full,
                                               status.voltage_max_design);
            break;
        case POWER_SUPPLY_PROP_TIME_TO_EMPTY_AVG:
            if(status.status == POWER_SUPPLY_STATUS_DISCHARGING) {
                val->intval = status.time_left;
            } else {
                val->intval = 0;
            }
            break;
        case POWER_SUPPLY_PROP_TIME_TO_FULL_NOW:
            if(status.status == POWER_SUPPLY_STATUS_CHARGING) {
                val->intval = status.time_left;
            } else {
                val->intval = 0;
            }
            break;
        case POWER_SUPPLY_PROP_TEMP:
            val->intval = status.temp;
            break;
        case POWER_SUPPLY_PROP_VOLTAGE_NOW:
            val->intval = status.voltage;
            break;
        case POWER_SUPPLY_PROP_VOLTAGE_MAX_DESIGN:
            val->intval = status.voltage_max_design;
            break;
        case POWER_SUPPLY_PROP_VOLTAGE_MIN_DESIGN:
            /* Never expose 0 — see voltage_min_design default comment. */
            val->intval = status.voltage_min_design
                    ? status.voltage_min_design
                    : status.voltage_max_design;
            break;
        case POWER_SUPPLY_PROP_POWER_NOW:
            val->intval = status.power_now;
            break;
        case POWER_SUPPLY_PROP_MANUFACTURE_YEAR:
            val->intval = status.manufacture_year;
            break;
        case POWER_SUPPLY_PROP_MANUFACTURE_MONTH:
            val->intval = status.manufacture_month;
            break;
        case POWER_SUPPLY_PROP_MANUFACTURE_DAY:
            val->intval = status.manufacture_day;
            break;
        default:
            ret = -EINVAL;
            break;
    }
    mutex_unlock(&status_lock);
    return ret;
}

static int
fake_ac_get_property(struct power_supply *psy,
        enum power_supply_property psp,
        union power_supply_propval *val)
{
    int online;
    int voltage;

    switch (psp) {
    case POWER_SUPPLY_PROP_ONLINE:
            mutex_lock(&status_lock);
            online = ac_status;
            mutex_unlock(&status_lock);
            val->intval = online;
            break;
    case POWER_SUPPLY_PROP_VOLTAGE_NOW:
            mutex_lock(&status_lock);
            voltage = ac_voltage;
            mutex_unlock(&status_lock);
            val->intval = voltage;
            break;
    default:
            return -EINVAL;
    }
    return 0;
}

static int
valid_psy_name(const char *name)
{
    const char *p;

    if(!isalnum((unsigned char)name[0])) {
        return 0;
    }

    for(p = name + 1; *p; p++) {
        if(!isalnum((unsigned char)*p) && *p != '_' && *p != '-') {
            return 0;
        }
    }
    return 1;
}

static int __init
fake_battery_nut_init(void)
{
    int result;
    int i;

    if(!battery_name[0] || !ac_name[0]) {
        pr_err("fake_battery_nut: battery_name and ac_name must be non-empty\n");
        return -EINVAL;
    }
    if(!strcmp(battery_name, ac_name)) {
        pr_err("fake_battery_nut: battery_name and ac_name must differ\n");
        return -EINVAL;
    }
    if(!valid_psy_name(battery_name) || !valid_psy_name(ac_name)) {
        pr_err("fake_battery_nut: supply names must be alphanumeric/[_-]\n");
        return -EINVAL;
    }

    /*
     * Register power supplies before the control device so a concurrent
     * write cannot call power_supply_changed() on a NULL supply pointer.
     */
    for(i = 0; i < ARRAY_SIZE(descriptions); i++) {
        supplies[i] = power_supply_register(NULL, &descriptions[i], &configs[i]);
        if(IS_ERR(supplies[i])) {
            result = PTR_ERR(supplies[i]);
            pr_err("fake_battery_nut: unable to register power supply %d\n", i);
            goto err_psy;
        }
    }

    result = misc_register(&control_device);
    if(result) {
        pr_err("fake_battery_nut: unable to register misc device\n");
        i = ARRAY_SIZE(descriptions);
        goto err_psy;
    }

    pr_info("fake_battery_nut: loaded (%s + %s)\n", battery_name, ac_name);
    return 0;

err_psy:
    while(--i >= 0) {
        power_supply_unregister(supplies[i]);
    }
    return result;
}

static void __exit
fake_battery_nut_exit(void)
{
    int i;

    misc_deregister(&control_device);

    for(i = ARRAY_SIZE(descriptions) - 1; i >= 0; i--) {
        power_supply_unregister(supplies[i]);
    }

    pr_info("fake_battery_nut: unloaded\n");
}

module_init(fake_battery_nut_init);
module_exit(fake_battery_nut_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("NUT UPS to Linux power_supply bridge");
MODULE_AUTHOR("Based on linux-fake-battery-module by Rob Hoelz");

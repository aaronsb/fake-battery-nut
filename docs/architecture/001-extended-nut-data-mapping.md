# ADR-001: Extended NUT Data Mapping

## Status

Proposed

## Context

The `fake_battery_nut` kernel module currently exposes a subset of NUT UPS data through the Linux power_supply subsystem. While the basic mapping works (capacity, time, voltage, status), NUT provides significantly more data that could be valuable for monitoring.

### Current Data Flow

```
NUT UPS Data → upsc → nut-to-fakebattery daemon → /dev/fake_battery_nut → kernel module → /sys/class/power_supply/
```

### Currently Mapped

| NUT Field | Kernel Module | power_supply Property |
|-----------|---------------|----------------------|
| battery.charge | capacity0 | BAT0/capacity |
| ups.load | capacity1 | BAT1/capacity |
| battery.runtime | time0 | BAT0/time_to_empty_avg |
| battery.voltage | voltage0 | BAT0/voltage_now |
| input.voltage | voltage1 | BAT1/voltage_now |
| ups.status (OL/OB) | status0, charging | BAT0/status, AC0/online |

### Available but Unmapped NUT Data

From a typical CyberPower UPS:

```
battery.charge.low: 10
battery.charge.warning: 20
battery.mfr.date: CPS
battery.runtime.low: 300
battery.type: PbAcid
battery.voltage.nominal: 24
input.sensitivity: normal
input.transfer.high: 139
input.transfer.low: 100
input.voltage.nominal: 120
output.voltage: 122.0
ups.beeper.status: enabled
ups.delay.shutdown: 60
ups.delay.start: 120
ups.firmware: BF01403CA
ups.mfr: CPS
ups.model: CST135XLU
ups.power.nominal: 1350
ups.realpower.nominal: 810
ups.serial: CR7KS2003692
ups.test.result: No test initiated
```

## Decision Drivers

1. **Monitoring completeness** - More data enables better dashboards and alerting
2. **power_supply API constraints** - Limited to properties the kernel API supports
3. **Complexity vs utility** - More control commands = more daemon complexity
4. **btop limitations** - btop only shows capacity, time, status anyway

## Options Considered

### Option A: Minimal Extension (Recommended)

Add only high-value fields that map cleanly to power_supply properties:

| NUT Field | Control Command | power_supply Property |
|-----------|-----------------|----------------------|
| battery.charge.low | lowbat0=N | BAT0/charge_control_end_threshold |
| output.voltage | - | Already via voltage1 |
| ups.temperature | temp0=N | BAT0/temp |

**Pros:**
- Low complexity
- Maps to existing kernel properties
- Minimal daemon changes

**Cons:**
- Leaves most NUT data unmapped

### Option B: Sysfs Extension

Add custom sysfs attributes beyond standard power_supply:

```
/sys/class/power_supply/BAT0/
├── capacity          (standard)
├── nut_model         (custom)
├── nut_serial        (custom)
├── nut_load_watts    (custom)
├── nut_input_voltage (custom)
└── ...
```

**Pros:**
- Can expose any NUT data
- Queryable by any tool

**Cons:**
- Non-standard attributes may confuse tools
- More kernel code complexity
- May not integrate with existing monitors

### Option C: Companion Daemon with JSON/Socket

Keep kernel module minimal, add a companion that serves full NUT data:

```
/run/fake-battery-nut/status.json
```

Or a Unix socket that tools can query.

**Pros:**
- Full data access
- No kernel complexity
- Easier to update

**Cons:**
- Doesn't help btop (the original goal)
- Another daemon to maintain

### Option D: Temperature Focus

NUT reports no temperature, but the kernel module has a temp field (currently hardcoded to 26°C). We could:

1. Add ambient temperature from system sensors
2. Leave as placeholder
3. Remove the property

## Proposed Decision

**Option A: Minimal Extension** with the following additions:

1. **Temperature** - Allow setting via `temp0=N` (in tenths of °C)
   - Daemon could read from system sensors if desired

2. **Model/Manufacturer strings** - Already in module, could make dynamic via:
   - `model0=UPS Model Name`
   - `mfr0=CyberPower`

3. **Consider BAT1 repurposing** - Currently shows "load %" as capacity, which is semantically wrong. Options:
   - Keep as-is (works, just weird)
   - Rename model to "UPS Load Meter" (done)
   - Remove BAT1, use only BAT0

## Consequences

### If Accepted

- Kernel module gains 2-3 new control commands
- Daemon script needs corresponding NUT field extraction
- Documentation update required
- Version bump to 1.1.0

### If Rejected

- Current implementation is functional
- btop shows what it can show (capacity %)
- Advanced users can query NUT directly

## Notes

The irony of this project should be preserved: we wrote a kernel module because btop doesn't have plugins, and btop only displays `BAT= 100%` anyway. Any extensions should be evaluated against "does btop even show this?"

## References

- [Linux power_supply class documentation](https://www.kernel.org/doc/html/latest/power/power_supply_class.html)
- [NUT variable naming](https://networkupstools.org/docs/developer-guide.chunked/apas01.html)
- Project README "The Duality of Engineering" section

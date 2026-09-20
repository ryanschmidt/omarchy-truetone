# True Tone for Omarchy

Matches your display's white point to the colour of the light in your room, using
your laptop's ambient **colour** sensor. This is the Linux equivalent of Apple's
True Tone.

It is not a blue light filter and not a night mode. Omarchy already ships that.

| | Input | Behaviour |
|---|---|---|
| **Night Light** (built in) | Clock | Warms the screen on a schedule |
| **True Tone** (this) | Ambient light **colour** | Matches the screen to the room, any time of day |

Warm room at noon, the screen warms. Cool room at midnight, it stays neutral.
Your eyes already do this to a sheet of paper. This does it to your panel.

## Does my laptop support this?

Most laptops have an ambient light sensor that reports **brightness only**. That is
enough for auto-brightness and not enough for this. You need a sensor that reports
colour.

```bash
for d in /sys/bus/iio/devices/iio:device*; do
  [ "$(cat $d/name 2>/dev/null)" = als ] || continue
  [ -r "$d/in_colortemp_raw" ] && echo "$d  SUPPORTED" || echo "$d  brightness only"
done
```

If nothing prints `SUPPORTED`, this plugin will install and tell you politely that
your hardware cannot do it. Known good: Dell XPS 14 (9450, Panther Lake).

### Watch it work

```bash
d=/sys/bus/iio/devices/iio:device2   # whichever printed SUPPORTED
watch -n1 "echo \$((\$(cat $d/in_colortemp_raw)/1000))K \$((\$(cat $d/in_illuminance_raw)/1000))lux"
```

Shine a phone torch at the top bezel. On a real colour sensor the Kelvin figure
climbs toward 5000. If it does not move while lux climbs, the value is derived
from brightness and this plugin cannot help you.

## Install

```bash
omarchy plugin add https://github.com/ryanschmidt/omarchy-truetone --enable
omarchy restart shell
```

Add the bar widget from **Omarchy menu → Bar → Add widget → True Tone**, or run the
service headless without the widget.

The bar shows a plain white icon, dimmed when inactive. Click it to open the panel,
which carries the live sensor readings, the on/off toggle, and the settings. Right
click the icon to toggle without opening the panel.

```bash
omarchy-shell truetone status     # what it sees right now
omarchy-shell truetone toggle
```

## How it decides

Three things matter, and all three are why the screen does not look absurd in a
dim room:

**Partial adaptation.** It moves the display *partway* toward the room, not all the
way. Your visual system is already adapting; the panel only closes part of the gap.
Full adaptation to a 2000 K lamp would look alarmingly orange. Default `strength`
is 0.5.

**Clamping.** Never warmer than `minKelvin` (3800 by default), never cooler than
6500 K, because above neutral hyprsunset tints the panel blue.

**A low light floor.** Below a few lux a colour sensor has too few photons to
report a meaningful colour, so it holds the last good value instead of lurching.

Changes ramp at 150 K per tick rather than jumping, because a step change in white
point is very visible in peripheral vision.

## Cost

This runs forever on a laptop, so it is built not to cost anything.

- **sysfs is read in process**, through Quickshell's `FileView`. No subprocess, no
  fork, microseconds per read.
- **No shell in the steady state.** A `bash -lc` spawn costs roughly 20 ms of CPU,
  mostly sourcing your login profile. Shells run only at startup (sensor scan,
  config load, state restore, and starting hyprsunset if it is not up) and when
  settings or the enable state are written.
- **Polling backs off.** Room lighting changes over minutes, so a fixed fast poll
  spends its whole budget confirming that nothing happened. It samples every 2 s
  while something is moving and every 20 s once settled. A change is picked up on
  the next poll, so up to 20 s later, not instantly.
- **One `hyprctl` probe per tick**, measured at 2.6 ms. An earlier version skipped
  most of them to save subprocesses; that bought nothing measurable and left a
  window in which Night Light could take the display unnoticed.

Measured on a Dell XPS 14, settled: the entire `omarchy-shell` process, bar and
clock and notifications included, uses **0.10% of one core**.

## Configuration

Optional. Create `~/.config/omarchy/truetone.conf`:

```ini
# How far to move toward the room, 0 to 1. Lower is subtler.
strength = 0.5

# Warmest the display may go.
minKelvin = 3800

# Coolest. Above 6500 tints the panel blue, so it is capped there.
maxKelvin = 6500

# Below this many lux, hold rather than sample.
luxFloor = 3

# Kelvin per tick while ramping.
maxStepK = 150

# Seconds between sensor reads while something is changing.
pollIntervalSec = 2
```

`idleIntervalSec` (20) is the relaxed cadence once settled and is not currently
exposed in the file; raise `pollIntervalSec` if you want the active cadence slower.

Values are clamped on load, so a typo degrades rather than breaking your display.
Restart the shell to apply.

## Sharing the display with Night Light

Both this and Omarchy's Night Light drive the same hyprsunset temperature. There is
no lock, so ownership is decided by observation: True Tone writes only while the
display shows what it last put there, or while it sits at neutral and is free.
Anything else means someone took it and True Tone stands down.

```bash
omarchy-shell truetone status    # includes yielded / active
omarchy-shell truetone adopt     # take the display back explicitly
```

Verified behaviour: with True Tone settled, enabling Night Light makes it yield and
hold at 4000 K indefinitely without fighting, and disabling Night Light makes it
resume. Disabling True Tone while Night Light owns the display leaves Night Light
alone rather than resetting to neutral.

**Two limits worth knowing.**

Ownership is re-checked on the poll, so while True Tone is actively ramping (about
30 s after a lighting change) it writes every 2 s and can win a race against a
Night Light toggle made in that window. Settled, which is almost all the time, it
yields correctly.

If something parks the display warm and never releases it, True Tone stays paused
by design. `truetone adopt`, or toggling it off and on, claims the display back.
Startup is deliberately conservative here and will not seize a warm display it did
not set.

## Known issue: the Night Light toggle inverts while this is running

Omarchy decides whether Night Light is on by reading the current hyprsunset
temperature and asking whether it is below 6000 K. True Tone legitimately sets
temperatures below 6000 K, so while it is adapting, Omarchy believes Night Light is
already on.

The consequence: pressing the Night Light toggle (bar indicator or
`omarchy toggle nightlight`) does the opposite of what you expect.

Explicit control is unaffected and works correctly:

```bash
omarchy-shell nightlight enable    # True Tone yields, holds at 4000 K
omarchy-shell nightlight disable   # True Tone resumes
```

True Tone itself handles this correctly, as described above. What is confused is
Night Light's own view of whether it is on.

This is an upstream design collision rather than something this plugin can fix on
its own: any plugin that drives hyprsunset hits it. Two candidate fixes upstream
are for Night Light to track its own state explicitly rather than deriving it from
temperature, or for the shell to arbitrate a single owner of the colour transform.

## Why another ALS plugin

There are several auto-brightness plugins for Omarchy. They all adjust
**brightness**. This one adjusts **colour**, which needs a different sensor channel
that most of them never look for.

The one existing plugin that does read the colour channel selects the first IIO
device named `als` and stops. Machines with two sensors, including the XPS 14, list
the brightness-only sensor first, so adaptive colour silently never engages on
exactly the hardware that supports it. This plugin picks the sensor that actually
has a colour channel.

## Development

```bash
node test-model.js
```

All decision logic lives in `TrueToneModel.js` as plain JavaScript with no QML
imports, so it runs under node. `Service.qml` does I/O and owns the loop;
`Panel.qml` is display only and binds to the service. Adding a behaviour means
adding a case to the model and a test next to it.

## Licence

MIT

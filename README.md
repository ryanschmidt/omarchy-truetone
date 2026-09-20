# True Tone for Omarchy

Automatically adapts the display so colours look consistent in different ambient
lighting, using your laptop's ambient **colour** sensor. The Linux equivalent of
Apple's True Tone.

It is on or off. There are no settings, for the same reason there are none on a
Mac: it has one job, and Night Light already owns the Kelvin slider.

## What it is, and what it is not

| | Input | Behaviour |
|---|---|---|
| **Night Light** (built in) | Clock | Warms the screen on a schedule |
| **True Tone** (this) | Ambient light **colour** | Matches the display's white point to the room |

Warm room at noon, the display warms. Cool room at midnight, it stays neutral.
Your eyes already do this to a sheet of paper; this does it to your panel.

**The two are independent and both can be on**, exactly as on a Mac. True Tone
sets the baseline white point and Night Light layers its warmth on top. Neither
knows the other exists, because they drive different channels:

```
Night Light  →  colour transform matrix   (hyprland-ctm-control-v1)
True Tone    →  gamma ramp                (wlr-gamma-control-unstable-v1)
                      ↓
            composed by the compositor
```

That split is the whole design. An earlier version drove hyprsunset's
temperature, the same single number Night Light owns, and the two fought over
it: Omarchy infers whether Night Light is on by reading that number, so a warm
display made the Night Light indicator light up on its own and its toggle
invert. Nothing here touches that number any more.

## Does my laptop support this?

Most laptops have an ambient light sensor that reports **brightness only**. That
is enough for auto-brightness and not enough for this. You need one that also
reports colour.

```bash
for d in /sys/bus/iio/devices/iio:device*; do
  [ "$(cat $d/name 2>/dev/null)" = als ] || continue
  [ -r "$d/in_colortemp_raw" ] && echo "$d  SUPPORTED" || echo "$d  brightness only"
done
```

If nothing prints `SUPPORTED`, the plugin installs and says so in its panel
rather than pretending to work. Known good: Dell XPS 14 (Panther Lake).

### Confirm the sensor really measures colour

Some sensors expose a colour temperature that is derived from brightness rather
than measured. Watch the reading and shine a phone torch at the top bezel:

```bash
d=/sys/bus/iio/devices/iio:device2   # whichever printed SUPPORTED
watch -n1 "echo \$((\$(cat $d/in_colortemp_raw)/1000))K \$((\$(cat $d/in_illuminance_raw)/1000))lux"
```

On a real colour sensor the Kelvin figure climbs toward 5000 and then **plateaus
while lux keeps rising**. If Kelvin tracks lux all the way up, it is derived, and
this plugin cannot help you.

## Install

```bash
omarchy plugin add https://github.com/ryanschmidt/omarchy-truetone --enable
omarchy restart shell
```

Then add the widget from **Omarchy menu → Bar → Add widget → True Tone**, or run
the service headless without it.

The bar shows a plain white icon, dimmed when inactive. Click it for the switch
and the live sensor reading; right click toggles without opening the panel.

```bash
omarchy-shell truetone status
omarchy-shell truetone toggle
```

### The helper is compiled on first run

Applying a gamma ramp needs a resident Wayland client, because the compositor
releases the ramp the moment its client disconnects. That client is
`truetone-gamma`, a small C program built automatically the first time the
service starts. It needs `gcc`, `wayland-scanner` and `pkg-config`, which any
Hyprland system already has. To build it by hand:

```bash
./build.sh
```

## How it decides

**Partial adaptation, calibrated against a Mac.** It moves the display *partway*
toward the room, not all the way: your visual system is already adapting, so the
panel only closes part of the gap. The strength is not a guess. A MacBook with
True Tone on was put beside this machine under the same lamp, both showing white,
and the value was swept until they matched. `calibrate.sh` reproduces that.

The resulting correction is small, and deliberately so. In a 2500 K evening room
it takes about 6% off green and 9% off blue; in daylight it does nothing at all,
because the correction scales with distance from D65 and neutral light is already
there.

**Measured chromaticity, not just temperature.** It interpolates in CIE xy from
D65 straight toward the colour the sensor actually measured, so an illuminant off
the blackbody curve is handled with no special case. This is what a colour sensor
buys you over a lux sensor: cheap LED and fluorescent lighting sits visibly off
that curve, and matching only its correlated temperature leaves the green or
magenta cast behind. Anchoring on D65 also means a neutral room gets exactly no
correction.

**A blue floor and no boosting.** A gamma ramp can only attenuate channels, so
the result is always a white-point shift and never a brightness change, and the
panel can never be tinted blue. A floor on the blue channel bounds how warm
candlelight can drive it.

**A low light floor.** Below a few lux a colour sensor has too few photons to
report a meaningful colour, so it holds the last good value instead of lurching.

Changes walk to their target rather than jumping, because a step change in white
point is very visible in peripheral vision.

## Cost

This runs forever on a laptop, so it is built not to cost anything.

- **sysfs is read in process** through Quickshell's `FileView`. No fork.
- **No shell in the steady state.** A `bash -lc` spawn costs roughly 20 ms of
  CPU, mostly sourcing your login profile. Shells run only at startup.
- **Polling backs off** from 2 s while something is moving to 20 s once settled,
  so a change is picked up within one poll rather than instantly.
- **The helper is idle between changes.** It waits on `inotify`, not a timer, and
  wakes only when the gains file is rewritten.

## Multiple monitors

The helper applies the ramp to every output and picks up monitors hotplugged
mid-session. The sensor is in the laptop lid, so an external display is corrected
for the same room light rather than for its own surroundings.

## Why another ALS plugin

There are several auto-brightness plugins for Omarchy. They all adjust
**brightness**. This one adjusts **colour**, which needs a different sensor
channel that most of them never look for.

The one existing plugin that does read the colour channel selects the first IIO
device named `als` and stops. Machines with two sensors, including the XPS 14,
list the brightness-only sensor first, so adaptive colour silently never engages
on exactly the hardware that supports it. This picks the sensor that actually has
a colour channel.

## Development

```bash
node test-model.js     # all decision logic, no QML needed
./build.sh             # the gamma helper
```

`TrueToneModel.js` holds every decision as plain JavaScript with no QML imports,
so it runs under node. `Service.qml` does I/O and owns the loop. `Panel.qml` is
display only. `truetone-gamma.c` does no colour science at all: it reads RGB
gains from a file and writes ramps. Adding a behaviour means adding a case to the
model and a test beside it.

## Licence

MIT

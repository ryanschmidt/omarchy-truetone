// Pure logic for True Tone. No QML, no I/O, so it runs under node for tests.
// Mirrors the shape of Omarchy's own NightlightModel.js.

// hyprsunset's identity point. Going above this tints the panel blue, which
// is never what ambient adaptation wants, so it doubles as our ceiling.
var NEUTRAL_K = 6500

var DEFAULTS = {
  // How far to move from neutral toward the room. Apple's True Tone is a
  // partial adaptation, not a match: your eye is already adapting, so the
  // display only closes part of the gap. Full adaptation to a 2000K lamp
  // would look alarmingly orange.
  strength: 0.5,
  minKelvin: 3800,
  maxKelvin: NEUTRAL_K,
  // Below this the color channel has too few photons to mean anything.
  // Measured on a Dell XPS 14: readings stay coherent down to ~7 lux.
  luxFloor: 3,
  // Sensor noise measured at roughly +/- 20K, so this mostly smooths real
  // transitions rather than jitter.
  emaAlpha: 0.3,
  // Don't bother hyprsunset for changes the eye cannot see.
  deadbandK: 25,
  // Per tick. At a 1s poll this crosses the full range in about 30s.
  maxStepK: 100
}

// ---------------------------------------------------------------------------
// Sensor discovery
// ---------------------------------------------------------------------------

// Emit one line per IIO device: path|name|hasColortemp|hasChromaticity|hasLux
// Kept as a single shell string because QML's Process wants argv, not a script.
function scanCommand() {
  return ["bash", "-lc",
    'for d in /sys/bus/iio/devices/iio:device*; do ' +
    '[ -r "$d/name" ] || continue; ' +
    'n=$(cat "$d/name" 2>/dev/null); ' +
    'c=0; x=0; l=0; ' +
    '[ -r "$d/in_colortemp_raw" ] && c=1; ' +
    '[ -r "$d/in_chromaticity_x_raw" ] && x=1; ' +
    '[ -r "$d/in_illuminance_raw" ] && l=1; ' +
    'echo "$d|$n|$c|$x|$l"; done'
  ]
}

function parseScan(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("|")
    if (parts.length < 5) continue
    out.push({
      path: parts[0],
      name: parts[1],
      hasColortemp: parts[2] === "1",
      hasChromaticity: parts[3] === "1",
      hasLux: parts[4] === "1"
    })
  }
  return out
}

// THE fix. Every other ALS consumer takes the first device named `als` and
// stops. A Dell XPS 14 has two: iio:device1 is lux-only and sorts first,
// iio:device2 carries the color channel. Taking the first one silently
// disables adaptive color on exactly the hardware that can do it.
function pickSensor(devices) {
  if (!devices || !devices.length) return null
  var lux = null
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    if (d.name !== "als") continue
    if (d.hasColortemp && d.hasLux) return d   // what we actually want
    if (d.hasLux && !lux) lux = d              // remembered only to explain why we can't run
  }
  return lux
}

// ---------------------------------------------------------------------------
// Sensor reading
// ---------------------------------------------------------------------------

function readCommand(path) {
  return ["bash", "-lc",
    'd=' + JSON.stringify(path) + '; ' +
    'echo "cct=$(cat $d/in_colortemp_raw 2>/dev/null)"; ' +
    'echo "cctscale=$(cat $d/in_colortemp_scale 2>/dev/null)"; ' +
    'echo "lux=$(cat $d/in_illuminance_raw 2>/dev/null)"; ' +
    'echo "luxscale=$(cat $d/in_illuminance_scale 2>/dev/null)"; ' +
    'echo "x=$(cat $d/in_chromaticity_x_raw 2>/dev/null)"; ' +
    'echo "y=$(cat $d/in_chromaticity_y_raw 2>/dev/null)"; ' +
    'echo "xyscale=$(cat $d/in_chromaticity_scale 2>/dev/null)"'
  ]
}

function parseReading(text) {
  var kv = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var eq = lines[i].indexOf("=")
    if (eq > 0) kv[lines[i].slice(0, eq)] = lines[i].slice(eq + 1)
  }
  var num = function (k) {
    var v = parseFloat(kv[k])
    return isFinite(v) ? v : null
  }
  var scale = function (k, fallback) {
    var v = parseFloat(kv[k])
    return isFinite(v) && v > 0 ? v : fallback
  }

  var cctRaw = num("cct")
  var luxRaw = num("lux")
  if (cctRaw === null || luxRaw === null) return null

  var xyScale = scale("xyscale", 0.001)
  return {
    cct: cctRaw * scale("cctscale", 0.001),
    lux: luxRaw * scale("luxscale", 0.001),
    x: num("x") === null ? null : num("x") * xyScale,
    y: num("y") === null ? null : num("y") * xyScale
  }
}

// ---------------------------------------------------------------------------
// Adaptation
// ---------------------------------------------------------------------------

function optionsWithDefaults(opts) {
  var o = {}
  for (var k in DEFAULTS) o[k] = DEFAULTS[k]
  if (opts) for (var j in opts) if (opts[j] !== undefined && opts[j] !== null) o[j] = opts[j]
  return o
}

function hasUsableLight(lux, opts) {
  var o = optionsWithDefaults(opts)
  return isFinite(lux) && lux >= o.luxFloor
}

// Partial chromatic adaptation, clamped. This is the whole feature in one line.
function adaptTarget(ambientK, opts) {
  var o = optionsWithDefaults(opts)
  if (!isFinite(ambientK) || ambientK <= 0) return null
  var target = NEUTRAL_K + o.strength * (ambientK - NEUTRAL_K)
  return Math.round(Math.max(o.minKelvin, Math.min(o.maxKelvin, target)))
}

function smooth(previous, sample, opts) {
  var o = optionsWithDefaults(opts)
  if (!isFinite(sample)) return previous
  if (!isFinite(previous) || previous === null) return sample
  return previous + o.emaAlpha * (sample - previous)
}

// Ramp instead of jumping. hyprsunset applies instantly and a step change in
// white point is very visible in peripheral vision.
function nextStep(currentK, targetK, opts) {
  var o = optionsWithDefaults(opts)
  if (!isFinite(targetK)) return null
  if (!isFinite(currentK) || currentK === null) return Math.round(targetK)
  var delta = targetK - currentK
  if (Math.abs(delta) <= o.deadbandK) return null
  var step = Math.max(-o.maxStepK, Math.min(o.maxStepK, delta))
  return Math.round(currentK + step)
}

// We only own the display while nothing else has touched it. If the applied
// temperature is not the one we last set, Night Light or the user took over,
// and we yield rather than fight them for the CTM.
function externallyChanged(appliedK, lastSetK, tolerance) {
  if (lastSetK === null || lastSetK === undefined) return false
  if (appliedK === null || appliedK === undefined) return false
  return Math.abs(appliedK - lastSetK) > (tolerance === undefined ? 60 : tolerance)
}

// ---------------------------------------------------------------------------
// Pacing
// ---------------------------------------------------------------------------

// Room lighting changes over minutes, not seconds, so a fixed fast poll spends
// almost all of its budget confirming that nothing happened. Poll fast only
// while something is actually moving.
var PACING = {
  fastIntervalSec: 2,     // converging, or the room is changing
  idleIntervalSec: 20,    // settled
  // A room reading wobbles by roughly +/- 20K at rest. Anything under this is
  // not the light changing, it is the sensor breathing.
  stableCctDeltaK: 40
}

function isSettled(state, opts) {
  if (!state) return false
  // Still ramping toward the target: stay fast.
  if (nextStep(state.appliedK, state.targetK, opts) !== null) return false
  // Reading is drifting: stay fast so we catch the change early.
  if (isFinite(state.previousCct) && isFinite(state.cct)) {
    if (Math.abs(state.cct - state.previousCct) > PACING.stableCctDeltaK) return false
  }
  return true
}

function pollIntervalFor(settled, fastSec, idleSec) {
  var fast = isFinite(fastSec) && fastSec > 0 ? fastSec : PACING.fastIntervalSec
  var idle = isFinite(idleSec) && idleSec > 0 ? idleSec : PACING.idleIntervalSec
  return settled ? Math.max(fast, idle) : fast
}

// The hyprctl probe is the only remaining subprocess in the steady state, and
// it exists solely to notice Night Light taking over. Once settled, checking
// that every tick is waste; a slower cadence still catches it promptly.
function shouldProbe(ticksSinceProbe, settled) {
  if (!settled) return true
  return ticksSinceProbe >= 3
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

// Hardware needs tuning a fixed model cannot see: panel white point, how warm
// a room the owner tolerates, how twitchy their lighting is. One KEY=VALUE
// file, same spelling as the defaults above.
function configPath() {
  return "~/.config/omarchy/truetone.conf"
}

function loadConfigCommand() {
  return ["bash", "-lc", "cat " + configPath() + " 2>/dev/null || true"]
}

var NUMERIC_KEYS = ["strength", "minKelvin", "maxKelvin", "luxFloor", "emaAlpha", "deadbandK", "maxStepK", "pollIntervalSec"]

function parseConfig(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line || line.charAt(0) === "#") continue
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.slice(0, eq).trim()
    var raw = line.slice(eq + 1).trim()
    if (NUMERIC_KEYS.indexOf(key) === -1) continue
    var value = parseFloat(raw)
    if (!isFinite(value)) continue
    out[key] = value
  }
  // Refuse settings that would produce a broken display rather than trusting
  // a hand-edited file.
  if (out.strength !== undefined) out.strength = Math.max(0, Math.min(1, out.strength))
  if (out.maxKelvin !== undefined) out.maxKelvin = Math.min(NEUTRAL_K, out.maxKelvin)
  if (out.minKelvin !== undefined) out.minKelvin = Math.max(1000, out.minKelvin)
  if (out.minKelvin !== undefined && out.maxKelvin !== undefined && out.minKelvin > out.maxKelvin) {
    delete out.minKelvin
    delete out.maxKelvin
  }
  return out
}

// Written back whenever the panel changes a knob, so the file stays the single
// source of truth and hand edits survive a round trip.
function renderConfig(values) {
  var v = optionsWithDefaults(values)
  var poll = (values && isFinite(values.pollIntervalSec)) ? values.pollIntervalSec : 2
  return [
    "# omarchy true tone. Managed by the panel, safe to hand edit.",
    "",
    "# How far to move toward the room colour, 0 to 1.",
    "strength = " + v.strength,
    "",
    "# Warmest the display may go.",
    "minKelvin = " + Math.round(v.minKelvin),
    "",
    "# Coolest. Above " + NEUTRAL_K + " tints the panel blue.",
    "maxKelvin = " + Math.round(v.maxKelvin),
    "",
    "# Below this many lux, hold rather than sample.",
    "luxFloor = " + Math.round(v.luxFloor),
    "",
    "# Kelvin per tick while ramping.",
    "maxStepK = " + Math.round(v.maxStepK),
    "",
    "# Seconds between sensor reads.",
    "pollIntervalSec = " + Math.round(poll),
    ""
  ].join("\n")
}

function saveConfigCommand(values) {
  return ["bash", "-lc",
    "mkdir -p ~/.config/omarchy && cat > " + configPath() + " <<'TRUETONE_EOF'\n" +
    renderConfig(values) + "TRUETONE_EOF"]
}

function temperatureFromOutput(output) {
  var match = String(output === undefined || output === null ? "" : output).match(/[0-9]+/)
  return match ? Number(match[0]) : null
}

function describe(reading, targetK) {
  if (!reading) return "sensor unavailable"
  var parts = [Math.round(reading.cct) + "K room"]
  parts.push(Math.round(reading.lux) + " lux")
  if (targetK) parts.push("→ " + targetK + "K display")
  return parts.join(" · ")
}

if (typeof module !== "undefined") {
  module.exports = {
    NEUTRAL_K: NEUTRAL_K,
    DEFAULTS: DEFAULTS,
    scanCommand: scanCommand,
    parseScan: parseScan,
    pickSensor: pickSensor,
    readCommand: readCommand,
    parseReading: parseReading,
    hasUsableLight: hasUsableLight,
    PACING: PACING,
    isSettled: isSettled,
    pollIntervalFor: pollIntervalFor,
    shouldProbe: shouldProbe,
    configPath: configPath,
    loadConfigCommand: loadConfigCommand,
    parseConfig: parseConfig,
    renderConfig: renderConfig,
    saveConfigCommand: saveConfigCommand,
    adaptTarget: adaptTarget,
    smooth: smooth,
    nextStep: nextStep,
    externallyChanged: externallyChanged,
    temperatureFromOutput: temperatureFromOutput,
    describe: describe
  }
}

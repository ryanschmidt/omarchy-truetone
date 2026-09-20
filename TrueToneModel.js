// Pure logic for True Tone. No QML, no I/O, so it runs under node for tests.
//
// True Tone has no settings, the same as on a Mac: it is on or off. Night
// Light owns the Kelvin slider, and this owns nothing but the white point.
// The constants below are the product, not configuration.

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// D65. Every display is built to call this white, so it is what we adapt from.
var D65_X = 0.3127
var D65_Y = 0.3290
var D65_K = 6500

// How far to move from D65 toward the room. True Tone is a partial
// adaptation, not a match: your eye is already adapting, so the display only
// closes part of the gap. Adapting fully to a 2000K lamp looks alarmingly
// orange. This is the one number that decides how the feature feels.
var STRENGTH = 0.5

// The warmest white point we will produce, as a floor on the blue channel.
// Without it a candle-lit room would drive blue toward zero.
var MIN_BLUE_GAIN = 0.42

// Below this the colour channel has too few photons to mean anything.
// Measured on a Dell XPS 14: readings stay coherent down to about 7 lux.
var LUX_FLOOR = 3

// Sensor noise sits around +/- 20K, so this mostly smooths real transitions.
var EMA_ALPHA = 0.3

// Per tick, in gain units. A step change in white point is very visible in
// peripheral vision, so we walk there instead.
var MAX_GAIN_STEP = 0.012

// Changes smaller than this are invisible; do not spend a write on them.
var GAIN_DEADBAND = 0.004

// Room lighting changes over minutes, so a fixed fast poll spends its whole
// budget confirming that nothing happened.
var FAST_INTERVAL_SEC = 2
var IDLE_INTERVAL_SEC = 20
var STABLE_CCT_DELTA_K = 40

// ---------------------------------------------------------------------------
// Sensor discovery
// ---------------------------------------------------------------------------

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

// Other ALS consumers take the first IIO device named `als` and stop. A Dell
// XPS 14 has two: iio:device1 is lux-only and sorts first, iio:device2 carries
// the colour channel. Taking the first silently disables adaptive colour on
// exactly the hardware that supports it.
function pickSensor(devices) {
  if (!devices || !devices.length) return null
  var lux = null
  for (var i = 0; i < devices.length; i++) {
    var d = devices[i]
    if (d.name !== "als") continue
    if (d.hasColortemp && d.hasLux) return d
    if (d.hasLux && !lux) lux = d
  }
  return lux
}

function hasUsableLight(lux) {
  return isFinite(lux) && lux >= LUX_FLOOR
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

// Planckian locus, Kim et al. cubic approximation. Used to separate the
// measured chromaticity into "how warm" and "how far off the curve", so the
// two can be scaled independently.
function locusXY(T) {
  var x
  if (T <= 4000) {
    x = -0.2661239e9 / (T * T * T) - 0.2343589e6 / (T * T) + 0.8776956e3 / T + 0.179910
  } else {
    x = -3.0258469e9 / (T * T * T) + 2.1070379e6 / (T * T) + 0.2226347e3 / T + 0.240390
  }
  var y
  if (T <= 2222) {
    y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
  } else if (T <= 4000) {
    y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
  } else {
    y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
  }
  return { x: x, y: y }
}

// CIE xy -> linear sRGB gains, normalised so nothing exceeds 1.
//
// A gamma ramp is a per-channel curve, so only a diagonal transform is
// available: we can attenuate channels, never boost one. Normalising to the
// brightest channel is what keeps the result a white-point shift rather than
// a brightness change.
function xyToGains(x, y) {
  if (!isFinite(x) || !isFinite(y) || y <= 0) return null
  var X = x / y
  var Y = 1.0
  var Z = (1 - x - y) / y

  var r = 3.2406 * X - 1.5372 * Y - 0.4986 * Z
  var g = -0.9689 * X + 1.8758 * Y + 0.0415 * Z
  var b = 0.0557 * X - 0.2040 * Y + 1.0570 * Z

  r = Math.max(0, r); g = Math.max(0, g); b = Math.max(0, b)
  var m = Math.max(r, g, b)
  if (!(m > 0)) return null
  return { r: r / m, g: g / m, b: b / m }
}

// The whole feature.
//
// Warmth is interpolated in Kelvin and the off-locus component of the
// measured chromaticity is carried across separately. That second part is
// what a Kelvin-only approach cannot do, and it is why a colour sensor is
// required: cheap LED and fluorescent lighting sits visibly off the blackbody
// curve, and matching only its correlated temperature leaves the cast behind.
function adaptGains(ambientK, ambientX, ambientY) {
  if (!isFinite(ambientK) || ambientK <= 0) return null

  var targetK = D65_K + STRENGTH * (ambientK - D65_K)
  if (targetK > D65_K) targetK = D65_K          // never tint the panel blue

  var target = locusXY(targetK)
  var tx = target.x
  var ty = target.y

  // Carry the measured tint, scaled the same way the warmth was.
  if (isFinite(ambientX) && isFinite(ambientY) && ambientX > 0 && ambientY > 0) {
    var measuredLocus = locusXY(ambientK)
    tx += STRENGTH * (ambientX - measuredLocus.x)
    ty += STRENGTH * (ambientY - measuredLocus.y)
  }

  var gains = xyToGains(tx, ty)
  if (!gains) return null

  // Bound how warm this can get, keeping the hue by scaling green with blue.
  if (gains.b < MIN_BLUE_GAIN) {
    var lift = MIN_BLUE_GAIN / gains.b
    gains.b = MIN_BLUE_GAIN
    gains.g = Math.min(1, gains.g * Math.sqrt(lift))
  }
  return {
    r: round3(gains.r),
    g: round3(gains.g),
    b: round3(gains.b),
    targetK: Math.round(targetK)
  }
}

function round3(v) { return Math.round(v * 1000) / 1000 }

var IDENTITY_GAINS = { r: 1, g: 1, b: 1 }

// ---------------------------------------------------------------------------
// Motion
// ---------------------------------------------------------------------------

function smoothCct(previous, sample) {
  if (!isFinite(sample)) return previous
  if (previous === null || previous === undefined || !isFinite(previous)) return sample
  return previous + EMA_ALPHA * (sample - previous)
}

// Walk each channel toward the target. Returns null when already there.
function stepGains(current, target) {
  if (!target) return null
  if (!current) return { r: target.r, g: target.g, b: target.b }
  var dr = target.r - current.r
  var dg = target.g - current.g
  var db = target.b - current.b
  if (Math.abs(dr) <= GAIN_DEADBAND &&
      Math.abs(dg) <= GAIN_DEADBAND &&
      Math.abs(db) <= GAIN_DEADBAND) return null
  return {
    r: round3(current.r + clampStep(dr)),
    g: round3(current.g + clampStep(dg)),
    b: round3(current.b + clampStep(db))
  }
}

function clampStep(delta) {
  return Math.max(-MAX_GAIN_STEP, Math.min(MAX_GAIN_STEP, delta))
}

function isSettled(state) {
  if (!state) return false
  if (stepGains(state.appliedGains, state.targetGains) !== null) return false
  if (isFinite(state.previousCct) && isFinite(state.cct)) {
    if (Math.abs(state.cct - state.previousCct) > STABLE_CCT_DELTA_K) return false
  }
  return true
}

function pollIntervalFor(settled) {
  return settled ? IDLE_INTERVAL_SEC : FAST_INTERVAL_SEC
}

// ---------------------------------------------------------------------------
// Helper protocol
// ---------------------------------------------------------------------------

function setCommand(gains) {
  if (!gains) return "RESET\n"
  return "SET " + gains.r.toFixed(3) + " " + gains.g.toFixed(3) + " " + gains.b.toFixed(3) + "\n"
}

// ---------------------------------------------------------------------------
// Persisted state: only whether the user switched it on.
// ---------------------------------------------------------------------------

function statePath() { return "~/.local/state/omarchy-truetone/enabled" }

function loadStateCommand() {
  return ["bash", "-lc", "cat " + statePath() + " 2>/dev/null || echo 1"]
}

function saveStateCommand(enabled) {
  return ["bash", "-lc",
    "mkdir -p ~/.local/state/omarchy-truetone && printf '%s' " +
    (enabled ? "1" : "0") + " > " + statePath()]
}

function parseState(text) { return String(text || "").trim() !== "0" }

function describe(reading, targetK) {
  if (!reading) return "sensor unavailable"
  var parts = [Math.round(reading.cct) + "K room", Math.round(reading.lux) + " lux"]
  if (targetK) parts.push("display at " + targetK + "K")
  return parts.join(" · ")
}

if (typeof module !== "undefined") {
  module.exports = {
    D65_K: D65_K, STRENGTH: STRENGTH, LUX_FLOOR: LUX_FLOOR,
    MIN_BLUE_GAIN: MIN_BLUE_GAIN, IDENTITY_GAINS: IDENTITY_GAINS,
    FAST_INTERVAL_SEC: FAST_INTERVAL_SEC, IDLE_INTERVAL_SEC: IDLE_INTERVAL_SEC,
    scanCommand: scanCommand, parseScan: parseScan, pickSensor: pickSensor,
    hasUsableLight: hasUsableLight,
    locusXY: locusXY, xyToGains: xyToGains, adaptGains: adaptGains,
    smoothCct: smoothCct, stepGains: stepGains, isSettled: isSettled,
    pollIntervalFor: pollIntervalFor, setCommand: setCommand,
    statePath: statePath, loadStateCommand: loadStateCommand,
    saveStateCommand: saveStateCommand, parseState: parseState,
    describe: describe
  }
}

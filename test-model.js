#!/usr/bin/env node
// Self-check for TrueToneModel. No framework on purpose.
//   node test-model.js

var assert = require("assert")
var M = require("./TrueToneModel.js")

var passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
    console.log("  ok   " + name)
  } catch (e) {
    console.error("  FAIL " + name + "\n       " + e.message)
    process.exitCode = 1
  }
}

console.log("\nsensor selection")

// The regression this plugin exists to fix. Real Dell XPS 14 topology:
// device1 is a lux-only ALS and sorts first, device2 carries the colour
// channel. Taking the first `als` silently disables adaptive colour.
test("prefers the colour-capable ALS over an earlier lux-only one", function () {
  var devices = M.parseScan([
    "/sys/bus/iio/devices/iio:device0|prox|0|0|0",
    "/sys/bus/iio/devices/iio:device1|als|0|0|1",
    "/sys/bus/iio/devices/iio:device2|als|1|1|1",
    "/sys/bus/iio/devices/iio:device3|hinge|0|0|0"
  ].join("\n"))
  assert.strictEqual(M.pickSensor(devices).path, "/sys/bus/iio/devices/iio:device2")
})

test("falls back to a lux-only ALS so the UI can explain itself", function () {
  var d = M.pickSensor(M.parseScan("/sys/bus/iio/devices/iio:device1|als|0|0|1"))
  assert.strictEqual(d.hasColortemp, false)
})

test("ignores non-ALS devices, and survives garbage", function () {
  assert.strictEqual(M.pickSensor(M.parseScan("/sys/bus/iio/devices/iio:device0|prox|0|0|0")), null)
  assert.strictEqual(M.pickSensor(M.parseScan("")), null)
  assert.strictEqual(M.pickSensor(null), null)
})

test("holds below the lux floor where colour readings are meaningless", function () {
  assert.strictEqual(M.hasUsableLight(1), false)
  assert.strictEqual(M.hasUsableLight(9), true)
})

console.log("\ncolour: xy to gains")

test("D65 produces essentially no correction", function () {
  var g = M.xyToGains(0.3127, 0.3290)
  assert.ok(Math.abs(g.r - 1) < 0.02, "r=" + g.r)
  assert.ok(Math.abs(g.g - 1) < 0.02, "g=" + g.g)
  assert.ok(Math.abs(g.b - 1) < 0.02, "b=" + g.b)
})

test("never boosts a channel above 1, so it cannot tint blue or brighten", function () {
  var samples = [[0.45, 0.41], [0.3127, 0.3290], [0.25, 0.25], [0.55, 0.40]]
  samples.forEach(function (s) {
    var g = M.xyToGains(s[0], s[1])
    if (!g) return
    assert.ok(g.r <= 1 && g.g <= 1 && g.b <= 1, "exceeded 1 at " + s)
    assert.ok(Math.max(g.r, g.g, g.b) === 1, "not normalised at " + s)
  })
})

test("rejects impossible chromaticity", function () {
  assert.strictEqual(M.xyToGains(0.3, 0), null)
  assert.strictEqual(M.xyToGains(NaN, 0.3), null)
})

console.log("\ncolour: adaptation")

test("the correction is subtle, not a blue-light filter", function () {
  // The whole point of the review: it was cutting blue by 78% of emitted
  // light. True Tone is something you notice when you toggle it, not a
  // night mode.
  var g = M.adaptGains(1997, 0.531, 0.420)
  assert.ok(g.b > 0.6, "still too aggressive: b=" + g.b)
  assert.ok(g.g > 0.7, "still too aggressive: g=" + g.g)
})

test("a warm room warms the display, attenuating blue most", function () {
  // Measured on the XPS 14 under an evening lamp.
  var g = M.adaptGains(1997, 0.531, 0.420)
  assert.ok(g.b < g.g && g.g < g.r, "channel order wrong: " + JSON.stringify(g))
  assert.strictEqual(g.r, 1)
})

test("a neutral room gets EXACTLY no correction", function () {
  // Regression, codex review: the anchor used to sit on the Planckian locus
  // at 6500K, which is (0.3135, 0.3237) against D65's (0.3127, 0.3290). That
  // cut green by 5.6% in a perfectly neutral room.
  var g = M.adaptGains(6500, 0.3127, 0.3290)
  assert.deepStrictEqual({ r: g.r, g: g.g, b: g.b }, { r: 1, g: 1, b: 1 })
})

test("a cool room does not tint the panel blue", function () {
  // Adapting toward 9000K would mean boosting blue, which a gamma ramp
  // cannot do without darkening everything else. Clamp at D65 instead.
  var g = M.adaptGains(9000, 0.28, 0.29)
  assert.strictEqual(g.targetK, M.D65_K)
})

test("moves partway, never all the way", function () {
  var g = M.adaptGains(2000, null, null)
  // Well short of the room, and well short of a night-mode shift.
  assert.ok(g.targetK > 5000 && g.targetK < M.D65_K, "targetK=" + g.targetK)
  assert.ok(g.b > 0.6, "b=" + g.b)
})

test("respects the blue floor in candlelight", function () {
  var g = M.adaptGains(1200, 0.60, 0.39)
  assert.ok(g.b >= M.MIN_BLUE_GAIN - 0.001, "b=" + g.b)
})

test("carries an off-locus tint that a Kelvin-only approach would miss", function () {
  // Two rooms at the same CCT: one on the blackbody curve, one green like a
  // cheap fluorescent. They must not produce the same correction.
  var onCurve = M.locusXY(4000)
  var neutral = M.adaptGains(4000, onCurve.x, onCurve.y)
  var green = M.adaptGains(4000, onCurve.x, onCurve.y + 0.03)
  assert.notStrictEqual(neutral.g, green.g)
})

test("survives a sensor with no chromaticity channel", function () {
  var g = M.adaptGains(3000, null, null)
  assert.ok(g && g.r === 1 && g.b < 1)
})

test("rejects a nonsense reading", function () {
  assert.strictEqual(M.adaptGains(0, 0.3, 0.3), null)
  assert.strictEqual(M.adaptGains(NaN, 0.3, 0.3), null)
})

test("chromaticity and temperature are smoothed together", function () {
  // Regression, codex review: a smoothed CCT paired with raw or stale xy
  // manufactured tint during a transition.
  var a = M.smoothReading(null, { cct: 2000, x: 0.5, y: 0.41 })
  assert.deepStrictEqual(a, { cct: 2000, x: 0.5, y: 0.41 })
  var b = M.smoothReading(a, { cct: 5000, x: 0.35, y: 0.35 })
  assert.ok(b.cct > 2000 && b.cct < 5000, "cct not damped")
  assert.ok(b.x < 0.5 && b.x > 0.35, "x not damped")
  assert.ok(b.y < 0.41 && b.y > 0.35, "y not damped")
})

test("a missing chromaticity channel keeps the previous value", function () {
  var a = M.smoothReading(null, { cct: 3000, x: 0.44, y: 0.40 })
  var b = M.smoothReading(a, { cct: 3000, x: null, y: null })
  assert.strictEqual(b.x, 0.44)
})

console.log("\nmotion")

test("EMA seeds from the first sample", function () {
  assert.strictEqual(M.smoothCct(null, 4000), 4000)
})

test("EMA damps a step change", function () {
  assert.strictEqual(Math.round(M.smoothCct(2000, 5000)), 2900)
})

test("first application jumps straight to target", function () {
  var s = M.stepGains(null, { r: 1, g: 0.8, b: 0.6 })
  assert.deepStrictEqual(s, { r: 1, g: 0.8, b: 0.6 })
})

test("ramp is capped per tick", function () {
  var s = M.stepGains({ r: 1, g: 1, b: 1 }, { r: 1, g: 0.8, b: 0.6 })
  assert.ok(s.b > 0.98, "jumped too far: " + s.b)
})

test("deadband suppresses invisible changes", function () {
  assert.strictEqual(M.stepGains({ r: 1, g: 0.9, b: 0.8 }, { r: 1, g: 0.9, b: 0.801 }), null)
})

test("ramp converges and then stops", function () {
  var cur = { r: 1, g: 1, b: 1 }
  var target = M.adaptGains(1997, 0.531, 0.420)
  var ticks = 0
  while (ticks < 1000) {
    var n = M.stepGains(cur, target)
    if (n === null) break
    cur = n; ticks++
  }
  assert.ok(ticks < 1000, "never converged")
  assert.ok(Math.abs(cur.b - target.b) <= 0.005, "settled at b=" + cur.b)
})

console.log("\npacing")

test("stays fast while ramping, backs off once settled", function () {
  var target = { r: 1, g: 0.8, b: 0.6 }
  assert.strictEqual(M.isSettled({ appliedGains: { r: 1, g: 1, b: 1 }, targetGains: target }), false)
  assert.strictEqual(M.isSettled({ appliedGains: target, targetGains: target, cct: 2000, previousCct: 2010 }), true)
  assert.strictEqual(M.pollIntervalFor(false), M.FAST_INTERVAL_SEC)
  assert.strictEqual(M.pollIntervalFor(true), M.IDLE_INTERVAL_SEC)
})

test("stays fast while the room is actually changing", function () {
  var t = { r: 1, g: 0.8, b: 0.6 }
  assert.strictEqual(M.isSettled({ appliedGains: t, targetGains: t, cct: 4600, previousCct: 2000 }), false)
})

console.log("\nhelper protocol")

test("formats a SET line the helper accepts", function () {
  assert.strictEqual(M.setCommand({ r: 1, g: 0.871, b: 0.752 }), "SET 1.000 0.871 0.752\n")
})

test("no gains means RESET", function () {
  assert.strictEqual(M.setCommand(null), "RESET\n")
})

console.log("\npersisted state")

test("remembers only whether it is on", function () {
  assert.strictEqual(M.parseState("1"), true)
  assert.strictEqual(M.parseState("0"), false)
  assert.strictEqual(M.parseState(""), true)      // default on
  assert.strictEqual(M.parseState("garbage"), true)
})

console.log("\n" + passed + " passed" + (process.exitCode ? ", SOME FAILED" : "") + "\n")

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
// device1 is a lux-only ALS and sorts first, device2 carries the color
// channel. Taking the first `als` silently disables adaptive color.
test("prefers the color-capable ALS over an earlier lux-only one", function () {
  var devices = M.parseScan([
    "/sys/bus/iio/devices/iio:device0|prox|0|0|0",
    "/sys/bus/iio/devices/iio:device1|als|0|0|1",
    "/sys/bus/iio/devices/iio:device2|als|1|1|1",
    "/sys/bus/iio/devices/iio:device3|hinge|0|0|0"
  ].join("\n"))
  var picked = M.pickSensor(devices)
  assert.strictEqual(picked.path, "/sys/bus/iio/devices/iio:device2")
  assert.strictEqual(picked.hasColortemp, true)
})

test("falls back to a lux-only ALS so the UI can explain itself", function () {
  var devices = M.parseScan("/sys/bus/iio/devices/iio:device1|als|0|0|1")
  var picked = M.pickSensor(devices)
  assert.strictEqual(picked.path, "/sys/bus/iio/devices/iio:device1")
  assert.strictEqual(picked.hasColortemp, false)
})

test("ignores non-ALS devices entirely", function () {
  var devices = M.parseScan([
    "/sys/bus/iio/devices/iio:device0|prox|0|0|0",
    "/sys/bus/iio/devices/iio:device3|hinge|0|0|0"
  ].join("\n"))
  assert.strictEqual(M.pickSensor(devices), null)
})

test("survives an empty or garbage scan", function () {
  assert.strictEqual(M.pickSensor(M.parseScan("")), null)
  assert.strictEqual(M.pickSensor(M.parseScan("nonsense\n\n")), null)
  assert.strictEqual(M.pickSensor(null), null)
})

console.log("\nsensor reading")

test("applies sysfs scales to raw integers", function () {
  var r = M.parseReading([
    "cct=1997000", "cctscale=0.001000000",
    "lux=9000", "luxscale=0.001000000",
    "x=531", "y=420", "xyscale=0.001000000"
  ].join("\n"))
  assert.strictEqual(Math.round(r.cct), 1997)
  assert.strictEqual(Math.round(r.lux), 9)
  assert.ok(Math.abs(r.x - 0.531) < 1e-9)
  assert.ok(Math.abs(r.y - 0.420) < 1e-9)
})

test("returns null when the sensor gives nothing", function () {
  assert.strictEqual(M.parseReading("cct=\nlux="), null)
  assert.strictEqual(M.parseReading(""), null)
})

test("defaults a missing scale rather than producing a wild value", function () {
  var r = M.parseReading("cct=4646000\nlux=300000")
  assert.strictEqual(Math.round(r.cct), 4646)
})

console.log("\nadaptation")

test("moves partway toward the room, never all the way", function () {
  // 2000K room at 50% strength lands midway to neutral, not at 2000K.
  var t = M.adaptTarget(2000, { strength: 0.5, minKelvin: 1000 })
  assert.strictEqual(t, 4250)
})

test("clamps warm rooms at the floor", function () {
  var t = M.adaptTarget(1500, { strength: 1.0, minKelvin: 3800 })
  assert.strictEqual(t, 3800)
})

test("never goes above neutral, so the panel is never tinted blue", function () {
  var t = M.adaptTarget(9000, { strength: 1.0 })
  assert.strictEqual(t, M.NEUTRAL_K)
})

test("strength 0 disables adaptation entirely", function () {
  assert.strictEqual(M.adaptTarget(2000, { strength: 0 }), M.NEUTRAL_K)
})

test("rejects a nonsense ambient value", function () {
  assert.strictEqual(M.adaptTarget(0), null)
  assert.strictEqual(M.adaptTarget(NaN), null)
})

console.log("\nlow light guard")

test("holds below the lux floor where color readings are meaningless", function () {
  assert.strictEqual(M.hasUsableLight(1, { luxFloor: 3 }), false)
  assert.strictEqual(M.hasUsableLight(9, { luxFloor: 3 }), true)
})

console.log("\nsmoothing and ramping")

test("EMA seeds from the first sample instead of ramping from zero", function () {
  assert.strictEqual(M.smooth(null, 4000), 4000)
})

test("EMA damps a step change", function () {
  var s = M.smooth(2000, 5000, { emaAlpha: 0.3 })
  assert.strictEqual(Math.round(s), 2900)
})

test("ramp is capped per tick", function () {
  assert.strictEqual(M.nextStep(4000, 6500, { maxStepK: 100 }), 4100)
  assert.strictEqual(M.nextStep(6500, 4000, { maxStepK: 100 }), 6400)
})

test("deadband suppresses invisible changes", function () {
  assert.strictEqual(M.nextStep(4000, 4010, { deadbandK: 25 }), null)
})

test("first application jumps straight to target", function () {
  assert.strictEqual(M.nextStep(null, 4300), 4300)
})

test("ramp converges and then stops", function () {
  var cur = 6500, target = 3800, ticks = 0
  while (ticks < 200) {
    var next = M.nextStep(cur, target, { maxStepK: 100, deadbandK: 25 })
    if (next === null) break
    cur = next
    ticks++
  }
  assert.ok(ticks < 200, "did not converge")
  assert.ok(Math.abs(cur - target) <= 25, "settled at " + cur)
})

console.log("\nownership (regression: codex review findings 2 and 5)")

test("yields when Night Light already owns the display at startup", function () {
  // lastSetK is null because we have set nothing yet. The old test returned
  // "nothing changed" here and stamped over Night Light.
  var o = M.evaluateOwnership(4000, null)
  assert.strictEqual(o.shouldYield, true)
  assert.strictEqual(o.owned, false)
})

test("adopts a free display at neutral on startup", function () {
  var o = M.evaluateOwnership(6500, null)
  assert.strictEqual(o.shouldYield, false)
  assert.strictEqual(o.atNeutral, true)
})

test("keeps ownership when the display shows what we set", function () {
  var o = M.evaluateOwnership(4250, 4250)
  assert.strictEqual(o.owned, true)
  assert.strictEqual(o.shouldYield, false)
})

test("yields when something else warms the display", function () {
  var o = M.evaluateOwnership(4000, 5200)
  assert.strictEqual(o.owned, false)
  assert.strictEqual(o.shouldYield, true)
})

test("resumes after Night Light returns to neutral, even at a value we once set", function () {
  // The stuck-yielded case. We last set 6500, Night Light took it to 4000,
  // then released back to 6500.
  var o = M.evaluateOwnership(6500, 6500)
  assert.strictEqual(o.shouldYield, false)
  assert.strictEqual(o.atNeutral, true)
})

test("treats an unknown temperature as not ours", function () {
  var o = M.evaluateOwnership(null, 4250)
  assert.strictEqual(o.shouldYield, true)
})

test("parses hyprctl output the way Omarchy's nightlight does", function () {
  assert.strictEqual(M.temperatureFromOutput("6500"), 6500)
  assert.strictEqual(M.temperatureFromOutput("temperature: 4000\n"), 4000)
  assert.strictEqual(M.temperatureFromOutput(""), null)
})

console.log("\nconfig sanitising (regression: codex review finding 8)")

test("a lone minKelvin above neutral cannot push the target above neutral", function () {
  // Previously produced a 9000K target because the pairwise range check only
  // ran when BOTH bounds were supplied.
  assert.strictEqual(M.adaptTarget(2000, M.parseConfig("minKelvin=9000")), M.NEUTRAL_K)
})

test("a negative step still ramps toward the target", function () {
  var step = M.nextStep(6500, 4250, M.parseConfig("maxStepK=-150"))
  assert.ok(step < 6500, "moved the wrong way: " + step)
})

test("a zero step still converges", function () {
  var cur = 6500, ticks = 0
  while (ticks < 500) {
    var n = M.nextStep(cur, 4250, { maxStepK: 0 })
    if (n === null) break
    cur = n; ticks++
  }
  assert.ok(ticks < 500, "never converged")
})

test("effective options are clamped, not just supplied ones", function () {
  var o = M.sanitizeOptions({ strength: 9, minKelvin: 99999, maxKelvin: 99999, maxStepK: -5, emaAlpha: 0, deadbandK: -1, luxFloor: -4 })
  assert.strictEqual(o.strength, 1)
  assert.strictEqual(o.maxKelvin, M.NEUTRAL_K)
  assert.ok(o.minKelvin <= o.maxKelvin)
  assert.ok(o.maxStepK >= 1)
  assert.ok(o.emaAlpha > 0)
  assert.ok(o.deadbandK >= 0)
  assert.ok(o.luxFloor >= 0)
})

console.log("\npacing")

test("stays fast while still ramping", function () {
  var settled = M.isSettled({ appliedK: 6000, targetK: 4200, cct: 2000, previousCct: 2000 })
  assert.strictEqual(settled, false)
})

test("stays fast while the room is actually changing", function () {
  var settled = M.isSettled({ appliedK: 4250, targetK: 4250, cct: 4600, previousCct: 2000 })
  assert.strictEqual(settled, false)
})

test("settles when at target and the reading is only breathing", function () {
  var settled = M.isSettled({ appliedK: 4250, targetK: 4250, cct: 1985, previousCct: 2000 })
  assert.strictEqual(settled, true)
})

test("backs off the poll once settled", function () {
  assert.strictEqual(M.pollIntervalFor(false, 2, 20), 2)
  assert.strictEqual(M.pollIntervalFor(true, 2, 20), 20)
})

test("never backs off below the configured fast interval", function () {
  assert.strictEqual(M.pollIntervalFor(true, 30, 20), 30)
})

console.log("\nconfig")

test("reads the knobs people will actually turn", function () {
  var c = M.parseConfig("# mine\nstrength = 0.7\nminKelvin=3200\n\npollIntervalSec=5\n")
  assert.strictEqual(c.strength, 0.7)
  assert.strictEqual(c.minKelvin, 3200)
  assert.strictEqual(c.pollIntervalSec, 5)
})

test("ignores comments, blanks and unknown keys", function () {
  var c = M.parseConfig("# comment\n\nrmrf=1\nstrength=0.4\n")
  assert.deepStrictEqual(Object.keys(c), ["strength"])
})

test("clamps a hand-edited file that would break the display", function () {
  assert.strictEqual(M.parseConfig("strength=5").strength, 1)
  assert.strictEqual(M.parseConfig("strength=-2").strength, 0)
  // Above neutral would tint the panel blue.
  assert.strictEqual(M.parseConfig("maxKelvin=12000").maxKelvin, M.NEUTRAL_K)
})

test("drops an inverted range instead of applying it", function () {
  var c = M.parseConfig("minKelvin=6000\nmaxKelvin=4000")
  assert.strictEqual(c.minKelvin, undefined)
  assert.strictEqual(c.maxKelvin, undefined)
})

test("survives a missing or garbage config", function () {
  assert.deepStrictEqual(M.parseConfig(""), {})
  assert.deepStrictEqual(M.parseConfig(null), {})
  assert.deepStrictEqual(M.parseConfig("strength=banana"), {})
})

test("round trips: what we write is what we read back", function () {
  var wanted = { strength: 0.65, minKelvin: 3400, maxKelvin: 6200, luxFloor: 5, maxStepK: 120, pollIntervalSec: 4 }
  var back = M.parseConfig(M.renderConfig(wanted))
  assert.strictEqual(back.strength, 0.65)
  assert.strictEqual(back.minKelvin, 3400)
  assert.strictEqual(back.maxKelvin, 6200)
  assert.strictEqual(back.luxFloor, 5)
  assert.strictEqual(back.maxStepK, 120)
  assert.strictEqual(back.pollIntervalSec, 4)
})

test("rendered config carries no shell metacharacters that would break the heredoc", function () {
  var text = M.renderConfig({ strength: 0.5 })
  assert.strictEqual(text.indexOf("TRUETONE_EOF"), -1)
  assert.strictEqual(/[`$\\]/.test(text), false)
})

console.log("\npersisted state")

test("round trips enabled and the last temperature we wrote", function () {
  var cmd = M.saveStateCommand(true, 4270)
  var body = cmd[2].split("TRUETONE_STATE_EOF")[1]
  var back = M.parseState(body)
  assert.strictEqual(back.enabled, true)
  assert.strictEqual(back.lastSetK, 4270)
})

test("a missing state file means enabled with no remembered temperature", function () {
  var s = M.parseState("")
  assert.strictEqual(s.enabled, true)
  assert.strictEqual(s.lastSetK, null)
})

test("remembering our own value survives a restart without yielding", function () {
  // The regression: after a shell restart the display still shows our 4270K.
  // Without the remembered value this reads as somebody else's and parks.
  var remembered = M.parseState("enabled=1\nlastSet=4270").lastSetK
  assert.strictEqual(M.evaluateOwnership(4270, remembered).shouldYield, false)
  assert.strictEqual(M.evaluateOwnership(4270, null).shouldYield, true)
})

test("a remembered value does not stop us yielding to Night Light", function () {
  var remembered = M.parseState("enabled=1\nlastSet=4270").lastSetK
  assert.strictEqual(M.evaluateOwnership(4000, remembered).shouldYield, true)
})

test("garbage state degrades to the safe default", function () {
  assert.strictEqual(M.parseState("lastSet=banana").lastSetK, null)
  assert.strictEqual(M.parseState("enabled=0").enabled, false)
})

console.log("\nend to end")

test("a real dark-room reading produces a sane display temperature", function () {
  // Verified on hardware: Dell XPS 14, warm lamp, evening.
  var r = M.parseReading("cct=1997000\ncctscale=0.001\nlux=9000\nluxscale=0.001")
  assert.strictEqual(M.hasUsableLight(r.lux), true)
  var t = M.adaptTarget(r.cct)
  assert.ok(t >= 3800 && t <= 6500, "target out of range: " + t)
  assert.strictEqual(t, 4249)
})

test("a real torch-lit reading barely shifts the display", function () {
  // Verified on hardware: same machine under a phone torch.
  var r = M.parseReading("cct=4646000\ncctscale=0.001\nlux=300000\nluxscale=0.001")
  var t = M.adaptTarget(r.cct)
  assert.strictEqual(t, 5573)
})

console.log("\n" + passed + " passed" + (process.exitCode ? ", SOME FAILED" : "") + "\n")

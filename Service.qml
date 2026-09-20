import QtQuick
import Quickshell.Io
import "TrueToneModel.js" as Model

// Reads the ambient color sensor and moves the display white point to match.
// Applies through hyprsunset, the same surface Omarchy's own Night Light uses.
//
// Two invariants hold the design together, both the product of a review that
// found real ways to break them:
//
//   OWNERSHIP. We only write the temperature while the display shows what we
//   last put there, or while it sits at neutral and is therefore free. Anything
//   else means Night Light or the user owns it and we stand down. Ownership is
//   re-established by a probe before any write, never assumed.
//
//   ONE OPERATION IN FLIGHT. A probe, a sample cycle, or an apply, never two.
//   Sensor callbacks arrive asynchronously and used to be able to land after a
//   disable, or pair a fresh reading with a stale one.
//
// Cost discipline, because this runs forever on a laptop: sysfs is read in
// process via FileView with no fork, there is no shell in the steady state,
// and polling backs off from 2s to 20s once the room stops changing.
Item {
  id: root

  property var shell: null

  // ---- configuration -------------------------------------------------------
  property real strength: 0.5
  property int minKelvin: 3800
  property int maxKelvin: Model.NEUTRAL_K
  property int luxFloor: 3
  property int maxStepK: 150
  property int pollIntervalSec: 2
  property int idleIntervalSec: 20

  readonly property var opts: ({
    strength: root.strength,
    minKelvin: root.minKelvin,
    maxKelvin: root.maxKelvin,
    luxFloor: root.luxFloor,
    maxStepK: root.maxStepK
  })

  // ---- state ---------------------------------------------------------------
  property bool enabled: true
  property bool ready: false
  property bool sensorBound: false
  property string sensorPath: ""
  property bool sensorHasColor: false
  property string unavailableReason: ""

  property var reading: null
  property var smoothedCct: null
  property var previousCct: null
  property var targetK: null
  property var appliedK: null      // last CONFIRMED display temperature
  property var lastSetK: null      // last value we successfully wrote
  property bool yielded: false
  property bool transportOk: true  // is hyprctl answering at all
  // Set only by an explicit user action. Startup stays conservative and yields
  // to whoever already holds a warm display; a deliberate toggle-on is the
  // user saying "I want True Tone now", which outranks that caution and is
  // also the only way out if something else parked the display warm.
  property bool adoptOnNextProbe: false
  // Releasing the display has to be decided against a FRESH probe. The
  // `yielded` flag can be up to one idle poll stale, and acting on a stale
  // "we own it" is how disabling True Tone switched off someone's Night Light.
  property bool releaseOnNextProbe: false

  property bool settled: false

  // Exactly one of these may be true at a time.
  property bool probePending: false
  property bool samplePending: false
  property bool applyPending: false
  property bool probeHandled: false

  // Sample slots, filled by the FileView callbacks for the current cycle only.
  property var sampleCct: null
  property var sampleLux: null
  property var sampleX: null
  property var sampleY: null

  property real cctScale: 0.001
  property real luxScale: 0.001
  property real xyScale: 0.001

  readonly property bool busy: probePending || samplePending || applyPending
  readonly property bool active: enabled && ready && sensorHasColor && !yielded && transportOk

  readonly property string statusText: {
    if (!ready) return "starting"
    if (!sensorHasColor) return unavailableReason
    if (!enabled) return "off"
    if (!transportOk) return "hyprsunset unavailable"
    if (yielded) return "paused (Night Light)"
    if (!reading) return "no reading"
    if (!Model.hasUsableLight(reading.lux, opts)) return "too dark to sample"
    return Model.describe(reading, targetK)
  }

  // ---- enable / disable ----------------------------------------------------

  function setEnabled(value) {
    if (root.enabled === value) return
    root.enabled = value

    saveState()

    // Abandon anything in flight so a late callback cannot act for the state
    // we just left.
    abandonInFlight()

    if (!value) {
      // Ask the display who owns it before handing anything back.
      root.releaseOnNextProbe = true
      startProbe()
    } else {
      root.lastSetK = null
      root.smoothedCct = null
      root.previousCct = null
      root.settled = false
      root.adoptOnNextProbe = true
      root.yielded = false
      tick()
    }
  }

  function toggle() { setEnabled(!enabled) }

  function abandonInFlight() {
    root.probePending = false
    root.samplePending = false
    root.probeHandled = true      // ignore any probe result still coming
    root.sampleCct = null
    root.sampleLux = null
  }

  // ---- settings ------------------------------------------------------------

  function setSetting(key, value) {
    if (!isFinite(value)) return
    if (key === "strength") root.strength = Math.max(0, Math.min(1, value))
    else if (key === "minKelvin") root.minKelvin = Math.round(Math.min(value, root.maxKelvin))
    else if (key === "maxKelvin") root.maxKelvin = Math.round(Math.max(Math.min(value, Model.NEUTRAL_K), root.minKelvin))
    else if (key === "luxFloor") root.luxFloor = Math.round(value)
    else if (key === "maxStepK") root.maxStepK = Math.max(1, Math.round(value))
    else if (key === "pollIntervalSec") root.pollIntervalSec = Math.max(1, Math.round(value))
    else return

    if (root.reading) {
      root.targetK = Model.adaptTarget(root.smoothedCct !== null ? root.smoothedCct : root.reading.cct, opts)
    }
    root.settled = false
    saveDebounce.restart()
  }

  function resetSettings() {
    root.strength = Model.DEFAULTS.strength
    root.minKelvin = Model.DEFAULTS.minKelvin
    root.maxKelvin = Model.NEUTRAL_K
    root.luxFloor = Model.DEFAULTS.luxFloor
    root.maxStepK = 150
    root.pollIntervalSec = 2
    if (root.reading) root.targetK = Model.adaptTarget(root.reading.cct, opts)
    root.settled = false
    saveDebounce.restart()
  }

  // ---- the loop ------------------------------------------------------------

  function runnable() {
    return root.ready && root.sensorBound && root.sensorHasColor && root.enabled
  }

  function tick() {
    if (!runnable() || root.busy) return

    // Always re-establish ownership before anything that could write. An
    // earlier version skipped the probe on most settled ticks to save a
    // subprocess; measured, hyprctl costs 2.6ms, and the skip bought nothing
    // while leaving up to 60s in which Night Light could take the display
    // without us noticing. Probing every tick is cheaper than being wrong.
    startProbe()
  }

  function startProbe() {
    root.probePending = true
    root.probeHandled = false
    probeProcess.running = true
  }

  // Called from stdout and from onExited; the first one wins.
  function onProbeResult(temp) {
    if (root.probeHandled) return
    root.probeHandled = true
    root.probePending = false

    if (temp === null || temp === undefined) {
      // hyprctl did not answer. Unknown is not neutral: guessing neutral here
      // used to clear a legitimate yield and then write over Night Light.
      root.transportOk = false
      root.settled = false
      return
    }

    root.transportOk = true
    root.appliedK = temp

    var own = Model.evaluateOwnership(temp, root.lastSetK)

    // Disable path: restore neutral only if the display is still showing what
    // we put there. If something else took it meanwhile, leave it alone.
    if (root.releaseOnNextProbe) {
      root.releaseOnNextProbe = false
      root.yielded = false
      if (own.owned && !own.atNeutral) applyTemperature(Model.NEUTRAL_K)
      return
    }

    if (root.adoptOnNextProbe) {
      root.adoptOnNextProbe = false
      root.yielded = false
      // Claim the CURRENT value as ours. Clearing it instead left the next
      // probe with nothing to recognise, so the adopt lasted exactly one tick
      // and then re-yielded.
      root.lastSetK = temp
    } else {
      root.yielded = own.shouldYield
      if (root.yielded) {
        root.settled = false
        return
      }
    }
    // Taking a free display: forget any stale value so the first write is a
    // clean jump rather than a ramp from something we no longer hold.
    if (!own.owned && own.atNeutral) root.lastSetK = null

    if (!root.enabled) return
    startSample()
  }

  // ---- sampling ------------------------------------------------------------

  // One cycle at a time. reload() is asynchronous with no ordering guarantee,
  // so the cycle completes only when both required files have reported, rather
  // than assuming the last reload issued is the last to land.
  function startSample() {
    if (!runnable()) return
    root.samplePending = true
    root.sampleCct = null
    root.sampleLux = null
    sampleWatchdog.restart()
    luxFile.reload()
    chromaXFile.reload()
    chromaYFile.reload()
    cctFile.reload()
  }

  function noteSample(which, value) {
    if (!root.samplePending) return   // stale arrival from an abandoned cycle
    if (which === "cct") root.sampleCct = value
    else if (which === "lux") root.sampleLux = value
    else if (which === "x") root.sampleX = value
    else if (which === "y") root.sampleY = value

    if (root.sampleCct !== null && root.sampleLux !== null) completeSample()
  }

  function completeSample() {
    root.samplePending = false
    sampleWatchdog.stop()

    // The state may have changed while the reads were in flight.
    if (!runnable() || root.yielded || !root.transportOk) return

    var cct = root.sampleCct * root.cctScale
    var lux = root.sampleLux * root.luxScale
    if (!isFinite(cct) || !isFinite(lux) || cct <= 0) return

    root.reading = {
      cct: cct,
      lux: lux,
      x: root.sampleX !== null ? root.sampleX * root.xyScale : null,
      y: root.sampleY !== null ? root.sampleY * root.xyScale : null
    }

    if (!Model.hasUsableLight(lux, opts)) {
      root.previousCct = cct
      root.settled = true
      return
    }

    root.smoothedCct = Model.smooth(root.smoothedCct, cct, opts)
    root.targetK = Model.adaptTarget(root.smoothedCct, opts)

    var step = Model.nextStep(root.appliedK, root.targetK, opts)
    if (step !== null) applyTemperature(step)

    root.settled = Model.isSettled({
      appliedK: root.appliedK,
      targetK: root.targetK,
      cct: cct,
      previousCct: root.previousCct
    }, opts)
    root.previousCct = cct
  }

  // ---- applying ------------------------------------------------------------

  // Direct argv, no shell. lastSetK and appliedK are only advanced once the
  // command has actually succeeded; recording them optimistically meant a
  // probe landing mid-apply saw the old value and called it a takeover.
  property var pendingApplyK: null

  function applyTemperature(temp) {
    if (root.applyPending) return
    root.pendingApplyK = Math.round(temp)
    root.applyPending = true
    applyProcess.command = ["hyprctl", "hyprsunset", "temperature", String(root.pendingApplyK)]
    applyProcess.running = true
  }

  // ---- sensor files --------------------------------------------------------

  FileView {
    id: cctFile; watchChanges: false; printErrors: false
    onLoaded: root.noteSample("cct", parseFloat(text()))
    onLoadFailed: root.samplePending = false
  }
  FileView {
    id: luxFile; watchChanges: false; printErrors: false
    onLoaded: root.noteSample("lux", parseFloat(text()))
    onLoadFailed: root.samplePending = false
  }
  FileView {
    id: chromaXFile; watchChanges: false; printErrors: false
    onLoaded: root.noteSample("x", parseFloat(text()))
  }
  FileView {
    id: chromaYFile; watchChanges: false; printErrors: false
    onLoaded: root.noteSample("y", parseFloat(text()))
  }

  FileView {
    id: cctScaleFile; watchChanges: false; printErrors: false
    onLoaded: { var v = parseFloat(text()); if (isFinite(v) && v > 0) root.cctScale = v; root.markScaleLoaded() }
    onLoadFailed: root.markScaleLoaded()
  }
  FileView {
    id: luxScaleFile; watchChanges: false; printErrors: false
    onLoaded: { var v = parseFloat(text()); if (isFinite(v) && v > 0) root.luxScale = v; root.markScaleLoaded() }
    onLoadFailed: root.markScaleLoaded()
  }
  FileView {
    id: xyScaleFile; watchChanges: false; printErrors: false
    onLoaded: { var v = parseFloat(text()); if (isFinite(v) && v > 0) root.xyScale = v; root.markScaleLoaded() }
    onLoadFailed: root.markScaleLoaded()
  }

  property int scalesLoaded: 0

  // Scales must be known before a reading can be converted, so the loop does
  // not start until all three have reported one way or the other.
  function markScaleLoaded() {
    root.scalesLoaded++
    if (root.scalesLoaded >= 3 && !root.sensorBound) {
      root.sensorBound = true
      ensureProcess.running = true
    }
  }

  function bindSensorFiles(path) {
    cctScaleFile.path = path + "/in_colortemp_scale"
    luxScaleFile.path = path + "/in_illuminance_scale"
    xyScaleFile.path = path + "/in_chromaticity_scale"
    cctFile.path = path + "/in_colortemp_raw"
    luxFile.path = path + "/in_illuminance_raw"
    chromaXFile.path = path + "/in_chromaticity_x_raw"
    chromaYFile.path = path + "/in_chromaticity_y_raw"
  }

  // ---- processes -----------------------------------------------------------

  Process {
    id: scanProcess
    command: Model.scanCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var picked = Model.pickSensor(Model.parseScan(text))
        if (!picked) {
          root.unavailableReason = "no ambient light sensor"
        } else if (!picked.hasColortemp) {
          root.sensorPath = picked.path
          root.unavailableReason = "sensor has no color channel"
        } else {
          root.sensorPath = picked.path
          root.sensorHasColor = true
          root.bindSensorFiles(picked.path)
        }
        root.ready = true
      }
    }
  }

  Process {
    id: ensureProcess
    command: ["bash", "-lc",
      "pgrep -x hyprsunset >/dev/null || { setsid uwsm-app -- hyprsunset >/dev/null 2>&1 & sleep 1; }"]
    onExited: root.tick()
  }

  Process {
    id: probeProcess
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onProbeResult(Model.temperatureFromOutput(text))
    }
    onExited: function (code) {
      if (code !== 0) root.onProbeResult(null)
      else if (root.probePending) root.onProbeResult(null)  // exited clean but said nothing
    }
  }

  Process {
    id: applyProcess
    onExited: function (code) {
      root.applyPending = false
      if (code === 0 && root.pendingApplyK !== null) {
        root.lastSetK = root.pendingApplyK
        root.appliedK = root.pendingApplyK
        root.transportOk = true
        root.saveState()
      } else if (code !== 0) {
        // The display did not move. Do not pretend it did.
        root.transportOk = false
        root.settled = false
      }
      root.pendingApplyK = null
    }
  }

  Process { id: persist }
  Process { id: saveProcess }

  // Debounced so a ramp does not write the state file once per 150K step.
  function saveState() { stateDebounce.restart() }

  Timer {
    id: stateDebounce
    interval: 1500
    repeat: false
    onTriggered: {
      persist.command = Model.saveStateCommand(root.enabled, root.lastSetK)
      persist.running = true
    }
  }

  Process {
    id: restore
    command: Model.loadStateCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var st = Model.parseState(text)
        root.enabled = st.enabled
        // Remembering what we last wrote is what lets the ownership check
        // recognise our own leftover value after a shell restart instead of
        // treating it as somebody else's and parking.
        root.lastSetK = st.lastSetK
      }
    }
  }

  Process {
    id: loadConfig
    command: Model.loadConfigCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var c = Model.parseConfig(text)
        if (c.strength !== undefined) root.strength = c.strength
        if (c.minKelvin !== undefined) root.minKelvin = c.minKelvin
        if (c.maxKelvin !== undefined) root.maxKelvin = c.maxKelvin
        if (c.luxFloor !== undefined) root.luxFloor = c.luxFloor
        if (c.maxStepK !== undefined) root.maxStepK = c.maxStepK
        if (c.pollIntervalSec !== undefined) root.pollIntervalSec = c.pollIntervalSec
        // Only start the sensor scan once the persisted enable state and the
        // config are in hand, so the first tick acts on the real settings.
        scanProcess.running = true
      }
    }
  }

  // If a sample cycle never completes, drop it rather than wedging the loop.
  Timer {
    id: sampleWatchdog
    interval: 5000
    repeat: false
    onTriggered: { root.samplePending = false; root.sampleCct = null; root.sampleLux = null }
  }

  Timer {
    id: saveDebounce
    interval: 600
    repeat: false
    onTriggered: {
      saveProcess.command = Model.saveConfigCommand({
        strength: root.strength,
        minKelvin: root.minKelvin,
        maxKelvin: root.maxKelvin,
        luxFloor: root.luxFloor,
        maxStepK: root.maxStepK,
        pollIntervalSec: root.pollIntervalSec
      })
      saveProcess.running = true
    }
  }

  Timer {
    id: loop
    interval: Model.pollIntervalFor(root.settled, root.pollIntervalSec, root.idleIntervalSec) * 1000
    running: root.ready && root.sensorBound && root.sensorHasColor && root.enabled
    repeat: true
    onTriggered: root.tick()
  }

  Component.onCompleted: {
    restore.running = true
    loadConfig.running = true   // chains into scanProcess
  }

  IpcHandler {
    target: "truetone"

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        active: root.active,
        yielded: root.yielded,
        transportOk: root.transportOk,
        settled: root.settled,
        pollSeconds: Model.pollIntervalFor(root.settled, root.pollIntervalSec, root.idleIntervalSec),
        sensor: root.sensorPath,
        hasColorChannel: root.sensorHasColor,
        reason: root.unavailableReason,
        roomKelvin: root.reading ? Math.round(root.reading.cct) : null,
        lux: root.reading ? Math.round(root.reading.lux) : null,
        targetKelvin: root.targetK,
        appliedKelvin: root.appliedK,
        text: root.statusText
      })
    }

    function enable(): string { root.setEnabled(true); return "enabled" }
    function disable(): string { root.setEnabled(false); return "disabled" }
    function toggle(): string { root.toggle(); return root.enabled ? "enabled" : "disabled" }
    function refresh(): void { root.settled = false; root.tick() }

    // Explicit "take the display back" without cycling the enable flag.
    function adopt(): string {
      root.adoptOnNextProbe = true
      root.yielded = false
      root.settled = false
      root.tick()
      return "adopting"
    }
  }
}

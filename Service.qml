import QtQuick
import Quickshell.Io
import "TrueToneModel.js" as Model

// Reads the ambient color sensor and moves the display white point to match.
// Applies through hyprsunset, the same surface Omarchy's own Night Light uses,
// and yields the moment Night Light or the user takes it.
//
// Cost discipline, because this runs forever on a laptop:
//   - sysfs is read in process via FileView, never through a subprocess
//   - no shell anywhere in the steady state (`bash -lc` costs ~20ms of CPU
//     per spawn, mostly sourcing the login profile)
//   - polling backs off from 2s to 20s once the room stops changing
//   - hyprctl is only called when the temperature actually needs to move
Item {
  id: root

  property var shell: null

  // ---- configuration -------------------------------------------------------
  property real strength: 0.5
  property int minKelvin: 3800
  property int maxKelvin: Model.NEUTRAL_K
  property int luxFloor: 3
  property int maxStepK: 150
  property int pollIntervalSec: 2        // fast cadence, while things move
  property int idleIntervalSec: 20       // relaxed cadence, once settled

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
  property string sensorPath: ""
  property bool sensorHasColor: false
  property string unavailableReason: ""

  property var reading: null
  property var smoothedCct: null
  property var previousCct: null
  property var targetK: null
  property var appliedK: null
  property var lastSetK: null
  property bool yielded: false

  property bool settled: false
  property int ticksSinceProbe: 99

  // Sysfs scales, read once. Always 0.001 on the hardware seen so far, but
  // the kernel is free to say otherwise.
  property real cctScale: 0.001
  property real luxScale: 0.001
  property real xyScale: 0.001

  readonly property bool active: enabled && ready && sensorHasColor && !yielded

  readonly property string statusText: {
    if (!ready) return "starting"
    if (!sensorHasColor) return unavailableReason
    if (!enabled) return "off"
    if (yielded) return "paused (Night Light)"
    if (!reading) return "no reading"
    if (!Model.hasUsableLight(reading.lux, opts)) return "too dark to sample"
    return Model.describe(reading, targetK)
  }

  // ---- lifecycle -----------------------------------------------------------

  function setEnabled(value) {
    if (root.enabled === value) return
    root.enabled = value
    persist.command = ["bash", "-lc",
      "mkdir -p ~/.local/state/omarchy-truetone && printf '%s' " +
      (value ? "1" : "0") + " > ~/.local/state/omarchy-truetone/enabled"]
    persist.running = true

    if (!value) {
      root.yielded = false
      applyTemperature(Model.NEUTRAL_K)
    } else {
      root.lastSetK = null
      root.smoothedCct = null
      root.settled = false
      root.ticksSinceProbe = 99
      tick()
    }
  }

  function toggle() { setEnabled(!enabled) }

  function setSetting(key, value) {
    if (!isFinite(value)) return
    if (key === "strength") root.strength = Math.max(0, Math.min(1, value))
    else if (key === "minKelvin") root.minKelvin = Math.round(Math.min(value, root.maxKelvin))
    else if (key === "maxKelvin") root.maxKelvin = Math.round(Math.max(Math.min(value, Model.NEUTRAL_K), root.minKelvin))
    else if (key === "luxFloor") root.luxFloor = Math.round(value)
    else if (key === "maxStepK") root.maxStepK = Math.round(value)
    else if (key === "pollIntervalSec") root.pollIntervalSec = Math.round(value)
    else return

    if (root.reading) {
      root.targetK = Model.adaptTarget(root.smoothedCct !== null ? root.smoothedCct : root.reading.cct, opts)
    }
    // A settings change is a change: wake back up so it takes effect now.
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

  function tick() {
    if (!ready || !sensorHasColor || !enabled) return

    // The probe is the only subprocess left in the steady state, so skip it
    // when nothing is moving.
    if (Model.shouldProbe(root.ticksSinceProbe, root.settled)) {
      root.ticksSinceProbe = 0
      if (!probeProcess.running) probeProcess.running = true
      return   // onProbed continues into the sensor read
    }

    root.ticksSinceProbe++
    readSensor()
  }

  function onProbed(appliedTemp) {
    root.appliedK = appliedTemp

    if (Model.externallyChanged(appliedTemp, root.lastSetK)) {
      if (Math.abs(appliedTemp - Model.NEUTRAL_K) <= 60) {
        root.yielded = false
        root.lastSetK = null
      } else {
        root.yielded = true
        root.settled = false
        return
      }
    }

    readSensor()
  }

  // In process, no fork. This is the hot path and it costs microseconds.
  function readSensor() {
    luxFile.reload()
    chromaXFile.reload()
    chromaYFile.reload()
    cctFile.reload()   // last, so the others are already fresh in onLoaded
  }

  function onSensorRead() {
    var cct = parseFloat(cctFile.text()) * root.cctScale
    var lux = parseFloat(luxFile.text()) * root.luxScale
    if (!isFinite(cct) || !isFinite(lux)) return

    var x = parseFloat(chromaXFile.text())
    var y = parseFloat(chromaYFile.text())
    root.reading = {
      cct: cct,
      lux: lux,
      x: isFinite(x) ? x * root.xyScale : null,
      y: isFinite(y) ? y * root.xyScale : null
    }

    if (!Model.hasUsableLight(lux, opts)) {
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

  // Direct argv. No shell: hyprsunset is started once at boot instead.
  function applyTemperature(temp) {
    root.lastSetK = temp
    root.appliedK = temp
    applyProcess.command = ["hyprctl", "hyprsunset", "temperature", String(Math.round(temp))]
    applyProcess.running = true
  }

  // ---- sensor files --------------------------------------------------------

  FileView { id: cctFile;     watchChanges: false; printErrors: false; onLoaded: root.onSensorRead() }
  FileView { id: luxFile;     watchChanges: false; printErrors: false }
  FileView { id: chromaXFile; watchChanges: false; printErrors: false }
  FileView { id: chromaYFile; watchChanges: false; printErrors: false }

  FileView {
    id: cctScaleFile
    watchChanges: false
    printErrors: false
    onLoaded: { var v = parseFloat(text()); if (isFinite(v) && v > 0) root.cctScale = v }
  }
  FileView {
    id: luxScaleFile
    watchChanges: false
    printErrors: false
    onLoaded: { var v = parseFloat(text()); if (isFinite(v) && v > 0) root.luxScale = v }
  }
  FileView {
    id: xyScaleFile
    watchChanges: false
    printErrors: false
    onLoaded: { var v = parseFloat(text()); if (isFinite(v) && v > 0) root.xyScale = v }
  }

  function bindSensorFiles(path) {
    cctFile.path = path + "/in_colortemp_raw"
    luxFile.path = path + "/in_illuminance_raw"
    chromaXFile.path = path + "/in_chromaticity_x_raw"
    chromaYFile.path = path + "/in_chromaticity_y_raw"
    cctScaleFile.path = path + "/in_colortemp_scale"
    luxScaleFile.path = path + "/in_illuminance_scale"
    xyScaleFile.path = path + "/in_chromaticity_scale"
  }

  // ---- processes -----------------------------------------------------------

  // Runs once at startup. The only shell this plugin spawns in normal use.
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
        if (root.sensorHasColor) {
          ensureProcess.running = true   // start hyprsunset once, then tick
        }
      }
    }
  }

  // Start hyprsunset if it is not up. Once, at startup, rather than guarding
  // every single apply with a pgrep.
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
      onStreamFinished: root.onProbed(Model.temperatureFromOutput(text))
    }
    onExited: function (code) {
      if (code !== 0) root.onProbed(Model.NEUTRAL_K)
    }
  }

  Process { id: applyProcess }
  Process { id: persist }
  Process { id: saveProcess }

  Process {
    id: restore
    command: ["bash", "-lc", "cat ~/.local/state/omarchy-truetone/enabled 2>/dev/null || echo 1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.enabled = String(text).trim() !== "0"
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
      }
    }
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
    running: root.ready && root.sensorHasColor && root.enabled
    repeat: true
    onTriggered: root.tick()
  }

  Component.onCompleted: {
    loadConfig.running = true
    restore.running = true
    scanProcess.running = true
  }

  IpcHandler {
    target: "truetone"

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        active: root.active,
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
  }
}

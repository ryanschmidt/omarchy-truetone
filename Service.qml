import QtQuick
import Quickshell.Io
import "TrueToneModel.js" as Model

// Reads the ambient color sensor and moves the display white point to match.
// Applies through hyprsunset, the same surface Omarchy's own Night Light uses,
// and yields the moment Night Light or the user takes it.
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

  property var reading: null        // { cct, lux, x, y }
  property var smoothedCct: null    // EMA of reading.cct
  property var targetK: null        // where we want the display
  property var appliedK: null       // where the display currently is
  property var lastSetK: null       // the last value WE set
  property bool yielded: false      // something else owns the display

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

  function start() {
    scanProcess.running = true
  }

  function setEnabled(value) {
    if (root.enabled === value) return
    root.enabled = value
    persist.command = ["bash", "-lc",
      "mkdir -p ~/.local/state/omarchy-truetone && printf '%s' " +
      (value ? "1" : "0") + " > ~/.local/state/omarchy-truetone/enabled"]
    persist.running = true

    if (!value) {
      // Hand the display back cleanly rather than freezing at a warm value.
      root.yielded = false
      apply(Model.NEUTRAL_K)
    } else {
      root.lastSetK = null
      root.smoothedCct = null
      tick()
    }
  }

  function toggle() { setEnabled(!enabled) }

  // ---- the loop ------------------------------------------------------------

  function tick() {
    if (!ready || !sensorHasColor) return
    if (!enabled) return
    if (readProcess.running || applyProcess.running) return
    probeProcess.running = true   // chains into readProcess on exit
  }

  function onProbed(appliedTemp) {
    root.appliedK = appliedTemp

    if (Model.externallyChanged(appliedTemp, root.lastSetK)) {
      // Night Light (or a keybind, or ssh) moved the temperature. Stand down.
      if (Math.abs(appliedTemp - Model.NEUTRAL_K) <= 60) {
        // Back at identity: the field is clear, we can resume.
        root.yielded = false
        root.lastSetK = null
      } else {
        root.yielded = true
        return
      }
    }

    readProcess.command = Model.readCommand(root.sensorPath)
    readProcess.running = true
  }

  function onRead(text) {
    var r = Model.parseReading(text)
    if (!r) return
    root.reading = r

    // Below the floor the color channel is noise. Hold the last good target
    // rather than lurching somewhere arbitrary.
    if (!Model.hasUsableLight(r.lux, opts)) return

    root.smoothedCct = Model.smooth(root.smoothedCct, r.cct, opts)
    root.targetK = Model.adaptTarget(root.smoothedCct, opts)

    var step = Model.nextStep(root.appliedK, root.targetK, opts)
    if (step !== null) apply(step)
  }

  function apply(temp) {
    root.lastSetK = temp
    root.appliedK = temp
    applyProcess.command = ["bash", "-lc",
      "pgrep -x hyprsunset >/dev/null || { setsid uwsm-app -- hyprsunset >/dev/null 2>&1 & sleep 1; }; " +
      "hyprctl hyprsunset temperature " + Number(temp)]
    applyProcess.running = true
  }

  // ---- processes -----------------------------------------------------------

  // ponytail: one bash round trip per tick. Fine at a 2s poll; if this ever
  // shows up in power measurements, switch to an IIO buffer reader held open.
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
        }
        root.ready = true
        if (root.sensorHasColor) root.tick()
      }
    }
  }

  Process {
    id: probeProcess
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onProbed(Model.temperatureFromOutput(text))
    }
    onExited: function (code) {
      // hyprsunset not running yet: nothing owns the display, so proceed.
      if (code !== 0) root.onProbed(Model.NEUTRAL_K)
    }
  }

  Process {
    id: readProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onRead(text)
    }
  }

  Process { id: applyProcess }
  Process { id: persist }

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
    interval: Math.max(1, root.pollIntervalSec) * 1000
    running: root.ready && root.sensorHasColor && root.enabled
    repeat: true
    onTriggered: root.tick()
  }

  Component.onCompleted: {
    loadConfig.running = true
    restore.running = true
    start()
  }

  IpcHandler {
    target: "truetone"

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        active: root.active,
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
    function refresh(): void { root.tick() }
  }
}

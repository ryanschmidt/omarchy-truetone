import QtQuick
import Quickshell
import Quickshell.Io
import "TrueToneModel.js" as Model

// Matches the display white point to the colour of the room.
//
// It writes to a wlr-gamma-control ramp through a small resident helper, and
// never touches hyprsunset's colour transform matrix. That matrix belongs to
// Omarchy's Night Light, which holds it exclusively, and the compositor
// composes the two channels at scanout. So the two features stack the way
// True Tone and Night Shift do on a Mac, neither aware of the other, and
// Night Light's own toggle keeps working because nothing here disturbs it.
//
// There are no settings, the same as on a Mac. It is on or off.
Item {
  id: root

  property var shell: null

  // ---- state ---------------------------------------------------------------
  property bool enabled: true
  property bool ready: false
  property bool sensorBound: false
  property string sensorPath: ""
  property bool sensorHasColor: false
  property string unavailableReason: ""

  property bool helperReady: false
  property string helperError: ""
  property int outputCount: 0

  property var reading: null          // { cct, lux, x, y }
  property var smoothed: null    // EMA of { cct, x, y }, smoothed together
  property var previousCct: null
  property var targetGains: null
  property var appliedGains: null
  property var targetK: null
  property bool settled: false

  property bool samplePending: false
  property var sampleCct: null
  property var sampleLux: null
  property var sampleX: null
  property var sampleY: null

  property real cctScale: 0.001
  property real luxScale: 0.001
  property real xyScale: 0.001
  property int scalesLoaded: 0

  readonly property bool supported: ready && sensorHasColor && helperReady
  readonly property bool active: supported && enabled

  readonly property string statusText: {
    if (!ready) return "starting"
    if (!sensorHasColor) return unavailableReason
    if (helperError !== "") return helperError
    if (!helperReady) return "starting"
    if (!enabled) return "off"
    if (!reading) return "no reading"
    if (!Model.hasUsableLight(reading.lux)) return "too dark to sample"
    return Model.describe(reading, targetK)
  }

  // ---- enable / disable ----------------------------------------------------

  function setEnabled(value) {
    if (root.enabled === value) return
    root.enabled = value
    persist.command = Model.saveStateCommand(value)
    persist.running = true

    root.samplePending = false

    if (!value) {
      sendGains(null)
      root.appliedGains = Model.IDENTITY_GAINS
      root.targetGains = null
      root.targetK = null
    } else {
      root.smoothed = null
      root.previousCct = null
      root.settled = false
      tick()
    }
  }

  function toggle() { setEnabled(!enabled) }

  // ---- the loop ------------------------------------------------------------

  function runnable() {
    return root.ready && root.sensorBound && root.sensorHasColor
      && root.helperReady && root.enabled
  }

  function tick() {
    if (!runnable() || root.samplePending) return
    root.samplePending = true
    root.sampleCct = null
    root.sampleLux = null
    root.sampleX = null
    root.sampleY = null
    sampleWatchdog.restart()
    // reload() is asynchronous with no ordering guarantee, so the cycle
    // completes on the arrival of both required values, not on the last
    // reload issued.
    luxFile.reload()
    chromaXFile.reload()
    chromaYFile.reload()
    cctFile.reload()
  }

  function noteSample(which, value) {
    // Chromaticity is advisory and frequently lands after cct and lux have
    // already closed the cycle. Dropping it as "late" silently disabled the
    // off-locus correction, which is the entire reason for reading a colour
    // sensor rather than a lux one. Accept it whenever it arrives.
    if (!root.samplePending) return
    if (which === "cct") root.sampleCct = value
    else if (which === "lux") root.sampleLux = value
    else if (which === "x") root.sampleX = value
    else if (which === "y") root.sampleY = value

    // Wait for the whole set so chromaticity and temperature describe the
    // same instant. The watchdog covers a channel that never arrives.
    if (root.sampleCct !== null && root.sampleLux !== null
        && root.sampleX !== null && root.sampleY !== null) completeSample()
  }

  function completeSample() {
    root.samplePending = false
    sampleWatchdog.stop()
    if (!runnable()) return

    var cct = root.sampleCct * root.cctScale
    var lux = root.sampleLux * root.luxScale
    if (!isFinite(cct) || !isFinite(lux) || cct <= 0) return

    var x = (root.sampleX !== null && isFinite(root.sampleX)) ? root.sampleX * root.xyScale : null
    var y = (root.sampleY !== null && isFinite(root.sampleY)) ? root.sampleY * root.xyScale : null
    root.reading = { cct: cct, lux: lux, x: x, y: y }

    // Below the floor the colour channel is noise. Hold the last good value.
    if (!Model.hasUsableLight(lux)) {
      root.previousCct = cct
      root.settled = true
      return
    }

    root.smoothed = Model.smoothReading(root.smoothed, { cct: cct, x: x, y: y })
    var goal = Model.adaptGains(root.smoothed.cct, root.smoothed.x, root.smoothed.y)
    if (goal) {
      root.targetGains = { r: goal.r, g: goal.g, b: goal.b }
      root.targetK = goal.targetK
    }

    var step = Model.stepGains(root.appliedGains, root.targetGains)
    if (step) {
      root.appliedGains = step
      sendGains(step)
    }

    root.settled = Model.isSettled({
      appliedGains: root.appliedGains,
      targetGains: root.targetGains,
      cct: cct,
      previousCct: root.previousCct
    })
    root.previousCct = cct
  }

  // The helper watches this file with inotify. Written through FileView so a
  // ramp step costs no subprocess; atomicWrites renames into place, which is
  // why the helper watches the directory for IN_MOVED_TO as well.
  readonly property string gainsPath: {
    var home = Quickshell.env("HOME") || ""
    return home + "/.local/state/omarchy-truetone/gains"
  }

  function sendGains(gains) {
    gainsFile.setText(gains
      ? gains.r.toFixed(3) + " " + gains.g.toFixed(3) + " " + gains.b.toFixed(3) + "\n"
      : "1.000 1.000 1.000\n")
  }

  FileView {
    id: gainsFile
    path: root.gainsPath
    atomicWrites: true
    watchChanges: false
    printErrors: false
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

  // Scales must be known before a reading can be converted.
  function markScaleLoaded() {
    root.scalesLoaded++
    if (root.scalesLoaded >= 3 && !root.sensorBound) {
      root.sensorBound = true
      prepare.running = true   // builds if needed, then starts the helper
    }
  }

  // Prepare, then start. The helper is compiled on first run so that
  // `omarchy plugin add` is genuinely all a user has to do; gcc and
  // wayland-scanner are present on any Hyprland system.
  Process {
    id: prepare
    command: ["bash", "-lc",
      "mkdir -p ~/.local/state/omarchy-truetone && " +
      "cd " + JSON.stringify(root.pluginDir) + " && " +
      "[ -x ./truetone-gamma ] || ./build.sh"]
    stderr: SplitParser { onRead: function (l) { console.warn("truetone build: " + l) } }
    onExited: function (code) {
      if (code !== 0) root.helperError = "could not build the gamma helper"
      else root.startHelper()
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

  // ---- the gamma helper ----------------------------------------------------

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace("file://", "").replace(/\/$/, "")
  readonly property string helperPath: root.pluginDir + "/truetone-gamma"

  function startHelper() {
    helper.command = [root.helperPath, root.gainsPath]
    helper.running = true
  }

  // A resident client, because the compositor drops the ramp the instant its
  // client disconnects. On exit the original ramps are restored, which is the
  // behaviour we want on shutdown or a crash.
  Process {
    id: helper
    stdout: SplitParser {
      onRead: function (line) {
        var s = String(line).trim()
        if (s.indexOf("READY") === 0) {
          root.outputCount = parseInt(s.split(" ")[1]) || 0
          root.helperReady = true
          root.helperError = ""
          if (root.enabled) root.tick()
        }
      }
    }
    stderr: SplitParser {
      onRead: function (line) { console.warn("truetone-gamma: " + line) }
    }
    onExited: function (code) {
      root.helperReady = false
      root.appliedGains = null
      if (code !== 0) {
        root.helperError = "gamma helper failed, run build.sh"
      }
    }
  }

  // ---- startup -------------------------------------------------------------

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
          root.unavailableReason = "sensor reports brightness only, not colour"
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
    id: restore
    command: Model.loadStateCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.enabled = Model.parseState(text)
        scanProcess.running = true
      }
    }
  }

  Process { id: persist }

  Timer {
    id: sampleWatchdog
    interval: 5000
    repeat: false
    onTriggered: { root.samplePending = false; root.sampleCct = null; root.sampleLux = null }
  }

  Timer {
    id: loop
    interval: Model.pollIntervalFor(root.settled) * 1000
    running: root.runnable()
    repeat: true
    onTriggered: root.tick()
  }

  Component.onCompleted: restore.running = true

  IpcHandler {
    target: "truetone"

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        active: root.active,
        supported: root.supported,
        settled: root.settled,
        pollSeconds: Model.pollIntervalFor(root.settled),
        sensor: root.sensorPath,
        hasColorChannel: root.sensorHasColor,
        helperReady: root.helperReady,
        outputs: root.outputCount,
        reason: root.unavailableReason || root.helperError,
        roomKelvin: root.reading ? Math.round(root.reading.cct) : null,
        lux: root.reading ? Math.round(root.reading.lux) : null,
        chromaticity: root.reading && root.reading.x !== null
          ? { x: root.reading.x, y: root.reading.y } : null,
        targetKelvin: root.targetK,
        gains: root.appliedGains,
        text: root.statusText
      })
    }

    function enable(): string { root.setEnabled(true); return "enabled" }
    function disable(): string { root.setEnabled(false); return "disabled" }
    function toggle(): string { root.toggle(); return root.enabled ? "enabled" : "disabled" }
    function refresh(): void { root.settled = false; root.tick() }
  }
}

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar control for True Tone. Click toggles; the tooltip carries the live
// sensor reading, which is the thing you actually want when you are deciding
// whether the screen looks odd because of the room or because of the plugin.
BarWidget {
  id: root
  moduleName: "ryanschmidt.truetone"

  // The service does the work. Binding straight to it beats polling our own
  // copy of the sensor: one reader, one source of truth.
  readonly property var service: bar?.shell?.serviceFor("ryanschmidt.truetone")

  readonly property bool serviceReady: !!service && service.ready === true
  readonly property bool supported: serviceReady && service.sensorHasColor === true
  readonly property bool on: supported && service.enabled === true
  readonly property bool adapting: supported && service.active === true

  readonly property int roomKelvin: (serviceReady && service.reading) ? Math.round(service.reading.cct) : 0
  readonly property var targetKelvin: serviceReady ? service.targetK : null

  readonly property bool showKelvin: setting("showRoomKelvin", true) && adapting && roomKelvin > 0
  readonly property string kelvinLabel: roomKelvin > 0 ? (roomKelvin + "K") : ""

  readonly property bool verticalBar: bar ? bar.vertical : false
  readonly property color foreground: bar ? bar.foreground : Color.foreground

  readonly property string tooltip: {
    if (!serviceReady) return "True Tone · starting"
    if (!supported) return "True Tone · " + (service.unavailableReason || "unsupported")
    if (!service.enabled) return "True Tone · off"
    if (service.yielded) return "True Tone · paused while Night Light is on"
    if (!service.reading) return "True Tone · waiting for a reading"

    var parts = ["True Tone · " + roomKelvin + "K room"]
    if (service.reading.lux !== undefined) parts.push(Math.round(service.reading.lux) + " lux")
    if (targetKelvin) parts.push("display at " + targetKelvin + "K")
    return parts.join(" · ")
  }

  function toggle() {
    if (service && service.toggle) service.toggle()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  TextMetrics {
    id: kelvinMetrics
    text: root.kelvinLabel
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.caption
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    dimmed: !root.adapting
    fixedWidth: root.verticalBar || !root.showKelvin
      ? -1
      : Style.bar.iconSlot + Style.space(5) + Math.ceil(kelvinMetrics.width)
    tooltipText: root.tooltip

    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            // mdi brightness-auto: the display adjusting itself.
            text: "󰃝"
            color: root.adapting ? Color.accent : root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.space(11)
          }

          Text {
            visible: root.showKelvin && !root.verticalBar
            anchors.verticalCenter: parent.verticalCenter
            text: root.kelvinLabel
            color: root.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    // Left toggles. Right forces a re-read, which is the useful thing when
    // you have just changed a bulb and do not want to wait for the poll.
    onPressed: function (mouseButton) {
      if (mouseButton === Qt.RightButton) {
        if (root.service && root.service.tick) root.service.tick()
      } else {
        root.toggle()
      }
    }
  }
}

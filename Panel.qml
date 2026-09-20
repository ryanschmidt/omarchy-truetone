import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon plus the True Tone panel. The icon stays a plain glyph; everything
// worth reading or changing lives behind a click.
Panel {
  id: root
  moduleName: "ryanschmidt.truetone"
  ipcTarget: "ryanschmidt.truetone"
  manageIpc: true

  // The service owns the sensor and the loop. This is a view over it.
  readonly property var service: bar?.shell?.serviceFor("ryanschmidt.truetone")

  readonly property bool serviceReady: !!service && service.ready === true
  readonly property bool supported: serviceReady && service.sensorHasColor === true
  readonly property bool on: supported && service.enabled === true
  readonly property bool adapting: supported && service.active === true

  readonly property var reading: serviceReady ? service.reading : null
  readonly property int roomKelvin: reading ? Math.round(reading.cct) : 0
  readonly property int roomLux: reading ? Math.round(reading.lux) : 0
  readonly property var targetKelvin: serviceReady ? service.targetK : null
  readonly property var appliedKelvin: serviceReady ? service.appliedK : null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string statusMetaText: {
    if (!serviceReady) return "Starting"
    if (!supported) return service.unavailableReason || "Unsupported hardware"
    if (!service.enabled) return "Off"
    if (service.yielded) return "Paused while Night Light is on"
    if (!reading) return "Waiting for a reading"
    if (roomLux < service.luxFloor) return "Too dark to sample, holding"
    return "Adapting to " + roomKelvin + "K room light"
  }

  function setSetting(key, value) {
    if (service && service.setSetting) service.setSetting(key, value)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ===== bar icon =====
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Plain foreground, never accent. Off reads as dimmed rather than
    // recoloured, so the bar keeps one colour.
    dimmed: !root.adapting
    tooltipText: "True Tone · " + root.statusMetaText

    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          // mdi brightness-auto
          text: "󰃝"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.space(11)
        }
      }
    }

    onPressed: function (mouseButton) {
      if (mouseButton === Qt.RightButton) root.setEnabledFromPanel(!root.on)
      else root.toggle()
    }
  }

  function setEnabledFromPanel(value) {
    if (service && service.setEnabled) service.setEnabled(value)
  }

  // ===== panel =====
  PopupCard {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(560))

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: flick.width
        spacing: Style.space(10)

        // ---- header with the master toggle ----
        Item {
          width: parent.width
          implicitHeight: Math.max(headerCol.implicitHeight, masterToggle.implicitHeight)

          Column {
            id: headerCol
            anchors.left: parent.left
            anchors.right: masterToggle.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "True Tone"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              font.bold: true
            }

            Text {
              width: parent.width
              text: root.statusMetaText
              color: root.adapting ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              maximumLineCount: 1
            }

            // Paused means something else holds the display. Without an action
            // here the state is a dead end: startup will not seize a warm
            // display it did not set, so the user needs a way to say "mine".
            Button {
              visible: root.serviceReady && root.service.yielded === true && root.on
              text: "Take over"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              onClicked: { if (root.service && root.service.adopt) root.service.adopt() }
            }
          }

          ToggleSwitch {
            id: masterToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.on
            interactive: root.supported
            foreground: root.foreground
            onToggled: root.setEnabledFromPanel(!root.on)
          }
        }

        // ---- unsupported hardware notice ----
        Text {
          width: parent.width
          visible: root.serviceReady && !root.supported
          text: "This machine's ambient light sensor reports brightness only. "
              + "True Tone needs a sensor that also reports colour."
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          width: parent.width
          visible: root.supported
          foreground: root.foreground
        }

        // ---- live readings ----
        PanelSectionHeader {
          width: parent.width
          visible: root.supported
          text: "Sensor"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          visible: root.supported
          spacing: Style.space(4)

          Repeater {
            model: [
              { label: "Room light", value: root.roomKelvin > 0 ? root.roomKelvin + " K" : "-" },
              { label: "Brightness", value: root.reading ? root.roomLux + " lux" : "-" },
              { label: "Display target", value: root.targetKelvin ? root.targetKelvin + " K" : "-" },
              { label: "Display now", value: root.appliedKelvin ? root.appliedKelvin + " K" : "-" }
            ]

            delegate: Item {
              required property var modelData
              width: column.width
              implicitHeight: rowLabel.implicitHeight

              Text {
                id: rowLabel
                anchors.left: parent.left
                text: parent.modelData.label
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.right: parent.right
                text: parent.modelData.value
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          visible: root.supported
          foreground: root.foreground
        }

        // ---- settings ----
        PanelSectionHeader {
          width: parent.width
          visible: root.supported
          text: "Settings"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // Strength
        Column {
          width: parent.width
          visible: root.supported
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: strengthLabel.implicitHeight

            Text {
              id: strengthLabel
              anchors.left: parent.left
              text: "Strength"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              text: root.serviceReady ? Math.round(root.service.strength * 100) + "%" : "-"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: 1
            step: 0.05
            value: root.serviceReady ? root.service.strength : 0.5
            onMoved: function (v) { root.setSetting("strength", v) }
          }

          Text {
            width: parent.width
            text: "Higher follows the room more closely."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // Warmest allowed
        Column {
          width: parent.width
          visible: root.supported
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: warmLabel.implicitHeight

            Text {
              id: warmLabel
              anchors.left: parent.left
              text: "Warmest allowed"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              text: root.serviceReady ? root.service.minKelvin + " K" : "-"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 2500
            maximum: 6000
            step: 100
            integer: true
            value: root.serviceReady ? root.service.minKelvin : 3800
            onMoved: function (v) { root.setSetting("minKelvin", v) }
          }

          Text {
            width: parent.width
            text: "The display will never go warmer than this."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // Responsiveness
        Column {
          width: parent.width
          visible: root.supported
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: pollLabel.implicitHeight

            Text {
              id: pollLabel
              anchors.left: parent.left
              text: "Check every"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              text: root.serviceReady ? root.service.pollIntervalSec + "s" : "-"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          PanelSlider {
            width: parent.width
            bar: root.bar
            minimum: 1
            maximum: 30
            step: 1
            integer: true
            value: root.serviceReady ? root.service.pollIntervalSec : 2
            onMoved: function (v) { root.setSetting("pollIntervalSec", v) }
          }

          Text {
            width: parent.width
            text: "Lower reacts faster and wakes the laptop more often."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        PanelSeparator {
          width: parent.width
          visible: root.supported
          foreground: root.foreground
        }

        // ---- footer ----
        Item {
          width: parent.width
          visible: root.supported
          implicitHeight: Math.max(sensorPathText.implicitHeight, resetButton.implicitHeight)

          Text {
            id: sensorPathText
            anchors.left: parent.left
            anchors.right: resetButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.serviceReady && root.service.sensorPath
              ? root.service.sensorPath.replace("/sys/bus/iio/devices/", "")
              : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          Button {
            id: resetButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Reset"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: { if (root.service && root.service.resetSettings) root.service.resetSettings() }
          }
        }
      }
    }
  }
}

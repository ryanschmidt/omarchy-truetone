import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon and the True Tone panel.
//
// There are no settings, the same as on a Mac: True Tone is on or off, and
// Night Light owns the Kelvin slider. What is left is the switch and enough
// sensor detail to answer the only question a Linux user actually has, which
// is whether their hardware can do this at all.
Panel {
  id: root
  moduleName: "ryanschmidt.truetone"
  ipcTarget: "ryanschmidt.truetone"
  manageIpc: true

  readonly property var service: bar?.shell?.serviceFor("ryanschmidt.truetone")

  readonly property bool serviceReady: !!service && service.ready === true
  readonly property bool supported: serviceReady && service.supported === true
  readonly property bool on: supported && service.enabled === true
  readonly property bool adapting: supported && service.active === true

  readonly property var reading: serviceReady ? service.reading : null
  readonly property int roomKelvin: reading ? Math.round(reading.cct) : 0
  readonly property int roomLux: reading ? Math.round(reading.lux) : 0
  readonly property var targetKelvin: serviceReady ? service.targetK : null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string blockedReason: {
    if (!serviceReady) return ""
    if (!service.sensorHasColor) return service.unavailableReason || "Unsupported hardware"
    if (service.helperError && service.helperError !== "") return service.helperError
    return ""
  }

  readonly property string statusMetaText: {
    if (!serviceReady) return "Starting"
    if (blockedReason !== "") return blockedReason
    if (!service.enabled) return "Off"
    if (!reading) return "Waiting for a reading"
    if (roomLux < 3) return "Too dark to sample, holding"
    return "Matching " + roomKelvin + "K room light"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ===== bar icon =====
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    dimmed: !root.adapting
    tooltipText: "True Tone · " + root.statusMetaText

    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: "󰃝"                                // mdi brightness-auto
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
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(420))

    Column {
      id: column
      width: popup.width > 0 ? popup.contentWidth : Style.space(320)
      spacing: Style.space(10)

      // ---- header with the only control there is ----
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

      Text {
        width: parent.width
        text: "Automatically adapts the display so colours look consistent "
            + "in different ambient lighting."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      // ---- hardware problem, if there is one ----
      Text {
        width: parent.width
        visible: root.blockedReason !== ""
        text: root.blockedReason === "sensor reports brightness only, not colour"
            ? "This laptop's ambient light sensor measures brightness but not "
            + "colour. True Tone needs a colour-capable sensor."
            : root.blockedReason
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

      // ---- what the sensor sees ----
      Column {
        width: parent.width
        visible: root.supported
        spacing: Style.space(4)

        Repeater {
          model: [
            { label: "Room light", value: root.roomKelvin > 0 ? root.roomKelvin + " K" : "-" },
            { label: "Brightness", value: root.reading ? root.roomLux + " lux" : "-" },
            { label: "Display white point", value: root.targetKelvin ? root.targetKelvin + " K" : "-" }
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

      // ---- footer ----
      Text {
        width: parent.width
        visible: root.supported
        text: "Independent of Night Light. Both can be on."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Settings surface for the shutter plugin: Home Assistant URL, long-lived
// token, optional exclude filter, floor management, per-cover floor mapping,
// and poll intervals. Everything writes straight through Service, which
// persists to the 0600 state file.
Column {
  id: root

  required property var service
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  // The panel's key catcher must stand down while a text field has focus,
  // otherwise j/k/h/l would drive the cursor instead of typing.
  readonly property bool editing: urlField.activeFocus || tokenField.activeFocus
    || excludeField.activeFocus || newFloorField.activeFocus || floorRenameActive

  property bool floorRenameActive: false
  property bool tokenRevealed: false

  signal done()

  // The panel's key catcher stands down while this view is up, so Escape has
  // to be handled here. Key events bubble up from whichever field has focus.
  Keys.onEscapePressed: function(event) {
    root.done()
    event.accepted = true
  }

  spacing: Style.space(12)

  function commit(key, value) {
    var changes = {}
    changes[key] = value
    service.updateSettings(changes)
  }

  // ------------------------------------------------------------ Home Assistant

  PanelSectionHeader {
    text: "HOME ASSISTANT"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Column {
    width: parent.width
    spacing: Style.spacing.labelGap

    FieldLabel { text: "URL" }

    TextField {
      id: urlField
      width: parent.width
      foreground: root.foreground
      placeholderText: "https://home.example.com:8123"
      text: root.service.settings.url
      onEditingFinished: root.commit("url", text)
      onAccepted: root.service.saveAndTest({ url: text })
    }
  }

  Column {
    width: parent.width
    spacing: Style.spacing.labelGap

    FieldLabel { text: "Long-Lived Access Token" }

    Item {
      width: parent.width
      implicitHeight: tokenField.implicitHeight

      TextField {
        id: tokenField
        anchors.left: parent.left
        anchors.right: tokenActions.left
        anchors.rightMargin: Style.space(4)
        foreground: root.foreground
        password: !root.tokenRevealed
        placeholderText: "In HA: Profile → Security → Create token"
        text: root.service.settings.token
        onEditingFinished: root.commit("token", text)
        onAccepted: root.service.saveAndTest({ token: text })
      }

      Row {
        id: tokenActions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        PanelActionButton {
          iconText: root.tokenRevealed ? "󰈉" : "󰈈"
          tooltipText: root.tokenRevealed ? "Hide token" : "Show token"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.tokenRevealed = !root.tokenRevealed
        }

        PanelActionButton {
          iconText: "󰅖"
          tooltipText: "Clear token"
          foreground: root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          enabled: root.service.settings.token !== ""
          onClicked: {
            tokenField.text = ""
            root.tokenRevealed = false
            root.commit("token", "")
          }
        }
      }
    }
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(testButton.implicitHeight, testResult.implicitHeight)

    Button {
      id: testButton
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "Test connection"
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onClicked: root.service.saveAndTest({ url: urlField.text, token: tokenField.text })
    }

    Text {
      id: testResult
      textFormat: Text.PlainText
      anchors.left: testButton.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      visible: root.service.testState !== ""
      text: (root.service.testState === "ok" ? "󰄬  " : root.service.testState === "error" ? "󰀨  " : "")
        + root.service.testMessage
      color: root.service.testState === "error" ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      maximumLineCount: 3
      elide: Text.ElideRight
    }
  }

  PanelSeparator { foreground: root.foreground }

  // ------------------------------------------------------------------ filter

  PanelSectionHeader {
    text: "ENTITIES"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Column {
    width: parent.width
    spacing: Style.spacing.labelGap

    FieldLabel { text: "Exclude (optional)" }

    TextField {
      id: excludeField
      width: parent.width
      foreground: root.foreground
      placeholderText: "cover.garage, cover.markise*"
      text: root.service.settings.exclude
      onEditingFinished: root.commit("exclude", text)
      onAccepted: root.commit("exclude", text)
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: {
        var total = root.service.covers.length
        var hidden = Model.excludedCount(root.service.covers, excludeField.text)
        return "Comma-separated entity_ids, * as wildcard · "
          + hidden + " of " + total + " excluded"
      }
      color: Qt.darker(root.foreground, 2.0)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  PanelSeparator { foreground: root.foreground }

  // ------------------------------------------------------------------- floors

  PanelSectionHeader {
    text: "FLOORS"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Column {
    id: floorColumn
    width: parent.width
    spacing: Style.space(4)

    Repeater {
      model: root.service.settings.floors

      FloorRow {
        required property var modelData
        required property int index
        width: floorColumn.width
        floorName: modelData
        floorIndex: index
      }
    }
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(newFloorField.implicitHeight, addFloorButton.implicitHeight)

    TextField {
      id: newFloorField
      anchors.left: parent.left
      anchors.right: addFloorButton.left
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.foreground
      placeholderText: "Add new floor…"
      onAccepted: {
        root.service.addFloor(text)
        text = ""
      }
    }

    PanelActionButton {
      id: addFloorButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰐕"
      tooltipText: "Add floor"
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: newFloorField.text.trim() !== ""
      onClicked: {
        root.service.addFloor(newFloorField.text)
        newFloorField.text = ""
      }
    }
  }

  PanelSeparator { foreground: root.foreground }

  // ------------------------------------------------------------------ mapping

  PanelSectionHeader {
    text: "ASSIGNMENT"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Text {
    textFormat: Text.PlainText
    width: parent.width
    visible: mappingRepeater.count === 0
    text: root.service.configured
      ? "No covers found. Test the connection to search again."
      : "Enter URL and token, then test the connection."
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  Column {
    id: mappingColumn
    width: parent.width
    spacing: Style.space(4)

    Repeater {
      id: mappingRepeater
      model: root.service.stableCovers

      MappingRow {
        required property var modelData
        width: mappingColumn.width
        cover: modelData
      }
    }
  }

  PanelSeparator { foreground: root.foreground }

  // ---------------------------------------------------------------- intervals

  PanelSectionHeader {
    text: "REFRESH"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Row {
    width: parent.width
    spacing: Style.space(16)

    NumberField {
      label: "Idle interval (s)"
      foreground: root.foreground
      fontFamily: root.fontFamily
      from: 10
      to: 600
      stepSize: 5
      fieldWidth: Style.space(110)
      value: root.service.settings.idleIntervalSec
      onModified: function(v) { root.commit("idleIntervalSec", v) }
    }

    NumberField {
      label: "Open interval (s)"
      foreground: root.foreground
      fontFamily: root.fontFamily
      from: 1
      to: 60
      stepSize: 1
      fieldWidth: Style.space(110)
      value: root.service.settings.openIntervalSec
      onModified: function(v) { root.commit("openIntervalSec", v) }
    }
  }

  Button {
    width: parent.width
    text: "Done"
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    enabled: root.service.configured
    onClicked: root.done()
  }

  // --------------------------------------------------------------- components

  component FieldLabel: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.4)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component FloorRow: Item {
    id: floorRow
    property string floorName: ""
    property int floorIndex: 0
    property bool renaming: false

    implicitHeight: Math.max(floorLabel.implicitHeight, floorActions.implicitHeight, renameField.implicitHeight)

    onRenamingChanged: {
      root.floorRenameActive = renaming
      if (renaming) {
        renameField.text = floorRow.floorName
        renameField.forceActiveFocus()
        renameField.selectAll()
      }
    }

    Text {
      id: floorLabel
      textFormat: Text.PlainText
      visible: !floorRow.renaming
      anchors.left: parent.left
      anchors.leftMargin: Style.space(2)
      anchors.right: floorActions.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: floorRow.floorName
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    TextField {
      id: renameField
      visible: floorRow.renaming
      anchors.left: parent.left
      anchors.right: floorActions.left
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.foreground
      onAccepted: {
        root.service.renameFloor(floorRow.floorIndex, text)
        floorRow.renaming = false
      }
      onActiveFocusChanged: if (!activeFocus && floorRow.renaming) floorRow.renaming = false
    }

    Row {
      id: floorActions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      PanelActionButton {
        iconText: "󰅃"
        tooltipText: "Move up"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: floorRow.floorIndex > 0
        onClicked: root.service.moveFloor(floorRow.floorIndex, -1)
      }

      PanelActionButton {
        iconText: "󰅀"
        tooltipText: "Move down"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: floorRow.floorIndex < root.service.settings.floors.length - 1
        onClicked: root.service.moveFloor(floorRow.floorIndex, 1)
      }

      PanelActionButton {
        iconText: "󰏫"
        tooltipText: "Rename"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: floorRow.renaming = !floorRow.renaming
      }

      PanelActionButton {
        iconText: "󰆴"
        tooltipText: "Remove floor"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        enabled: root.service.settings.floors.length > 1
        onClicked: root.service.removeFloor(floorRow.floorIndex)
      }
    }
  }

  component MappingRow: Item {
    id: mappingRow
    property var cover: null

    implicitHeight: Math.max(mappingLabel.implicitHeight, floorPicker.implicitHeight)

    Column {
      id: mappingLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(2)
      anchors.right: floorPicker.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: mappingRow.cover ? mappingRow.cover.name : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: mappingRow.cover ? mappingRow.cover.entityId : ""
        color: Qt.darker(root.foreground, 2.0)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Dropdown {
      id: floorPicker
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(150)
      showLabel: false
      foreground: root.foreground
      fontFamily: root.fontFamily
      options: Model.floorOptions(root.service.settings)
      value: mappingRow.cover ? Model.mappingValue(root.service.settings, mappingRow.cover.entityId) : Model.UNASSIGNED
      onChanged: function(value) {
        if (mappingRow.cover) root.service.setMapping(mappingRow.cover.entityId, value)
      }
    }
  }
}

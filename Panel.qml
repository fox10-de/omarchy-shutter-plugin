import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "fox10.shutters"
  ipcTarget: "fox10.shutters"
  manageIpc: false

  // Resolve the plugin directory from this file's own URL so the helper script
  // is found no matter where the plugin was installed.
  readonly property string pluginDir: {
    var path = String(Qt.resolvedUrl("."))
    if (path.indexOf("file://") === 0) path = path.substring(7)
    while (path.length > 1 && path.charAt(path.length - 1) === "/") path = path.substring(0, path.length - 1)
    return decodeURIComponent(path)
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // "list" | "settings"
  property string view: "list"
  property int rowIndex: 0
  property int buttonIndex: 0
  property bool cursorActive: false

  // entity_id whose position is currently being typed, "" when not editing.
  property string positionEditEntityId: ""

  readonly property var rows: Model.flattenRows(shutterService.sections)
  readonly property bool hasRows: rows.length > 0
  readonly property color barIconColor: !shutterService.configured || shutterService.lastError !== ""
    ? urgent
    : barForeground

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------ cursor model

  function clampCursor() {
    if (rows.length === 0) {
      rowIndex = 0
      buttonIndex = 0
      return
    }
    if (rowIndex < 0) rowIndex = 0
    if (rowIndex >= rows.length) rowIndex = rows.length - 1
    if (buttonIndex < 0) buttonIndex = 0
    if (buttonIndex > 2) buttonIndex = 2
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    clampCursor()
    if (dy !== 0) {
      rowIndex = Math.max(0, Math.min(rows.length - 1, rowIndex + dy))
      scrollCursorIntoView()
    }
    if (dx !== 0) buttonIndex = Math.max(0, Math.min(2, buttonIndex + dx))
  }

  function currentRow() {
    if (rows.length === 0) return null
    return rows[Math.max(0, Math.min(rowIndex, rows.length - 1))]
  }

  function targetsForRow(row) {
    if (!row) return []
    if (row.kind === "floor") return Model.entityIdsOf(row.section)
    return [row.cover.entityId]
  }

  function actionForButton(index) {
    return index === 0 ? "open" : (index === 1 ? "stop" : "close")
  }

  function activateCursor() {
    var row = currentRow()
    if (!row) return
    shutterService.command(actionForButton(buttonIndex), targetsForRow(row))
  }

  function setCursor(index, button) {
    cursorActive = true
    rowIndex = index
    if (button !== undefined) buttonIndex = button
  }

  // ------------------------------------------------------ position editing

  function beginPositionEdit(cover) {
    if (!cover || !cover.available || !cover.canSetPosition) return
    positionEditEntityId = cover.entityId
  }

  function cancelPositionEdit() {
    positionEditEntityId = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function commitPositionEdit(entityId, text) {
    var value = Model.parsePositionInput(text)
    positionEditEntityId = ""
    if (value >= 0) shutterService.setPosition(value, [entityId])
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Opens the editor for the row under the keyboard cursor.
  function editCursorPosition() {
    var row = currentRow()
    if (row && row.kind === "cover") beginPositionEdit(row.cover)
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (!rowColumn || rowIndex < 0 || rowIndex >= rowColumn.children.length) return
    scrollItemIntoView(rowColumn.children[rowIndex])
  }

  function showSettings() {
    positionEditEntityId = ""
    // open() drives onOpenedChanged, which resets `view` — so open first, then
    // select the settings view, or the reset would clobber it.
    if (!opened) open()
    view = "settings"
    shutterService.discoverAreas()
  }

  function showList() {
    view = "list"
    cursorActive = false
    clampCursor()
  }

  onOpenedChanged: {
    shutterService.panelOpen = opened
    if (opened) {
      cursorActive = false
      positionEditEntityId = ""
      if (panelFlick) panelFlick.contentY = 0
      // Nothing to control until it's configured — start where the work is,
      // otherwise always come back to the shutter list.
      view = shutterService.configured ? "list" : "settings"
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }

  onRowsChanged: clampCursor()

  Service {
    id: shutterService
    pluginDir: root.pluginDir
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { shutterService.refresh(); return "ok" }
    function settings(): string { root.showSettings(); return "ok" }
    function openAll(): string { shutterService.openAll(allEntityIds()); return "ok" }
    function closeAll(): string { shutterService.closeAll(allEntityIds()); return "ok" }
    function stopAll(): string { shutterService.stopAll(allEntityIds()); return "ok" }
    function status(): string { return shutterService.aggregate }
  }

  function allEntityIds() {
    var ids = []
    var list = shutterService.visibleCovers
    for (var i = 0; i < list.length; i++) ids.push(list[i].entityId)
    return ids
  }

  // --------------------------------------------------------------- bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barGlyph(shutterService.aggregate, shutterService.configured, shutterService.lastError)
    tooltipText: Model.barTooltip(shutterService.visibleCovers, shutterService.configured, shutterService.lastError)
    foreground: root.barIconColor
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) shutterService.refresh()
      else if (buttonCode === Qt.MiddleButton) root.showSettings()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // In the settings view the form owns the keyboard: Tab walks its focus
      // chain and text fields receive j/k/h/l as literal characters. The
      // catcher only drives the shutter list.
      blocked: root.view === "settings" || root.positionEditEntityId !== ""
      onMoveRequested: function(dx, dy) {
        if (root.view !== "list") return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.view === "list" && root.cursorActive) root.activateCursor()
      onCloseRequested: {
        if (root.view === "settings" && shutterService.configured) root.showList()
        else root.close()
      }
      onTabRequested: function(direction) {
        // In the settings view Tab must walk the form's own focus chain,
        // otherwise the dropdowns and buttons are unreachable by keyboard.
        if (root.view === "settings") return
        root.switchPanel(direction)
      }
      onTextKey: function(t) {
        if (root.view !== "list") return
        var key = String(t).toLowerCase()
        if (key === "r") shutterService.refresh()
        else if (key === "s") root.showSettings()
        else if (key === "p") root.editCursorPosition()
        else if (key >= "0" && key <= "9") {
          // Typing a digit on a cover row jumps straight into the editor.
          var row = root.currentRow()
          if (row && row.kind === "cover") root.beginPositionEdit(row.cover)
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          // ------------------------------------------------------------ header
          Item {
            width: parent.width
            implicitHeight: Math.max(headerTitle.implicitHeight, headerActions.implicitHeight)

            Text {
              id: headerTitle
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: headerActions.left
              anchors.rightMargin: Style.space(8)
              text: root.view === "settings" ? "Settings" : "Shutters"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              elide: Text.ElideRight
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              PanelActionButton {
                visible: root.view === "settings"
                iconText: "󰓖"
                tooltipText: "Back"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: shutterService.configured
                onClicked: root.showList()
              }

              PanelActionButton {
                visible: root.view === "list"
                iconText: "󰑐"
                tooltipText: "Refresh"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: shutterService.refresh()
              }

              PanelActionButton {
                visible: root.view === "list"
                iconText: "󰒓"
                tooltipText: "Settings"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.showSettings()
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------------- status line
          Text {
            textFormat: Text.PlainText
            visible: root.view === "list" && statusText !== ""
            width: parent.width
            readonly property string statusText: {
              if (!shutterService.configured) return "Not configured — open the settings (⚙ or s)."
              if (shutterService.actionError !== "") return shutterService.actionError
              if (shutterService.lastError !== "") return shutterService.lastError
              if (!root.hasRows && !shutterService.refreshing) return "No covers found."
              return ""
            }
            text: statusText
            color: shutterService.lastError !== "" || shutterService.actionError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ------------------------------------------------------------- rows
          Column {
            id: rowColumn
            visible: root.view === "list"
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.rows

              Loader {
                required property var modelData
                required property int index
                width: rowColumn.width
                sourceComponent: modelData.kind === "floor" ? floorHeaderComponent : coverRowComponent
                onLoaded: {
                  item.row = modelData
                  item.rowIdx = index
                }
                Binding {
                  target: item
                  property: "row"
                  value: modelData
                  when: item !== null
                }
              }
            }
          }

          // --------------------------------------------------------- settings
          Loader {
            id: settingsLoader
            width: parent.width
            active: root.view === "settings"
            visible: active
            sourceComponent: SettingsView {
              width: settingsLoader.width
              service: shutterService
              foreground: root.foreground
              dim: root.dim
              urgent: root.urgent
              fontFamily: root.fontFamily
              onDone: root.showList()
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.view === "list" && root.hasRows
            width: parent.width
            text: root.positionEditEntityId !== ""
              ? "Enter 0–100 · ⏎ apply · Esc cancel"
              : "j/k row · h/l button · ⏎ activate · click/p position · r refresh · s settings"
            color: Qt.darker(root.foreground, 2.0)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // --------------------------------------------------------------- components

  Component {
    id: floorHeaderComponent

    CursorSurface {
      id: floorHeader
      property var row: null
      property int rowIdx: 0
      readonly property var section: row ? row.section : null
      readonly property var entityIds: section ? Model.entityIdsOf(section) : []

      hasCursor: root.cursorActive && root.rowIndex === rowIdx
      foreground: root.foreground
      implicitHeight: Math.max(floorLabel.implicitHeight, floorButtons.implicitHeight) + Style.space(6)

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        onEntered: root.setCursor(floorHeader.rowIdx)
      }

      PanelSectionHeader {
        id: floorLabel
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.right: floorButtons.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: section ? String(section.title).toUpperCase() : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
        elide: Text.ElideRight
      }

      ControlTriplet {
        id: floorButtons
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        rowIdx: floorHeader.rowIdx
        entityIds: floorHeader.entityIds
        canStop: true
        tooltipSuffix: section ? " (" + section.title + ")" : ""
      }
    }
  }

  Component {
    id: coverRowComponent

    CursorSurface {
      id: coverRow
      property var row: null
      property int rowIdx: 0
      readonly property var cover: row ? row.cover : null

      hasCursor: root.cursorActive && root.rowIndex === rowIdx
      foreground: root.foreground
      implicitHeight: Math.max(nameLabel.implicitHeight, coverButtons.implicitHeight, positionEditor.implicitHeight) + Style.spacing.rowPaddingX

      readonly property bool editingPosition: cover !== null && root.positionEditEntityId === cover.entityId

      onEditingPositionChanged: if (editingPosition) {
        positionEditor.text = Model.positionEditSeed(cover)
        positionEditor.forceActiveFocus()
        positionEditor.selectAll()
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: cover && cover.available && cover.canSetPosition ? Qt.IBeamCursor : Qt.ArrowCursor
        onEntered: root.setCursor(coverRow.rowIdx)
        onClicked: root.beginPositionEdit(coverRow.cover)
      }

      Text {
        id: nameLabel
        textFormat: Text.PlainText
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.right: coverRow.editingPosition ? positionEditor.left : positionLabel.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: cover ? cover.name : ""
        color: cover && cover.available ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      // Inline percentage editor. Replaces the read-only position label while
      // this row is being edited.
      TextField {
        id: positionEditor
        visible: coverRow.editingPosition
        anchors.right: coverButtons.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(64)
        foreground: root.foreground
        verticalPadding: Style.space(2)
        horizontalAlignment: Text.AlignRight
        inputMethodHints: Qt.ImhDigitsOnly
        validator: IntValidator { bottom: 0; top: 100 }
        placeholderText: "0-100"
        onAccepted: if (coverRow.cover) root.commitPositionEdit(coverRow.cover.entityId, text)
        Keys.onEscapePressed: function(event) {
          root.cancelPositionEdit()
          event.accepted = true
        }
        onActiveFocusChanged: if (!activeFocus && coverRow.editingPosition) root.cancelPositionEdit()
      }

      Row {
        id: positionLabel
        visible: !coverRow.editingPosition
        anchors.right: coverButtons.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Text {
          textFormat: Text.PlainText
          visible: text !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: cover ? Model.stateGlyph(cover) : ""
          color: cover && !cover.available ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconSmall

          RotationAnimation on rotation {
            from: 0
            to: 360
            duration: 1200
            loops: Animation.Infinite
            running: cover !== null && cover.moving
          }
        }

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: Model.positionText(cover)
          color: cover && cover.available ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignRight
          width: Math.max(implicitWidth, Style.space(34))
        }
      }

      ControlTriplet {
        id: coverButtons
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        rowIdx: coverRow.rowIdx
        entityIds: cover ? [cover.entityId] : []
        canStop: cover ? cover.canStop : true
        enabledRow: cover ? cover.available : false
        tooltipSuffix: cover ? " — " + cover.name : ""
      }
    }
  }

  // Up / stop / down. Shared by cover rows and floor headers so both respond
  // to the same h/l cursor positions.
  component ControlTriplet: Row {
    id: triplet
    property int rowIdx: 0
    property var entityIds: []
    property bool canStop: true
    property bool enabledRow: true
    property string tooltipSuffix: ""

    readonly property bool rowHasCursor: root.cursorActive && root.rowIndex === rowIdx
    spacing: Style.space(2)

    PanelActionButton {
      iconText: "󰜷"
      tooltipText: "Open" + triplet.tooltipSuffix
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: triplet.enabledRow && triplet.entityIds.length > 0
      hasCursor: triplet.rowHasCursor && root.buttonIndex === 0
      onHovered: function(on) { if (on) root.setCursor(triplet.rowIdx, 0) }
      onClicked: shutterService.command("open", triplet.entityIds)
    }

    PanelActionButton {
      iconText: "󰓛"
      tooltipText: triplet.canStop ? "Stop" + triplet.tooltipSuffix : "Stop not supported"
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: triplet.enabledRow && triplet.canStop && triplet.entityIds.length > 0
      hasCursor: triplet.rowHasCursor && root.buttonIndex === 1
      onHovered: function(on) { if (on) root.setCursor(triplet.rowIdx, 1) }
      onClicked: shutterService.command("stop", triplet.entityIds)
    }

    PanelActionButton {
      iconText: "󰜮"
      tooltipText: "Close" + triplet.tooltipSuffix
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: triplet.enabledRow && triplet.entityIds.length > 0
      hasCursor: triplet.rowHasCursor && root.buttonIndex === 2
      onHovered: function(on) { if (on) root.setCursor(triplet.rowIdx, 2) }
      onClicked: shutterService.command("close", triplet.entityIds)
    }
  }
}

import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the settings file, the Home Assistant polling loop, and the cover
// commands. All network work goes through ha.sh so the long-lived token
// stays inside the 0600 settings file and never reaches argv or `ps`.
Item {
  id: root

  property string pluginDir: ""
  readonly property string helperPath: pluginDir + "/ha.sh"
  readonly property string settingsPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/shutters.json"

  property var settings: Model.defaultSettings()
  property bool settingsLoaded: false
  readonly property bool configured: Model.isConfigured(settings)

  property var covers: []
  property var discovered: ({})
  property string lastError: ""
  property bool refreshing: false
  property bool panelOpen: false
  property int failureCount: 0
  property string actionError: ""

  // Burst window after a command / while a cover is travelling.
  property int burstTicks: 0

  readonly property var visibleCovers: Model.applyExcludes(covers, settings.exclude)
  readonly property var sections: Model.groupByFloor(visibleCovers, settings, discovered)
  readonly property string aggregate: Model.aggregateState(visibleCovers)

  // visibleCovers is a fresh array on every poll, which would make any Repeater
  // bound to it rebuild its delegates every few seconds — destroying an open
  // dropdown in the settings view before the user can pick anything. This
  // republishes only when the actual set of entities changes, so the mapping
  // list stays stable while the panel is polling.
  property var stableCovers: []
  property string stableCoverKey: ""
  onVisibleCoversChanged: {
    var key = Model.entityIdsOf(visibleCovers).join("\u0000")
    if (key === stableCoverKey && stableCovers.length === visibleCovers.length) return
    stableCoverKey = key
    stableCovers = visibleCovers
  }
  readonly property bool anyMoving: aggregate === "moving"

  signal settingsSaved()
  signal statesRefreshed()

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // ---------------------------------------------------------------- settings

  function applySettings(next) {
    settings = next
    settingsLoaded = true
  }

  function updateSettings(changes) {
    var next = Model.parseSettings(Model.serializeSettings(settings))
    for (var key in changes) {
      if (changes.hasOwnProperty(key)) next[key] = changes[key]
    }
    // Round-trip through the parser so normalization (url scheme, clamping,
    // token trimming) is applied exactly once, in one place.
    var normalized = Model.parseSettings(Model.serializeSettings(next))
    settings = normalized
    saveSettings()
  }

  function setMapping(entityId, floor) {
    var mapping = {}
    for (var key in settings.mapping) {
      if (settings.mapping.hasOwnProperty(key)) mapping[key] = settings.mapping[key]
    }
    if (floor === Model.UNASSIGNED) delete mapping[entityId]
    else mapping[entityId] = floor
    updateSettings({ mapping: mapping })
  }

  function addFloor(name) {
    var trimmed = String(name || "").trim()
    if (trimmed === "" || settings.floors.indexOf(trimmed) !== -1) return
    var floors = settings.floors.slice()
    floors.push(trimmed)
    updateSettings({ floors: floors })
  }

  function renameFloor(index, name) {
    var trimmed = String(name || "").trim()
    if (trimmed === "" || index < 0 || index >= settings.floors.length) return
    var previous = settings.floors[index]
    if (previous === trimmed) return
    if (settings.floors.indexOf(trimmed) !== -1) return
    var floors = settings.floors.slice()
    floors[index] = trimmed
    var mapping = {}
    for (var key in settings.mapping) {
      if (!settings.mapping.hasOwnProperty(key)) continue
      mapping[key] = settings.mapping[key] === previous ? trimmed : settings.mapping[key]
    }
    updateSettings({ floors: floors, mapping: mapping })
  }

  function moveFloor(index, delta) {
    var target = index + delta
    if (index < 0 || index >= settings.floors.length) return
    if (target < 0 || target >= settings.floors.length) return
    var floors = settings.floors.slice()
    var tmp = floors[index]
    floors[index] = floors[target]
    floors[target] = tmp
    updateSettings({ floors: floors })
  }

  // Covers mapped to a removed floor fall back to "Unassigned".
  function removeFloor(index) {
    if (index < 0 || index >= settings.floors.length) return
    if (settings.floors.length <= 1) return
    var removed = settings.floors[index]
    var floors = settings.floors.slice()
    floors.splice(index, 1)
    var mapping = {}
    for (var key in settings.mapping) {
      if (!settings.mapping.hasOwnProperty(key)) continue
      if (settings.mapping[key] === removed) continue
      mapping[key] = settings.mapping[key]
    }
    updateSettings({ floors: floors, mapping: mapping })
  }

  function saveSettings() {
    savePayload = Model.serializeSettings(settings)
    if (saveProcess.running) {
      savePending = true
      return
    }
    savePending = false
    saveProcess.payload = savePayload
    saveProcess.command = ["bash", helperPath, "save"]
    // stdinEnabled is set to false in onStarted to send EOF, which breaks the
    // declared binding for good. Re-enable it explicitly before every run or
    // the second save would start with stdin closed, ha.sh would block forever
    // in `payload="$(cat)"`, and the whole save queue would jam.
    saveProcess.stdinEnabled = true
    saveProcess.running = true
    saveWatchdog.restart()
  }

  property string savePayload: ""
  property bool savePending: false
  // "Verbindung testen" must not read the settings file before the pending
  // write lands, so the test waits for the save process to exit.
  property bool testAfterSave: false

  // Persists the given changes, then tests the connection once the write has
  // actually landed — the helper reads the file, not our in-memory copy.
  function saveAndTest(changes) {
    testState = "running"
    testMessage = "Saving…"
    testAfterSave = true
    updateSettings(changes)
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      // Our own writes trigger this watcher. While a save is in flight or
      // queued, the in-memory settings are newer than the file, so adopting
      // the file contents here would clobber edits the user just made — that
      // is how rapid successive changes used to get silently lost. Only adopt
      // the file when we are not mid-write; then it is either our own,
      // already-matching content or a genuine external edit.
      if (saveProcess.running || root.savePending) return
      root.applySettings(Model.parseSettings(text()))
    }
    onLoadFailed: {
      // Only fall back to defaults on the very first read (no settings file
      // yet). A later transient failure must not wipe loaded settings, since
      // the next save would then persist those defaults over the real file.
      if (!root.settingsLoaded) root.applySettings(Model.defaultSettings())
    }
  }

  // FileView's first read can race shell startup; one delayed reload
  // self-corrects and is a no-op when the first read was fine.
  Timer {
    interval: 1500
    running: true
    onTriggered: settingsFile.reload()
  }

  // Safety net: a save that never exits would leave savePending stuck and
  // silently swallow every later settings change. Nothing should take this
  // long, so treat it as hung and let the queue continue.
  Timer {
    id: saveWatchdog
    interval: 10000
    repeat: false
    onTriggered: {
      if (!saveProcess.running) return
      root.lastError = "Saving settings timed out"
      saveProcess.running = false
    }
  }

  Process {
    id: saveProcess
    property string payload: ""
    running: false
    command: []
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      saveWatchdog.stop()
      root.settingsSaved()
      if (root.savePending) {
        // Leave savePending set: it doubles as the "our write cycle is still
        // running" guard for the file watcher. saveSettings() clears it in the
        // same tick that it starts the next write, so no reload can slip in
        // between and overwrite the newer in-memory settings.
        Qt.callLater(root.saveSettings)
        return
      }
      if (root.testAfterSave) {
        root.testAfterSave = false
        Qt.callLater(root.testConnection)
        return
      }
      // The file watcher will pick the write up too, but refresh right away
      // so a corrected URL/token takes effect without waiting a poll cycle.
      Qt.callLater(root.refresh)
    }
  }

  // ------------------------------------------------------------------- states

  function refresh() {
    if (!configured || !settingsLoaded || statesProcess.running) return
    refreshing = true
    statesProcess.command = ["bash", helperPath, "states"]
    statesProcess.running = true
  }

  function applyStatesResponse(raw) {
    var parsed
    try {
      parsed = JSON.parse(String(raw || ""))
    } catch (e) {
      failureCount += 1
      lastError = "Invalid response from helper"
      return
    }
    if (!parsed || parsed.ok !== true) {
      failureCount += 1
      lastError = parsed && parsed.error ? String(parsed.error) : "Unknown error"
      return
    }
    failureCount = 0
    lastError = ""
    covers = Model.parseCovers(parsed.data)
    statesRefreshed()
    // Keep polling fast while anything is still travelling.
    if (anyMoving) burstTicks = Math.max(burstTicks, 3)
  }

  Process {
    id: statesProcess
    running: false
    command: []
    stdout: StdioCollector { id: statesOut; waitForEnd: true }
    stderr: StdioCollector { id: statesErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0 && String(statesOut.text || "").trim() === "") {
        root.failureCount += 1
        root.lastError = String(statesErr.text || "Helper could not be started").substring(0, 200)
        return
      }
      root.applyStatesResponse(statesOut.text)
    }
  }

  // ----------------------------------------------------------------- commands

  // Optimistically flips local state so the row reacts before HA answers.
  function markMoving(entityIds, action) {
    if (action === "stop") return
    var updated = []
    for (var i = 0; i < covers.length; i++) {
      var cover = covers[i]
      if (entityIds.indexOf(cover.entityId) === -1) {
        updated.push(cover)
        continue
      }
      var copy = {}
      for (var key in cover) if (cover.hasOwnProperty(key)) copy[key] = cover[key]
      copy.state = action === "open" ? "opening" : "closing"
      copy.moving = true
      updated.push(copy)
    }
    covers = updated
  }

  function command(action, entityIds) {
    if (!configured || !entityIds || entityIds.length === 0) return
    markMoving(entityIds, action)
    actionError = ""
    commandQueue.push({ action: action, entityIds: entityIds })
    pumpQueue()
  }

  // Drives cover.set_cover_position. `position` is 0-100 (100 = fully open).
  function setPosition(position, entityIds) {
    if (!configured || !entityIds || entityIds.length === 0) return
    var target = Model.clampInt(position, -1, 0, 100)
    if (target < 0) return
    actionError = ""
    // Optimistically mark travel direction from the current position so the
    // row shows a spinner immediately.
    var updated = []
    for (var i = 0; i < covers.length; i++) {
      var cover = covers[i]
      if (entityIds.indexOf(cover.entityId) === -1 || cover.position === target) {
        updated.push(cover)
        continue
      }
      var copy = {}
      for (var key in cover) if (cover.hasOwnProperty(key)) copy[key] = cover[key]
      if (cover.position >= 0) {
        copy.state = target > cover.position ? "opening" : "closing"
        copy.moving = true
      }
      updated.push(copy)
    }
    covers = updated
    commandQueue.push({ action: "position", entityIds: entityIds, position: target })
    pumpQueue()
  }

  property var commandQueue: []

  function pumpQueue() {
    if (commandProcess.running || commandQueue.length === 0) return
    var next = commandQueue.shift()
    if (next.action === "position") {
      commandProcess.command = ["bash", helperPath, "position", String(next.position)].concat(next.entityIds)
    } else {
      commandProcess.command = ["bash", helperPath, "service", next.action].concat(next.entityIds)
    }
    commandProcess.running = true
  }

  Process {
    id: commandProcess
    running: false
    command: []
    stdout: StdioCollector { id: commandOut; waitForEnd: true }
    stderr: StdioCollector { id: commandErr; waitForEnd: true }
    onExited: function(exitCode) {
      var raw = String(commandOut.text || "").trim()
      var ok = false
      try {
        var parsed = JSON.parse(raw)
        ok = parsed && parsed.ok === true
        if (!ok) root.actionError = parsed && parsed.error ? String(parsed.error) : "Befehl fehlgeschlagen"
      } catch (e) {
        root.actionError = String(commandErr.text || "Befehl fehlgeschlagen").substring(0, 200)
      }
      if (ok) root.actionError = ""
      // Covers travel for many seconds; burst-poll so the percentage animates.
      root.burstTicks = 8
      burstTimer.restart()
      Qt.callLater(root.pumpQueue)
      Qt.callLater(root.refresh)
    }
  }

  function openAll(entityIds) { command("open", entityIds) }
  function closeAll(entityIds) { command("close", entityIds) }
  function stopAll(entityIds) { command("stop", entityIds) }

  // --------------------------------------------------------------- discovery

  function discoverAreas() {
    if (!configured || areaProcess.running) return
    areaProcess.command = ["bash", helperPath, "areas"]
    areaProcess.running = true
  }

  Process {
    id: areaProcess
    running: false
    command: []
    stdout: StdioCollector { id: areaOut; waitForEnd: true }
    onExited: function(exitCode) {
      // Area/floor discovery is best-effort — a failure silently leaves the
      // name heuristic in charge.
      try {
        var parsed = JSON.parse(String(areaOut.text || ""))
        if (parsed && parsed.ok === true) root.discovered = Model.indexDiscovery(parsed.data)
      } catch (e) {
      }
    }
  }

  // ------------------------------------------------------------ connection test

  property string testState: ""   // "" | "running" | "ok" | "error"
  property string testMessage: ""

  function testConnection() {
    if (testProcess.running) return
    if (!configured) {
      testState = "error"
      testMessage = "URL and token are required"
      return
    }
    testState = "running"
    testMessage = "Connecting…"
    testProcess.command = ["bash", helperPath, "test"]
    testProcess.running = true
  }

  Process {
    id: testProcess
    running: false
    command: []
    stdout: StdioCollector { id: testOut; waitForEnd: true }
    stderr: StdioCollector { id: testErr; waitForEnd: true }
    onExited: function(exitCode) {
      try {
        var parsed = JSON.parse(String(testOut.text || ""))
        if (parsed && parsed.ok === true) {
          root.testState = "ok"
          root.testMessage = "Connected — " + parsed.data.covers + " covers found"
          root.failureCount = 0
          root.lastError = ""
          root.refresh()
          root.discoverAreas()
          return
        }
        root.testState = "error"
        root.testMessage = parsed && parsed.error ? String(parsed.error) : "Connection failed"
      } catch (e) {
        root.testState = "error"
        root.testMessage = String(testErr.text || "Connection failed").substring(0, 200)
      }
    }
  }

  // ------------------------------------------------------------------ polling

  readonly property int effectiveIntervalSec: {
    if (failureCount > 0) return Model.backoffSeconds(failureCount)
    if (burstTicks > 0) return 1
    if (panelOpen) return Model.clampInt(settings.openIntervalSec, 3, 1, 60)
    return Model.clampInt(settings.idleIntervalSec, 60, 10, 600)
  }

  Timer {
    id: pollTimer
    interval: Math.max(1, root.effectiveIntervalSec) * 1000
    repeat: true
    running: root.configured && root.settingsLoaded
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Counts the burst window down; the actual polling is driven by pollTimer,
  // whose interval drops to 1s while burstTicks is non-zero.
  Timer {
    id: burstTimer
    interval: 1000
    repeat: true
    running: root.burstTicks > 0
    onTriggered: root.burstTicks -= 1
  }

  onConfiguredChanged: if (configured) {
    failureCount = 0
    Qt.callLater(refresh)
    Qt.callLater(discoverAreas)
  }

  onPanelOpenChanged: if (panelOpen) {
    refresh()
    if (Object.keys(discovered).length === 0) discoverAreas()
  }
}

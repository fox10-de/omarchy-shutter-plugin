// Pure state logic for the fox10.shutters plugin. No QML imports here so the
// functions stay unit-testable with plain node/qmljs.

.pragma library

// Home Assistant CoverEntityFeature bits.
var FEATURE_OPEN = 1
var FEATURE_CLOSE = 2
var FEATURE_SET_POSITION = 4
var FEATURE_STOP = 8

var UNASSIGNED = "__unassigned__"
var IGNORED = "__ignored__"

var DEFAULT_FLOORS = ["Ground Floor", "First Floor"]

function defaultSettings() {
  return {
    version: 1,
    url: "",
    token: "",
    exclude: "",
    floors: DEFAULT_FLOORS.slice(),
    mapping: {},
    idleIntervalSec: 60,
    openIntervalSec: 3
  }
}

function clampInt(value, fallback, min, max) {
  var n = parseInt(value, 10)
  if (!isFinite(n)) n = fallback
  if (n < min) n = min
  if (n > max) n = max
  return n
}

// Normalizes whatever is on disk into a complete settings object.
function parseSettings(raw) {
  var out = defaultSettings()
  if (!raw) return out
  var parsed
  try {
    parsed = JSON.parse(String(raw))
  } catch (e) {
    return out
  }
  if (!parsed || typeof parsed !== "object") return out

  out.url = normalizeUrl(parsed.url)
  out.token = String(parsed.token || "").trim()
  out.exclude = String(parsed.exclude || "")
  if (Array.isArray(parsed.floors) && parsed.floors.length > 0) {
    var floors = []
    for (var i = 0; i < parsed.floors.length; i++) {
      var name = String(parsed.floors[i] || "").trim()
      if (name !== "" && floors.indexOf(name) === -1) floors.push(name)
    }
    if (floors.length > 0) out.floors = floors
  }
  if (parsed.mapping && typeof parsed.mapping === "object") {
    var mapping = {}
    for (var key in parsed.mapping) {
      if (!parsed.mapping.hasOwnProperty(key)) continue
      mapping[String(key)] = String(parsed.mapping[key] || "")
    }
    out.mapping = mapping
  }
  out.idleIntervalSec = clampInt(parsed.idleIntervalSec, 60, 10, 600)
  out.openIntervalSec = clampInt(parsed.openIntervalSec, 3, 1, 60)
  return out
}

// Trims whitespace, adds a scheme when the user typed a bare host, and drops
// any trailing slash so path concatenation in ha.sh stays predictable.
function normalizeUrl(value) {
  var url = String(value || "").trim()
  if (url === "") return ""
  if (!/^https?:\/\//i.test(url)) url = "https://" + url
  while (url.length > 1 && url.charAt(url.length - 1) === "/") url = url.substring(0, url.length - 1)
  return url
}

function isConfigured(settings) {
  return !!settings && String(settings.url || "") !== "" && String(settings.token || "") !== ""
}

// "cover.garage, cover.markise*" -> ["cover.garage", "cover.markise*"]
function parseExcludes(text) {
  var parts = String(text || "").split(/[,\n]/)
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var pattern = parts[i].trim().toLowerCase()
    if (pattern !== "") out.push(pattern)
  }
  return out
}

function globToRegExp(pattern) {
  var escaped = String(pattern).replace(/[.+^${}()|[\]\\]/g, "\\$&")
  escaped = escaped.replace(/\*/g, ".*").replace(/\?/g, ".")
  return new RegExp("^" + escaped + "$")
}

function matchesAny(entityId, patterns) {
  var id = String(entityId || "").toLowerCase()
  for (var i = 0; i < patterns.length; i++) {
    try {
      if (globToRegExp(patterns[i]).test(id)) return true
    } catch (e) {
      // A malformed pattern should never take the panel down.
    }
  }
  return false
}

// ha.sh already reduces /api/states to the fields we need; this turns it into
// the record the UI binds against.
function parseCovers(rawData) {
  var list = []
  if (!Array.isArray(rawData)) return list
  for (var i = 0; i < rawData.length; i++) {
    var item = rawData[i]
    if (!item || !item.entity_id) continue
    var state = String(item.state || "unknown")
    var position = item.position === null || item.position === undefined ? -1 : clampInt(item.position, -1, 0, 100)
    var features = clampInt(item.features, 15, 0, 1023)
    var available = state !== "unavailable" && state !== "unknown"
    list.push({
      entityId: String(item.entity_id),
      name: String(item.name || item.entity_id),
      state: state,
      position: position,
      features: features,
      deviceClass: String(item.device_class || ""),
      available: available,
      moving: state === "opening" || state === "closing",
      canStop: (features & FEATURE_STOP) !== 0,
      canOpen: (features & FEATURE_OPEN) !== 0,
      canClose: (features & FEATURE_CLOSE) !== 0,
      canSetPosition: (features & FEATURE_SET_POSITION) !== 0
    })
  }
  list.sort(function(a, b) { return a.name.localeCompare(b.name) })
  return list
}

function applyExcludes(covers, excludeText) {
  var patterns = parseExcludes(excludeText)
  if (patterns.length === 0) return covers.slice()
  var out = []
  for (var i = 0; i < covers.length; i++) {
    if (!matchesAny(covers[i].entityId, patterns)) out.push(covers[i])
  }
  return out
}

function excludedCount(covers, excludeText) {
  return covers.length - applyExcludes(covers, excludeText).length
}

// Guesses a floor from the entity id / friendly name when the user has not
// assigned one and Home Assistant gave us nothing.
function guessFloor(cover, floors) {
  var haystack = (String(cover.entityId) + " " + String(cover.name)).toLowerCase()
  // Keys are searched in the entity_id/name (which usually stay in the user's own
  // language); match[] is searched in the configured floor names.
  var hints = [
    { keys: ["erdgeschoss", "eg_", "_eg", " eg", "ground", "parterre", "downstairs"],
      match: ["erdgeschoss", "ground", "eg", "lower", "downstairs"] },
    { keys: ["obergeschoss", "og_", "_og", " og", "first floor", "dachgeschoss", "dg_", "_dg", "upstairs"],
      match: ["obergeschoss", "upper", "og", "dach", "first", "1st", "upstairs", "attic"] }
  ]
  for (var h = 0; h < hints.length; h++) {
    var hit = false
    for (var k = 0; k < hints[h].keys.length; k++) {
      if (haystack.indexOf(hints[h].keys[k]) !== -1) { hit = true; break }
    }
    if (!hit) continue
    for (var f = 0; f < floors.length; f++) {
      var floorLower = String(floors[f]).toLowerCase()
      for (var m = 0; m < hints[h].match.length; m++) {
        if (floorLower.indexOf(hints[h].match[m]) !== -1) return floors[f]
      }
    }
  }
  return ""
}

// Explicit mapping wins, then the HA area/floor hint, then the name heuristic.
function floorFor(cover, settings, discovered) {
  var explicit = settings && settings.mapping ? settings.mapping[cover.entityId] : undefined
  if (explicit === IGNORED) return IGNORED
  if (explicit && settings.floors.indexOf(explicit) !== -1) return explicit

  var floors = settings ? settings.floors : DEFAULT_FLOORS
  var hint = discovered ? discovered[cover.entityId] : null
  if (hint) {
    var candidates = [hint.floor, hint.area]
    for (var c = 0; c < candidates.length; c++) {
      var value = String(candidates[c] || "").trim()
      if (value === "") continue
      for (var i = 0; i < floors.length; i++) {
        if (String(floors[i]).toLowerCase() === value.toLowerCase()) return floors[i]
      }
    }
  }

  var guessed = guessFloor(cover, floors)
  return guessed !== "" ? guessed : UNASSIGNED
}

// Returns [{ key, title, covers: [...] }] in configured floor order, with an
// "Unassigned" bucket appended when anything is left over.
function groupByFloor(covers, settings, discovered) {
  var floors = settings && settings.floors ? settings.floors : DEFAULT_FLOORS
  var buckets = {}
  var sections = []
  for (var i = 0; i < floors.length; i++) {
    buckets[floors[i]] = { key: floors[i], title: floors[i], covers: [] }
    sections.push(buckets[floors[i]])
  }
  var unassigned = { key: UNASSIGNED, title: "Unassigned", covers: [] }

  for (var c = 0; c < covers.length; c++) {
    var floor = floorFor(covers[c], settings, discovered)
    if (floor === IGNORED) continue
    if (buckets[floor]) buckets[floor].covers.push(covers[c])
    else unassigned.covers.push(covers[c])
  }

  var out = []
  for (var s = 0; s < sections.length; s++) {
    if (sections[s].covers.length > 0) out.push(sections[s])
  }
  if (unassigned.covers.length > 0) out.push(unassigned)
  return out
}

function flattenRows(sections) {
  var rows = []
  for (var s = 0; s < sections.length; s++) {
    rows.push({ kind: "floor", sectionIndex: s, section: sections[s] })
    for (var c = 0; c < sections[s].covers.length; c++) {
      rows.push({ kind: "cover", sectionIndex: s, cover: sections[s].covers[c] })
    }
  }
  return rows
}

// Looks up the live cover object for an entity id in a covers array.
function findCover(covers, entityId) {
  if (!covers) return null
  for (var i = 0; i < covers.length; i++) {
    if (covers[i].entityId === entityId) return covers[i]
  }
  return null
}

function entityIdsOf(section) {
  var ids = []
  if (!section || !section.covers) return ids
  for (var i = 0; i < section.covers.length; i++) ids.push(section.covers[i].entityId)
  return ids
}

// "open" | "closed" | "partial" | "moving" | "empty"
function aggregateState(covers) {
  if (!covers || covers.length === 0) return "empty"
  var open = 0
  var closed = 0
  var moving = 0
  var known = 0
  for (var i = 0; i < covers.length; i++) {
    var cover = covers[i]
    if (cover.moving) moving++
    if (!cover.available) continue
    known++
    if (isOpen(cover)) open++
    else if (isClosed(cover)) closed++
  }
  if (moving > 0) return "moving"
  if (known === 0) return "empty"
  if (closed === known) return "closed"
  if (open === known) return "open"
  return "partial"
}

function isOpen(cover) {
  if (cover.position >= 0) return cover.position >= 100
  return cover.state === "open"
}

function isClosed(cover) {
  if (cover.position >= 0) return cover.position <= 0
  return cover.state === "closed"
}

function openCount(covers) {
  var n = 0
  for (var i = 0; i < covers.length; i++) {
    if (covers[i].available && !isClosed(covers[i])) n++
  }
  return n
}

function barGlyph(state, configured, hasError) {
  if (!configured || hasError) return "󰀨"
  switch (state) {
    case "moving": return "󰓡"
    case "open": return "󰖳"
    case "closed": return "󰖰"
    case "partial": return "󰂬"
    default: return "󰖰"
  }
}

function barTooltip(covers, configured, error) {
  if (!configured) return "Shutters — not configured (middle-click for settings)"
  if (error) return "Shutters — " + error
  if (!covers || covers.length === 0) return "Shutters — no covers found"
  var open = openCount(covers)
  return "Shutters — " + open + " open · " + (covers.length - open) + " closed"
}

// Position label for a row. Covers without a position report open/closed text.
function positionText(cover) {
  if (!cover) return "—"
  if (!cover.available) return "—"
  if (cover.position >= 0) return String(cover.position) + "%"
  if (cover.state === "open") return "Open"
  if (cover.state === "closed") return "Closed"
  return "—"
}

function stateGlyph(cover) {
  if (!cover) return ""
  if (cover.moving) return "󰝲"
  if (!cover.available) return "󰌙"
  return ""
}

function floorOptions(settings) {
  var options = [{ value: UNASSIGNED, label: "— automatic" }]
  var floors = settings && settings.floors ? settings.floors : DEFAULT_FLOORS
  for (var i = 0; i < floors.length; i++) options.push({ value: floors[i], label: floors[i] })
  options.push({ value: IGNORED, label: "— ignore" })
  return options
}

function mappingValue(settings, entityId) {
  var value = settings && settings.mapping ? settings.mapping[entityId] : undefined
  if (value === undefined || value === null || value === "") return UNASSIGNED
  if (value !== IGNORED && settings.floors.indexOf(value) === -1) return UNASSIGNED
  return value
}

// Index HA's template response by entity id for cheap lookups.
function indexDiscovery(rawData) {
  var out = {}
  if (!Array.isArray(rawData)) return out
  for (var i = 0; i < rawData.length; i++) {
    var item = rawData[i]
    if (!item || !item.entity_id) continue
    out[String(item.entity_id)] = {
      area: String(item.area || ""),
      floor: String(item.floor || "")
    }
  }
  return out
}

// Backoff for repeated failures: 5s, 10s, 20s, 40s, capped at 60s.
function backoffSeconds(failureCount) {
  if (failureCount <= 0) return 0
  return Math.min(60, 5 * Math.pow(2, Math.min(failureCount - 1, 4)))
}

function serializeSettings(settings) {
  return JSON.stringify({
    version: 1,
    url: normalizeUrl(settings.url),
    token: String(settings.token || "").trim(),
    exclude: String(settings.exclude || ""),
    floors: settings.floors || DEFAULT_FLOORS.slice(),
    mapping: settings.mapping || {},
    idleIntervalSec: clampInt(settings.idleIntervalSec, 60, 10, 600),
    openIntervalSec: clampInt(settings.openIntervalSec, 3, 1, 60)
  })
}

// Normalizes free-typed input from the position editor. Accepts "45", "45%",
// " 45 ", and clamps to 0-100. Returns -1 when it isn't a usable number.
function parsePositionInput(text) {
  var raw = String(text === undefined || text === null ? "" : text).trim()
  raw = raw.replace(/%/g, "").trim().replace(",", ".")
  if (raw === "" || !/^[0-9]+(\.[0-9]+)?$/.test(raw)) return -1
  var value = Math.round(parseFloat(raw))
  if (!isFinite(value)) return -1
  if (value < 0) value = 0
  if (value > 100) value = 100
  return value
}

// Value the inline editor starts with: the live position, or empty when the
// cover doesn't report one.
function positionEditSeed(cover) {
  if (!cover || cover.position < 0) return ""
  return String(cover.position)
}

.pragma library

// File lifecycle management for Downlodarchy.
// Tracks file age, staleness, and generates archive/delete decisions.
// All data stays local — no network, no cloud, no external dependencies.

// --- Data Schema (version 1) ---
// {
//   version: 1,
//   lastScan: "2024-01-15T10:30:00Z",
//   files: {
//     "/path/to/file.pdf": {
//       category: "Papers",
//       addedAt: "2024-01-10T08:00:00Z",
//       lastModified: "2024-01-12T14:30:00Z",
//       lastAccessed: "2024-01-14T09:15:00Z",
//       size: 1024000,
//       state: "active" | "stale" | "archived" | "deleted"
//     }
//   },
//   archiveIndex: {
//     "2024-01": ["/path/to/archived1.pdf", ...]
//   }
// }

var CURRENT_VERSION = 1

function emptyModel() {
  return {
    version: CURRENT_VERSION,
    lastScan: null,
    files: {},
    archiveIndex: {}
  }
}

// --- Input sanitization ---

function sanitizePath(path) {
  var p = String(path || "").trim()
  if (!p) return ""
  // Reject traversal patterns.
  if (p.indexOf("..") !== -1) return ""
  return p
}

function sanitizeCategory(cat) {
  var c = String(cat || "").trim()
  if (!c || c.indexOf("/") !== -1 || c.indexOf("\\") !== -1) return ""
  return c
}

// --- Time helpers ---

function nowISO() {
  return new Date().toISOString()
}

function daysSince(isoString) {
  if (!isoString) return Infinity
  var then = new Date(isoString).getTime()
  var now = Date.now()
  return (now - then) / (1000 * 60 * 60 * 24)
}

function daysAgo(days) {
  var d = new Date()
  d.setDate(d.getDate() - days)
  return d.toISOString()
}

// --- Core lifecycle logic ---

function fileState(addedAt, lastModified, lastAccessed, config) {
  var archiveDays = (config && config.archiveAfterDays) || 30
  var deleteDays = (config && config.deleteAfterDays) || 0

  // Check delete threshold first (most aggressive).
  if (deleteDays > 0) {
    var daysSinceMod = daysSince(lastModified)
    var daysSinceAcc = daysSince(lastAccessed)
    if (daysSinceMod >= deleteDays && daysSinceAcc >= deleteDays) {
      return "delete-eligible"
    }
  }

  // Check archive threshold.
  var daysSinceAdd = daysSince(addedAt)
  var daysSinceMod2 = daysSince(lastModified)
  var daysSinceAcc2 = daysSince(lastAccessed)

  // Archive if ALL timestamps are older than threshold.
  if (daysSinceAdd >= archiveDays && daysSinceMod2 >= archiveDays && daysSinceAcc2 >= archiveDays) {
    return "archive-eligible"
  }

  // Stale if any timestamp is getting old (half the archive threshold).
  var staleDays = archiveDays / 2
  if (daysSinceMod2 >= staleDays || daysSinceAcc2 >= staleDays) {
    return "stale"
  }

  return "active"
}

function classifyFiles(model, config) {
  var result = { active: [], stale: [], "archive-eligible": [], "delete-eligible": [] }
  var files = (model && model.files) || {}

  for (var path in files) {
    var entry = files[path]
    if (entry.state === "archived" || entry.state === "deleted") continue

    var state = fileState(entry.addedAt, entry.lastModified, entry.lastAccessed, config)
    entry.state = state
    result[state].push({
      path: path,
      category: entry.category,
      addedAt: entry.addedAt,
      lastModified: entry.lastModified,
      lastAccessed: entry.lastAccessed,
      size: entry.size || 0,
      state: state
    })
  }

  return result
}

// --- File tracking ---

function recordFile(model, path, category, metadata) {
  var p = sanitizePath(path)
  var cat = sanitizeCategory(category)
  if (!p || !cat) return model

  var m = model || emptyModel()
  var now = nowISO()

  m.files[p] = {
    category: cat,
    addedAt: (metadata && metadata.addedAt) || now,
    lastModified: (metadata && metadata.lastModified) || now,
    lastAccessed: (metadata && metadata.lastAccessed) || now,
    size: (metadata && metadata.size) || 0,
    state: "active"
  }

  return m
}

function markArchived(model, path, archivePath) {
  var p = sanitizePath(path)
  var ap = sanitizePath(archivePath)
  if (!p) return model

  var m = model || emptyModel()
  if (m.files[p]) {
    m.files[p].state = "archived"
    m.files[p].archivedAt = nowISO()
    m.files[p].archivePath = ap
  }

  // Update archive index.
  var dateKey = nowISO().slice(0, 7)  // "2024-01"
  if (!m.archiveIndex[dateKey]) m.archiveIndex[dateKey] = []
  m.archiveIndex[dateKey].push(p)

  return m
}

function markDeleted(model, path) {
  var p = sanitizePath(path)
  if (!p) return model

  var m = model || emptyModel()
  if (m.files[p]) {
    m.files[p].state = "deleted"
    m.files[p].deletedAt = nowISO()
  }

  return m
}

function removeFile(model, path) {
  var p = sanitizePath(path)
  if (!p) return model

  var m = model || emptyModel()
  delete m.files[p]
  return m
}

// --- Statistics ---

function lifecycleStats(model, config) {
  var classified = classifyFiles(model, config)
  var totalTracked = 0
  var totalArchived = 0
  var totalDeleted = 0
  var totalSize = 0

  var files = (model && model.files) || {}
  for (var p in files) {
    totalTracked++
    var f = files[p]
    if (f.state === "archived") totalArchived++
    if (f.state === "deleted") totalDeleted++
    totalSize += f.size || 0
  }

  return {
    lastScan: model ? model.lastScan : null,
    totalTracked: totalTracked,
    active: classified.active.length,
    stale: classified.stale.length,
    archiveEligible: classified["archive-eligible"].length,
    deleteEligible: classified["delete-eligible"].length,
    totalArchived: totalArchived,
    totalDeleted: totalDeleted,
    totalSizeBytes: totalSize,
    totalSizeFormatted: formatBytes(totalSize)
  }
}

function formatBytes(bytes) {
  if (bytes === 0) return "0 B"
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = Math.floor(Math.log(bytes) / Math.log(1024))
  i = Math.min(i, units.length - 1)
  var val = bytes / Math.pow(1024, i)
  return Math.round(val * 10) / 10 + " " + units[i]
}

// --- Persistence helpers ---

function modelToJSON(model) {
  return JSON.stringify(model || emptyModel(), null, 2)
}

function parseModel(raw) {
  if (!raw || !String(raw).trim()) return emptyModel()
  try {
    var parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== "object") return emptyModel()
    if (!parsed.version || parsed.version < CURRENT_VERSION) {
      return migrateModel(parsed)
    }
    return parsed
  } catch (e) {
    return emptyModel()
  }
}

function migrateModel(old) {
  var m = emptyModel()
  if (old && typeof old === "object") {
    m.files = old.files || {}
    m.archiveIndex = old.archiveIndex || {}
    m.lastScan = old.lastScan || null
  }
  return m
}

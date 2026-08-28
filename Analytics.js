.pragma library

// Analytics engine for Downlodarchy.
// Tracks sort events, computes statistics, and provides dashboard data.
// All data stays local — no network, no cloud, no external dependencies.

// --- Data Schema (version 1) ---
// {
//   version: 1,
//   events: [
//     {
//       id: "evt_1234567890",
//       timestamp: "2024-01-15T10:30:00Z",
//       file: "report.pdf",
//       extension: "pdf",
//       category: "Papers",
//       size: 1024000,
//       source: "auto" | "manual" | "classifier"
//     }
//   ],
//   stats: {
//     totalSorts: 150,
//     categoryCounts: { "Papers": 45, "Images": 30, ... },
//     extensionCounts: { "pdf": 25, "jpg": 15, ... },
//     dailyCounts: { "2024-01-15": 12, ... },
//     weeklyCounts: { "2024-W03": 45, ... },
//     monthlyCounts: { "2024-01": 150, ... }
//   }
// }

var CURRENT_VERSION = 1
var MAX_EVENTS = 10000  // Keep last 10k events to prevent unbounded growth.

function emptyModel() {
  return {
    version: CURRENT_VERSION,
    events: [],
    stats: {
      totalSorts: 0,
      categoryCounts: {},
      extensionCounts: {},
      dailyCounts: {},
      weeklyCounts: {},
      monthlyCounts: {}
    }
  }
}

// --- Input sanitization ---

function sanitizeString(str) {
  var s = String(str || "").trim()
  if (!s) return ""
  // Reject potential injection patterns.
  if (s.indexOf("\0") !== -1) return ""
  return s
}

function sanitizeExtension(ext) {
  var e = String(ext || "").trim().toLowerCase()
  e = e.replace(/^\.+/, "")
  if (!e || e.indexOf("/") !== -1 || e.indexOf("\\") !== -1) return ""
  return e
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

function dateKey(isoString) {
  // "2024-01-15T10:30:00Z" -> "2024-01-15"
  return isoString ? isoString.slice(0, 10) : ""
}

function weekKey(isoString) {
  // "2024-01-15T10:30:00Z" -> "2024-W03"
  if (!isoString) return ""
  var d = new Date(isoString)
  var year = d.getFullYear()
  var jan1 = new Date(year, 0, 1)
  var days = Math.floor((d - jan1) / (1000 * 60 * 60 * 24))
  var weekNum = Math.ceil((days + jan1.getDay() + 1) / 7)
  return year + "-W" + String(weekNum).padStart(2, "0")
}

function monthKey(isoString) {
  // "2024-01-15T10:30:00Z" -> "2024-01"
  return isoString ? isoString.slice(0, 7) : ""
}

function daysAgo(isoString, days) {
  if (!isoString) return false
  var then = new Date(isoString).getTime()
  var cutoff = Date.now() - (days * 24 * 60 * 60 * 1000)
  return then >= cutoff
}

// --- Core analytics ---

function recordEvent(model, eventData) {
  var m = model || emptyModel()
  var now = nowISO()

  var event = {
    id: "evt_" + Date.now() + "_" + Math.random().toString(36).slice(2, 8),
    timestamp: now,
    file: sanitizeString(eventData.file) || "unknown",
    extension: sanitizeExtension(eventData.extension),
    category: sanitizeCategory(eventData.category) || "Unsorted",
    size: parseInt(eventData.size, 10) || 0,
    source: sanitizeString(eventData.source) || "manual"
  }

  // Add event.
  m.events.push(event)

  // Trim old events if over limit.
  if (m.events.length > MAX_EVENTS) {
    m.events = m.events.slice(m.events.length - MAX_EVENTS)
  }

  // Update stats incrementally.
  m.stats.totalSorts++

  // Category counts.
  m.stats.categoryCounts[event.category] = (m.stats.categoryCounts[event.category] || 0) + 1

  // Extension counts.
  if (event.extension) {
    m.stats.extensionCounts[event.extension] = (m.stats.extensionCounts[event.extension] || 0) + 1
  }

  // Time-based counts.
  var dk = dateKey(now)
  var wk = weekKey(now)
  var mk = monthKey(now)
  m.stats.dailyCounts[dk] = (m.stats.dailyCounts[dk] || 0) + 1
  m.stats.weeklyCounts[wk] = (m.stats.weeklyCounts[wk] || 0) + 1
  m.stats.monthlyCounts[mk] = (m.stats.monthlyCounts[mk] || 0) + 1

  return m
}

// --- Statistics queries ---

function totalCount(model) {
  return (model && model.stats && model.stats.totalSorts) || 0
}

function categoryDistribution(model) {
  return (model && model.stats && model.stats.categoryCounts) || {}
}

function topCategory(model) {
  var counts = categoryDistribution(model)
  var best = null
  var bestCount = 0
  for (var cat in counts) {
    if (counts[cat] > bestCount) {
      bestCount = counts[cat]
      best = cat
    }
  }
  return best
}

function extensionDistribution(model) {
  return (model && model.stats && model.stats.extensionCounts) || {}
}

function topExtensions(model, limit) {
  var counts = extensionDistribution(model)
  var limit = limit || 10
  var sorted = []
  for (var ext in counts) {
    sorted.push({ extension: ext, count: counts[ext] })
  }
  sorted.sort(function(a, b) { return b.count - a.count })
  return sorted.slice(0, limit)
}

function dailyTrend(model, days) {
  var counts = (model && model.stats && model.stats.dailyCounts) || {}
  var limit = days || 7
  var result = []
  for (var i = 0; i < limit; i++) {
    var d = new Date()
    d.setDate(d.getDate() - i)
    var dk = dateKey(d.toISOString())
    result.unshift({ date: dk, count: counts[dk] || 0 })
  }
  return result
}

function weeklyTrend(model, weeks) {
  var counts = (model && model.stats && model.stats.weeklyCounts) || {}
  var limit = weeks || 4
  var result = []
  for (var i = 0; i < limit; i++) {
    var d = new Date()
    d.setDate(d.getDate() - (i * 7))
    var wk = weekKey(d.toISOString())
    result.unshift({ week: wk, count: counts[wk] || 0 })
  }
  return result
}

function monthlyTrend(model, months) {
  var counts = (model && model.stats && model.stats.monthlyCounts) || {}
  var limit = months || 6
  var result = []
  for (var i = 0; i < limit; i++) {
    var d = new Date()
    d.setMonth(d.getMonth() - i)
    var mk = monthKey(d.toISOString())
    result.unshift({ month: mk, count: counts[mk] || 0 })
  }
  return result
}

function recentEvents(model, limit) {
  var events = (model && model.events) || []
  var limit = limit || 10
  return events.slice(events.length - limit).reverse()
}

function eventsByCategory(model, category, limit) {
  var events = (model && model.events) || []
  var cat = sanitizeCategory(category)
  if (!cat) return []
  var limit = limit || 10
  var filtered = events.filter(function(e) { return e.category === cat })
  return filtered.slice(filtered.length - limit).reverse()
}

function eventsByDate(model, dateStr, limit) {
  var events = (model && model.events) || []
  var dk = sanitizeString(dateStr)
  if (!dk) return []
  var limit = limit || 100
  var filtered = events.filter(function(e) { return dateKey(e.timestamp) === dk })
  return filtered.slice(0, limit)
}

function sizeStats(model) {
  var events = (model && model.events) || []
  var totalSize = 0
  var count = 0
  var byCategory = {}

  for (var i = 0; i < events.length; i++) {
    var e = events[i]
    if (e.size > 0) {
      totalSize += e.size
      count++
      if (!byCategory[e.category]) byCategory[e.category] = 0
      byCategory[e.category] += e.size
    }
  }

  return {
    totalSizeBytes: totalSize,
    totalSizeFormatted: formatBytes(totalSize),
    filesWithSize: count,
    averageSizeBytes: count > 0 ? Math.round(totalSize / count) : 0,
    averageSizeFormatted: formatBytes(count > 0 ? Math.round(totalSize / count) : 0),
    byCategory: byCategory
  }
}

// --- Export ---

function exportCSV(model) {
  var events = (model && model.events) || []
  var lines = ["timestamp,file,extension,category,size,source"]
  for (var i = 0; i < events.length; i++) {
    var e = events[i]
    lines.push([
      e.timestamp,
      "\"" + (e.file || "").replace(/"/g, "\"\"") + "\"",
      e.extension,
      e.category,
      e.size,
      e.source
    ].join(","))
  }
  return lines.join("\n")
}

function exportJSON(model) {
  return JSON.stringify({
    exportedAt: nowISO(),
    totalEvents: (model && model.events) || 0,
    events: (model && model.events) || []
  }, null, 2)
}

// --- Utility ---

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
    m.events = Array.isArray(old.events) ? old.events : []
    // Rebuild stats from events if missing.
    if (old.stats) {
      m.stats = old.stats
    } else {
      m.stats = rebuildStats(m.events)
    }
  }
  return m
}

function rebuildStats(events) {
  var stats = {
    totalSorts: events.length,
    categoryCounts: {},
    extensionCounts: {},
    dailyCounts: {},
    weeklyCounts: {},
    monthlyCounts: {}
  }

  for (var i = 0; i < events.length; i++) {
    var e = events[i]
    if (e.category) stats.categoryCounts[e.category] = (stats.categoryCounts[e.category] || 0) + 1
    if (e.extension) stats.extensionCounts[e.extension] = (stats.extensionCounts[e.extension] || 0) + 1
    var dk = dateKey(e.timestamp)
    var wk = weekKey(e.timestamp)
    var mk = monthKey(e.timestamp)
    if (dk) stats.dailyCounts[dk] = (stats.dailyCounts[dk] || 0) + 1
    if (wk) stats.weeklyCounts[wk] = (stats.weeklyCounts[wk] || 0) + 1
    if (mk) stats.monthlyCounts[mk] = (stats.monthlyCounts[mk] || 0) + 1
  }

  return stats
}

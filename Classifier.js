.pragma library

// Local statistical classifier for Downlodarchy.
// Learns from user sort decisions to predict the best category for new files.
// Uses extension frequency + name pattern matching with configurable weights.
// All data stays local — no network, no cloud, no external dependencies.

// --- Data Schema (version 2) ---
// {
//   version: 2,
//   extensionRules: { "pdf": { "Papers": 15, "Documents": 3 }, ... },
//   namePatterns: { "IMG_": { "Images": 12 }, ... },
//   totalSorts: { "Papers": 18, ... },
//   sortCount: 58
// }

var CURRENT_VERSION = 2

function emptyModel() {
  return {
    version: CURRENT_VERSION,
    extensionRules: {},
    namePatterns: {},
    totalSorts: {},
    sortCount: 0
  }
}

// --- Input sanitization ---

function sanitizeExtension(ext) {
  var e = String(ext || "").trim().toLowerCase()
  // Strip leading dots, reject path separators.
  e = e.replace(/^\.+/, "")
  if (!e || e.indexOf("/") !== -1 || e.indexOf("\\") !== -1) return ""
  return e
}

function sanitizeCategory(cat) {
  var c = String(cat || "").trim()
  if (!c || c.indexOf("/") !== -1 || c.indexOf("\\") !== -1) return ""
  return c
}

// Extract name patterns from a filename. Returns an array of pattern strings.
// Patterns are lowercase, derived from the filename without extension.
function extractNamePatterns(fileName) {
  var name = String(fileName || "").trim()
  if (!name) return []
  // Strip extension.
  var dotIdx = name.lastIndexOf(".")
  if (dotIdx > 0) name = name.slice(0, dotIdx)
  name = name.toLowerCase()
  // Reject traversal or path components.
  if (name.indexOf("..") !== -1 || name.indexOf("/") !== -1 || name.indexOf("\\") !== -1)
    return []
  var patterns = []
  // Prefix patterns: "IMG_2024" -> ["IMG_", "IMG_202", "IMG_2024"]
  // Only emit patterns of length 3+ to avoid false positives.
  var parts = name.split(/[^a-z0-9]+/).filter(function(p) { return p.length >= 3 })
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i]
    // Full token.
    patterns.push(p)
    // Prefixes of length 3+.
    for (var len = 3; len < p.length; len++) {
      patterns.push(p.slice(0, len))
    }
  }
  return patterns
}

// --- Core learning ---

function record(model, extension, fileName, category) {
  var ext = sanitizeExtension(extension)
  var cat = sanitizeCategory(category)
  if (!ext || !cat) return model

  var m = model || emptyModel()

  // Extension rule.
  if (!m.extensionRules[ext]) m.extensionRules[ext] = {}
  m.extensionRules[ext][cat] = (m.extensionRules[ext][cat] || 0) + 1

  // Name patterns.
  var patterns = extractNamePatterns(fileName)
  for (var i = 0; i < patterns.length; i++) {
    var pat = patterns[i]
    if (!m.namePatterns[pat]) m.namePatterns[pat] = {}
    m.namePatterns[pat][cat] = (m.namePatterns[pat][cat] || 0) + 1
  }

  // Totals.
  m.totalSorts[cat] = (m.totalSorts[cat] || 0) + 1
  m.sortCount = (m.sortCount || 0) + 1

  return m
}

// --- Prediction ---

// Weight config: how much each signal contributes.
var DEFAULT_WEIGHTS = {
  extension: 1.0,
  namePattern: 0.6,
  globalBias: 0.15  // slight preference for frequently-used categories
}

function predict(model, extension, fileName, categories, weights) {
  var w = weights || DEFAULT_WEIGHTS
  var m = model || emptyModel()
  var ext = sanitizeExtension(extension)
  if (!ext) return null

  var catNames = []
  for (var i = 0; i < (categories || []).length; i++) {
    var n = sanitizeCategory(categories[i].name || categories[i])
    if (n) catNames.push(n)
  }
  if (catNames.length === 0) return null

  // Score each category.
  var scores = {}
  var maxScore = 0
  for (var j = 0; j < catNames.length; j++) {
    scores[catNames[j]] = 0
  }

  // Signal 1: extension frequency.
  var extRules = m.extensionRules[ext] || {}
  var extTotal = 0
  for (var k in extRules) extTotal += extRules[k]
  if (extTotal > 0) {
    for (var ci = 0; ci < catNames.length; ci++) {
      var cat = catNames[ci]
      var freq = extRules[cat] || 0
      scores[cat] += w.extension * (freq / extTotal)
    }
  }

  // Signal 2: name pattern frequency.
  var patterns = extractNamePatterns(fileName)
  var patMatchCount = 0
  for (var pi = 0; pi < patterns.length; pi++) {
    var patRules = m.namePatterns[patterns[pi]]
    if (!patRules) continue
    patMatchCount++
    var patTotal = 0
    for (var pk in patRules) patTotal += patRules[pk]
    if (patTotal > 0) {
      for (var ci2 = 0; ci2 < catNames.length; ci2++) {
        var cat2 = catNames[ci2]
        var patFreq = patRules[cat2] || 0
        scores[cat2] += w.namePattern * (patFreq / patTotal)
      }
    }
  }

  // Signal 3: global category bias (prevents never-seen categories from winning).
  var maxSorts = 0
  for (var tk in m.totalSorts) {
    if (m.totalSorts[tk] > maxSorts) maxSorts = m.totalSorts[tk]
  }
  if (maxSorts > 0) {
    for (var ci3 = 0; ci3 < catNames.length; ci3++) {
      var cat3 = catNames[ci3]
      var catSorts = m.totalSorts[cat3] || 0
      scores[cat3] += w.globalBias * (catSorts / maxSorts)
    }
  }

  // Find winner.
  var bestCat = null
  var bestScore = -1
  for (var bk in scores) {
    if (scores[bk] > bestScore) {
      bestScore = scores[bk]
      bestCat = bk
    }
  }
  if (bestCat === null || bestScore === 0) return null

  // Compute confidence: winner score / sum of all scores.
  var totalScore = 0
  for (var sk in scores) totalScore += scores[sk]
  var confidence = totalScore > 0 ? bestScore / totalScore : 0

  // Build ranked alternatives.
  var ranked = []
  for (var rk in scores) {
    if (rk !== bestCat && scores[rk] > 0) {
      ranked.push({ category: rk, score: scores[rk] })
    }
  }
  ranked.sort(function(a, b) { return b.score - a.score })

  return {
    category: bestCat,
    confidence: Math.round(confidence * 1000) / 1000,
    alternatives: ranked.slice(0, 3),
    signalCounts: {
      extensionRules: extTotal > 0 ? 1 : 0,
      namePatterns: patMatchCount
    }
  }
}

// --- History persistence helpers ---

function modelToJSON(model) {
  return JSON.stringify(model || emptyModel(), null, 2)
}

function parseModel(raw) {
  if (!raw || !String(raw).trim()) return emptyModel()
  try {
    var parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== "object") return emptyModel()
    // Version migration.
    if (!parsed.version || parsed.version < CURRENT_VERSION) {
      return migrateModel(parsed)
    }
    return parsed
  } catch (e) {
    return emptyModel()
  }
}

function migrateModel(old) {
  // v1 -> v2: no schema change yet, just ensure fields exist.
  var m = emptyModel()
  if (old && typeof old === "object") {
    m.extensionRules = old.extensionRules || {}
    m.namePatterns = old.namePatterns || {}
    m.totalSorts = old.totalSorts || {}
    m.sortCount = old.sortCount || 0
  }
  return m
}

// --- Utility ---

function totalDecisions(model) {
  return (model && model.sortCount) || 0
}

function topCategory(model) {
  if (!model || !model.totalSorts) return null
  var best = null
  var bestCount = 0
  for (var k in model.totalSorts) {
    if (model.totalSorts[k] > bestCount) {
      bestCount = model.totalSorts[k]
      best = k
    }
  }
  return best
}

function extensionStats(model) {
  var stats = {}
  var rules = (model && model.extensionRules) || {}
  for (var ext in rules) {
    var cats = rules[ext]
    var total = 0
    for (var c in cats) total += cats[c]
    stats[ext] = { totalSorts: total, categories: cats }
  }
  return stats
}

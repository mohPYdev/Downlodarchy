.pragma library

// Pure data helpers for Downlodarchy. File I/O lives in the QML side
// (FileView); everything here is parse/normalize/filter only.

function defaultCategories() {
  return [
    { name: "Unsorted", icon: "\uf01c" },
    { name: "Papers", icon: "\uf15c" },
    { name: "Applications", icon: "\uf1b2" },
    { name: "Images", icon: "\uf03e" },
    { name: "Backgrounds", icon: "\uf1fc" },
    { name: "Videos", icon: "\uf008" },
    { name: "Music", icon: "\uf001" },
    { name: "Archives", icon: "\uf1c6" }
  ]
}

function defaultConfig() {
  return {
    version: 1,
    defaultCategory: "Unsorted",
    categories: defaultCategories()
  }
}

// Strip path separators, traversal, and whitespace so a typed category can
// never escape ~/Downloads. Rejects any value containing path separators,
// dot or dot-dot, or empty results.
function normalizeName(name) {
  var n = String(name || "").trim()
  if (!n) return ""
  // Strip path separators and traversal components.
  n = n.replace(/[\/\\]/g, " ")
  n = n.replace(/\.\./g, " ")
  n = n.replace(/\b\.\b/g, " ")
  n = n.replace(/\s+/g, " ").trim()
  // Final guard: empty or pure-separator residue.
  if (!n || /^[.\s]+$/.test(n)) return ""
  return n
}

function sanitizeIcon(icon, fallback) {
  var i = String(icon || "").trim()
  return i.length > 0 ? i : (fallback || "\uf016")
}

function findCategory(config, name) {
  var wanted = normalizeName(name).toLowerCase()
  var cats = (config && config.categories) || []
  for (var i = 0; i < cats.length; i++)
    if (normalizeName(cats[i].name).toLowerCase() === wanted) return cats[i]
  return null
}

// Parse raw config.json content. Falls back field-by-field to defaults so a
// hand-edited partial file never breaks the plugin.
function parseConfig(raw) {
  var cfg = defaultConfig()
  if (!raw || !String(raw).trim()) return cfg
  var parsed
  try { parsed = JSON.parse(raw) } catch (e) { return cfg }
  if (!parsed || typeof parsed !== "object") return cfg

  if (Array.isArray(parsed.categories)) {
    var seen = {}
    var cats = []
    for (var i = 0; i < parsed.categories.length; i++) {
      var entry = parsed.categories[i]
      var name = normalizeName(entry && typeof entry === "object" ? entry.name : entry)
      if (!name || seen[name.toLowerCase()]) continue
      seen[name.toLowerCase()] = true
      cats.push({ name: name, icon: sanitizeIcon(typeof entry === "object" ? entry.icon : "") })
    }
    if (cats.length > 0) cfg.categories = cats
  }

  var def = normalizeName(parsed.defaultCategory)
  if (def && findCategory({ categories: cfg.categories }, def)) cfg.defaultCategory = def
  else cfg.defaultCategory = cfg.categories[0].name

  return cfg
}

// Filter-as-you-type. Empty filter returns everything in stored order.
function filterCategories(categories, filterText) {
  var f = String(filterText || "").trim().toLowerCase()
  if (!f) return categories.slice()
  var out = []
  for (var i = 0; i < categories.length; i++)
    if (String(categories[i].name).toLowerCase().indexOf(f) !== -1) out.push(categories[i])
  return out
}

function hasExactCategory(categories, filterText) {
  var f = normalizeName(filterText).toLowerCase()
  if (!f) return false
  for (var i = 0; i < categories.length; i++)
    if (String(categories[i].name).toLowerCase() === f) return true
  return false
}

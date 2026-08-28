import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Config.js" as Config

// Downlodarchy service: watches ~/Downloads for completed files, asks which
// category folder each belongs in (Picker overlay below), and moves it there.
// Dismissing or timing out files into the default category ("Unsorted"
// initially). Also owns the IPC surface for manual triggers.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string downloadsDir: homeDir + "/Downloads"
  readonly property string configDir: homeDir + "/.config/downlodarchy"
  readonly property string configPath: configDir + "/config.json"

  property var config: Config.defaultConfig()
  property var queue: []
  property var moveQueue: []
  property var recentPaths: ({})
  property string currentFile: ""

  // Hard limits to prevent resource exhaustion.
  readonly property int maxQueueSize: 50
  readonly property int maxMoveQueueSize: 20
  readonly property int maxOrganizeEntries: 100
  readonly property int maxConfigCategories: 50
  readonly property int maxStdioBytes: 524288  // 512 KB

  readonly property string watcherPidFile: (Qt.getenv("XDG_RUNTIME_DIR") || homeDir + "/.cache") + "/downlodarchy-watcher.pid"

  Component.onCompleted: {
    dirsProc.command = ["mkdir", "-p", root.configDir, root.downloadsDir]
    dirsProc.running = true
    // Kill any stale watcher from a previous service instance using the
    // PID file it left behind. Validates each PID via /proc/<pid>/cmdline
    // to ensure it belongs to this plugin's watcher before signaling.
    // Uses kill -- -$pid to terminate the entire process group atomically.
    cleanupProc.command = ["bash", "-c",
      "if [ -f \"$1\" ]; then " +
      "  while IFS= read -r pid; do " +
      "    pid=${pid%%[^0-9]*}; " +
      "    [ -d \"/proc/$pid\" ] || continue; " +
      "    cmd=$(tr '\\0' ' ' < \"/proc/$pid/cmdline\" 2>/dev/null) || continue; " +
      "    case \"$cmd\" in *downlodarchy*watch*) kill -- -\"$pid\" 2>/dev/null ;; esac; " +
      "  done < \"$1\"; " +
      "  rm -f \"$1\"; " +
      "fi",
      "cleanup", root.watcherPidFile]
    cleanupProc.running = true
  }

  function defaultCategoryName() {
    return root.config.defaultCategory || "Unsorted"
  }

  // ------------------------------------------------------------- watching

  function scriptPath(name) {
    return Qt.resolvedUrl(name).toString().replace(/^file:\/\//, "")
  }

  function startWatcher() {
    if (watcherProc.running) return
    // setsid creates a new session + process group so all pipeline
    // members share one PGID that can be killed atomically.
    watcherProc.command = ["setsid", "bash", root.scriptPath("watch.sh"), root.downloadsDir]
    watcherProc.running = true
  }

  function handleWatchEvent(line) {
    var p = String(line).trim()
    if (!p || p.indexOf(root.downloadsDir + "/") !== 0) return
    if (root.recentPaths[p]) return
    root.recentPaths[p] = true
    dedupeTimer.restart()
    root.enqueue(p)
  }

  // Reject paths outside ~/Downloads, nested subdirs, or traversal.
  function validPath(path) {
    var p = String(path || "").trim()
    if (!p || p.indexOf(root.downloadsDir + "/") !== 0) return false
    var rel = p.slice(root.downloadsDir.length + 1)
    // Direct child only — no subdirectories or traversal.
    return rel !== "" && rel.indexOf("/") === -1 && rel !== "." && rel !== ".."
  }

  function enqueue(path) {
    if (!root.validPath(path)) return
    if (root.queue.length >= root.maxQueueSize) return
    var next = root.queue.slice()
    for (var i = 0; i < next.length; i++)
      if (next[i] === path) return
    next.push(path)
    root.queue = next
    root.maybeShowNext()
  }

  function maybeShowNext() {
    if (picker.opened || root.currentFile !== "" || root.queue.length === 0) return
    var next = root.queue.slice()
    root.currentFile = next.shift()
    root.queue = next
    picker.openFor(root.currentFile)
  }

  function pickDone(file, category) {
    if (root.currentFile === file) root.currentFile = ""
    root.sortFile(file, category)
    root.maybeShowNext()
  }

  function sortFile(file, category) {
    var name = Config.normalizeName(category)
    if (!name) name = root.defaultCategoryName()
    if (root.moveQueue.length >= root.maxMoveQueueSize) return
    var next = root.moveQueue.slice()
    for (var i = 0; i < next.length; i++)
      if (next[i].file === file && next[i].category === name) return
    next.push({ file: file, category: name })
    root.moveQueue = next
    root.pumpMoveQueue()
  }

  function pumpMoveQueue() {
    if (moverProc.running || root.moveQueue.length === 0) return
    var job = root.moveQueue[0]
    moverProc.command = [
      "bash", root.scriptPath("move.sh"),
      root.downloadsDir, job.file, job.category
    ]
    moverProc.running = true
  }

  function moveFailed() {
    Quickshell.execDetached([
      root.omarchyPath + "/bin/omarchy-notification-send",
      "-u", "normal", "Downlodarchy",
      "Could not sort a downloaded file — is it still being written?"
    ])
  }

  Timer {
    id: dedupeTimer
    interval: 2000
    onTriggered: root.recentPaths = ({})
  }

  Timer {
    id: watcherRestartTimer
    interval: 3000
    onTriggered: root.startWatcher()
  }

  Timer {
    id: watcherStartTimer
    interval: 400
    onTriggered: root.startWatcher()
  }

  Process { id: dirsProc }

  // Reads the PID file and kills stale watchers individually.
  Process {
    id: cleanupProc
    onExited: watcherStartTimer.restart()
  }

  Process {
    id: watcherProc
    onExited: function(code) {
      // inotifywait only exits on failure; back off and retry so a blip
      // doesn't silently end download tracking.
      if (code !== 0) watcherRestartTimer.restart()
    }
    stdout: SplitParser {
      onRead: function(line) { root.handleWatchEvent(line) }
    }
  }

  Process {
    id: moverProc
    stdout: StdioCollector { waitForEnd: false }
    onExited: function(code) {
      if (code !== 0) root.moveFailed()
      var next = root.moveQueue.slice()
      next.shift()
      root.moveQueue = next
      root.pumpMoveQueue()
    }
  }

  // --------------------------------------------------------------- config

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.config = Config.parseConfig(text())
    onLoadFailed: {
      root.config = Config.defaultConfig()
      configFile.setText(JSON.stringify(root.config, null, 2) + "\n")
    }
    onFileChanged: reload()
  }

  function saveConfig() {
    configFile.setText(JSON.stringify(root.config, null, 2) + "\n")
  }

  function addCategory(name, icon) {
    var clean = Config.normalizeName(name)
    if (!clean) return false
    if (Config.findCategory(root.config, clean)) return false
    if (root.config.categories.length >= root.maxConfigCategories) return false
    var next = root.config.categories.concat([{ name: clean, icon: Config.sanitizeIcon(icon, "\uf016") }])
    root.config = Object.assign({}, root.config, { categories: next })
    root.saveConfig()
    return true
  }

  function removeCategory(name) {
    if (name === root.defaultCategoryName()) return false
    var clean = Config.normalizeName(name)
    var cats = root.config.categories.filter(function(c) {
      return Config.normalizeName(c.name).toLowerCase() !== clean.toLowerCase()
    })
    if (cats.length === root.config.categories.length) return false
    root.config = Object.assign({}, root.config, { categories: cats })
    root.saveConfig()
    return true
  }

  function setDefaultCategory(name) {
    var clean = Config.normalizeName(name)
    if (!Config.findCategory(root.config, clean)) return false
    root.config = Object.assign({}, root.config, { defaultCategory: clean })
    root.saveConfig()
    return true
  }

  // ------------------------------------------------------------------ ipc

  IpcHandler {
    target: "mohpydev.downlodarchy"

    // Open the category box for one specific file right now.
    // Rejects paths outside ~/Downloads or nested in subdirectories.
    function pick(path: string) {
      root.enqueue(path)
    }

    // Queue stray files sitting in the Downloads root, capped to prevent
    // resource exhaustion from a large or attacker-populated directory.
    function organize() {
      sweepProc.command = [
        "bash", "-c",
        "find \"$1\" -maxdepth 1 -type f -not -name \".*\" ! -name \"*.part\" ! -name \"*.crdownload\" ! -name \"*.tmp\" -print | head -\"$2\" | sort",
        "find", root.downloadsDir, String(root.maxOrganizeEntries)
      ]
      sweepProc.running = true
    }

    // Report current settings as JSON (handy for scripting/debugging).
    function status(): string {
      return JSON.stringify({ downloadsDir: root.downloadsDir, defaultCategory: root.defaultCategoryName(), categories: root.config.categories })
    }
  }

  Process {
    id: sweepProc
    stdout: StdioCollector {
      waitForEnd: true
      maxBytes: root.maxStdioBytes
      onStreamFinished: {
        var lines = text.split("\n")
        var count = 0
        for (var i = 0; i < lines.length && count < root.maxOrganizeEntries; i++) {
          var p = lines[i].trim()
          if (p) {
            root.enqueue(p)
            count++
          }
        }
      }
    }
  }

  // --------------------------------------------------------------- picker

  Picker {
    id: picker
    service: root
  }
}

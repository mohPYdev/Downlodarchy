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

  Component.onCompleted: {
    dirsProc.command = ["mkdir", "-p", root.configDir, root.downloadsDir]
    dirsProc.running = true
    // Hot-reloads and plugin swaps can orphan the previous watcher's
    // pipeline (inotifywait + loop subshell survive their killed parent).
    // Clear any stale instances before starting ours; dedupe covers any
    // brief overlap.
    staleKillProc.command = ["bash", "-c",
      "pkill -f \"" + root.scriptPath("watch.sh") + "\"; " +
      "pkill -f \"inotifywait.*close_write,moved_to.*" + root.downloadsDir + "\"",
      "pkill"]
    staleKillProc.running = true
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
    watcherProc.command = ["bash", root.scriptPath("watch.sh"), root.downloadsDir]
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

  function enqueue(path) {
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

  // pkill exits non-zero when nothing matched; that's fine.
  Process {
    id: staleKillProc
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
    function pick(path: string) {
      root.enqueue(path)
    }

    // Queue every stray file still sitting in the Downloads root.
    function organize() {
      sweepProc.command = [
        "bash", "-c",
        "find \"$1\" -maxdepth 1 -type f -not -name \".*\" ! -name \"*.part\" ! -name \"*.crdownload\" ! -name \"*.tmp\" -print | sort",
        "find", root.downloadsDir
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
      onStreamFinished: {
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var p = lines[i].trim()
          if (p) root.enqueue(p)
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

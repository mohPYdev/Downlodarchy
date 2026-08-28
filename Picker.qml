import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Config.js" as Config

// Floating box that asks which category folder a new download belongs in.
// Lives inside the service so it can pop without any loader round-trip.
// Esc, scrim click, or ~20s idle files the download into the default
// category; typing filters and creates categories; enter sorts.
Item {
  id: root

  property var service: null
  property bool opened: false
  property string filePath: ""
  property string filterText: ""
  property int cursorIndex: 0
  property var currentPrediction: null

  readonly property string fileName: {
    var p = root.filePath
    var idx = p.lastIndexOf("/")
    return idx >= 0 ? p.slice(idx + 1) : p
  }
  readonly property var allCategories: service ? (service.config.categories || []) : []
  readonly property var shownCategories: Config.filterCategories(root.allCategories, root.filterText)
  // The trailing pseudo-row "+ Create '<filter>'".
  readonly property bool canCreate: root.filterText.trim() !== ""
    && !Config.hasExactCategory(root.allCategories, root.filterText)
    && Config.normalizeName(root.filterText) !== ""
  readonly property int rowCount: root.shownCategories.length + (root.canCreate ? 1 : 0)

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color border: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int rowHeight: Style.space(36)
  readonly property real cardWidth: Style.space(440)

  function openFor(path, prediction) {
    root.filePath = String(path || "")
    root.filterText = ""
    root.currentPrediction = prediction || null
    root.opened = true
    root.resetCursor()
    idleTimer.restart()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function resetCursor() {
    var idx = 0
    // Pre-select predicted category if available.
    if (root.currentPrediction && root.currentPrediction.category) {
      var predName = String(root.currentPrediction.category).toLowerCase()
      for (var i = 0; i < root.shownCategories.length; i++) {
        if (String(root.shownCategories[i].name).toLowerCase() === predName) {
          idx = i
          break
        }
      }
    } else {
      var def = root.service ? root.service.defaultCategoryName() : ""
      for (var j = 0; j < root.shownCategories.length; j++) {
        if (String(root.shownCategories[j].name).toLowerCase() === def.toLowerCase()) { idx = j; break }
      }
    }
    root.cursorIndex = root.rowCount > 0 ? Math.min(idx, root.rowCount - 1) : 0
    Qt.callLater(function() {
      if (root.opened && root.rowCount > 0) list.positionViewAtIndex(root.cursorIndex, ListView.Contain)
    })
  }

  function interacted() {
    idleTimer.restart()
  }

  function moveCursor(delta) {
    if (root.rowCount === 0) return
    root.cursorIndex = (root.cursorIndex + delta + root.rowCount) % root.rowCount
    list.positionViewAtIndex(root.cursorIndex, ListView.Contain)
    interacted()
  }

  function setFilter(next) {
    root.filterText = next
    root.interacted()
    if (root.cursorIndex >= root.rowCount) root.cursorIndex = Math.max(0, root.rowCount - 1)
  }

  function categoryNameAt(index) {
    if (index < 0 || index >= root.shownCategories.length) return ""
    return String(root.shownCategories[index].name)
  }

  function activate(index) {
    if (!root.service || !root.opened) return
    var file = root.filePath
    if (index >= root.shownCategories.length) {
      // Create row.
      var name = Config.normalizeName(root.filterText)
      if (!name) return
      root.service.addCategory(name)
      root.close()
      root.service.pickDone(file, name)
      return
    }
    var chosen = root.categoryNameAt(index)
    if (!chosen) return
    root.close()
    root.service.pickDone(file, chosen)
  }

  // Dismissal always falls back to the default category, never "leave it".
  function dismiss() {
    if (!root.opened) return
    var file = root.filePath
    var def = root.service ? root.service.defaultCategoryName() : "Unsorted"
    root.close()
    root.service.pickDone(file, def)
  }

  function close() {
    root.opened = false
    root.filePath = ""
    root.filterText = ""
    root.currentPrediction = null
  }

  Timer {
    id: idleTimer
    interval: 20000
    onTriggered: root.dismiss()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "downlodarchy-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: content.implicitHeight + card.contentTopInset + card.contentBottomInset
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.moveCursor(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveCursor(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(root.cursorIndex)
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        Column {
          id: content
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset
          spacing: Style.space(12)

          // ----- header
          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              text: "SORT DOWNLOAD"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }

            Text {
              width: parent.width
              text: root.fileName
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              elide: Text.ElideMiddle
            }

            Text {
              width: parent.width
              text: root.cursorIndex < root.shownCategories.length
                ? "→ ~/Downloads/" + root.categoryNameAt(root.cursorIndex)
                : "→ new category"
              textFormat: Text.PlainText
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideMiddle
            }
          }

          // ----- category list
          ListView {
            id: list
            width: parent.width
            height: Math.min(root.rowCount * root.rowHeight, root.rowHeight * 7)
            clip: true
            interactive: true

            model: root.rowCount

            delegate: Item {
              id: rowDelegate
              required property int index
              width: list.width
              height: root.rowHeight

              readonly property bool isCreate: index >= root.shownCategories.length
              readonly property var cat: isCreate ? null : root.shownCategories[index]
              readonly property bool hasCursor: root.cursorIndex === index

              Rectangle {
                anchors.fill: parent
                radius: Style.space(6)
                color: rowDelegate.hasCursor ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10) : "transparent"
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onPositionChanged: {
                  if (root.cursorIndex !== rowDelegate.index) root.cursorIndex = rowDelegate.index
                  root.interacted()
                }
                onClicked: root.activate(rowDelegate.index)
              }

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(10)

                Text {
                  width: Style.space(22)
                  anchors.verticalCenter: parent.verticalCenter
                  text: rowDelegate.isCreate ? "\uf055" : Config.sanitizeIcon(rowDelegate.cat.icon)
                  textFormat: Text.PlainText
                  color: rowDelegate.isCreate ? Color.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(22) - parent.spacing * 2 - defaultBadge.width - predictionBadge.width - (predictionBadge.visible ? parent.spacing : 0)
                  text: rowDelegate.isCreate
                    ? "Create \u201C" + Config.normalizeName(root.filterText) + "\u201D"
                    : rowDelegate.cat.name
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: rowDelegate.hasCursor
                  elide: Text.ElideRight
                }

                Rectangle {
                  id: defaultBadge
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !rowDelegate.isCreate && root.service
                    && String(rowDelegate.cat.name).toLowerCase() === String(root.service.defaultCategoryName()).toLowerCase()
                  width: defaultLabel.implicitWidth + Style.space(12)
                  height: Style.space(18)
                  radius: height / 2
                  color: Color.accent

                  Text {
                    id: defaultLabel
                    anchors.centerIn: parent
                    text: "DEFAULT"
                    color: Color.background
                    font.family: root.fontFamily
                    font.pixelSize: Math.max(9, Style.font.caption - 2)
                    font.bold: true
                    font.letterSpacing: 0.8
                  }
                }

                Rectangle {
                  id: predictionBadge
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !rowDelegate.isCreate && root.currentPrediction
                    && root.currentPrediction.category
                    && String(rowDelegate.cat.name).toLowerCase() === String(root.currentPrediction.category).toLowerCase()
                  width: predictionLabel.implicitWidth + Style.space(12)
                  height: Style.space(18)
                  radius: height / 2
                  color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)

                  Text {
                    id: predictionLabel
                    anchors.centerIn: parent
                    text: "AI " + Math.round((root.currentPrediction.confidence || 0) * 100) + "%"
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Math.max(9, Style.font.caption - 2)
                    font.bold: true
                    font.letterSpacing: 0.8
                  }
                }
              }
            }
          }

          // ----- footer hints
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "↵ sort · esc " + (root.service ? root.service.defaultCategoryName() : "default") + " · type to search or create"
            textFormat: Text.PlainText
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}

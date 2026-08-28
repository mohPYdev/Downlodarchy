import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Config.js" as Config
import "Analytics.js" as Analytics

// Bar widget: download icon -> popup listing category folders.
// Click a row to open that folder in the file manager; the star column
// shows/sets the default category (where dismissed downloads land).
Panel {
  id: root

  moduleName: "mohpydev.downlodarchy"
  ipcTarget: "mohpydev.downlodarchy.menu"

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string downloadsDir: homeDir + "/Downloads"
  readonly property string configPath: homeDir + "/.config/downlodarchy/config.json"
  readonly property string analyticsPath: homeDir + "/.config/downlodarchy/history.json"

  property var configData: Config.defaultConfig()
  property var analyticsData: Analytics.emptyModel()
  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property var categories: configData.categories || []
  readonly property string defaultCategory: configData.defaultCategory || ""
  readonly property string foregroundColor: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property int totalSorts: Analytics.totalCount(root.analyticsData)
  readonly property string topCategoryName: Analytics.topCategory(root.analyticsData) || "—"

  function openFolder(name) {
    Quickshell.execDetached(["xdg-open", root.downloadsDir + "/" + Config.normalizeName(name)])
    root.close()
  }

  function setDefault(name) {
    var clean = Config.normalizeName(name)
    if (!Config.findCategory(root.configData, clean)) return
    root.configData = Object.assign({}, root.configData, { defaultCategory: clean })
    configFile.setText(JSON.stringify(root.configData, null, 2) + "\n")
  }

  function sortLeftovers() {
    leftoverProc.command = ["omarchy-shell", "mohpydev.downlodarchy", "organize"]
    leftoverProc.running = true
    root.close()
  }

  function selectByDelta(dy) {
    if (!root.cursorActive) { root.cursorActive = true; return }
    if (root.categories.length === 0) return
    root.cursorIndex = (root.cursorIndex + dy + root.categories.length) % root.categories.length
  }

  function activateSelected() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.categories.length) return
    root.openFolder(root.categories[root.cursorIndex].name)
  }

  function setDefaultSelected() {
    if (root.cursorIndex < 0 || root.cursorIndex >= root.categories.length) return
    root.setDefault(root.categories[root.cursorIndex].name)
  }

  onOpenedChanged: {
    if (opened) {
      configFile.reload()
      analyticsFile.reload()
      cursorActive = false
      var def = String(root.defaultCategory).toLowerCase()
      var idx = 0
      for (var i = 0; i < root.categories.length; i++)
        if (String(root.categories[i].name).toLowerCase() === def) { idx = i; break }
      cursorIndex = idx
    }
  }

  Process { id: leftoverProc }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.configData = Config.parseConfig(text())
    onLoadFailed: root.configData = Config.defaultConfig()
    onFileChanged: reload()
  }

  FileView {
    id: analyticsFile
    path: root.analyticsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.analyticsData = Analytics.parseModel(text())
    onLoadFailed: root.analyticsData = Analytics.emptyModel()
    onFileChanged: reload()
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf019"
    tooltipText: "Downloads"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.selectByDelta(dy)
        else if (dx > 0) root.setDefaultSelected()
      }
      onActivateRequested: if (root.cursorActive) root.activateSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelSectionHeader {
          text: "DOWNLOADS"
          foreground: root.foregroundColor
          fontFamily: root.fontFamily
        }

        // ----- actions
        Row {
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth: (width - spacing) / 2

          Button {
            width: parent.cellWidth
            iconText: "\uf07c"
            iconSize: Style.font.title
            text: "Open"
            fontSize: Style.font.bodySmall
            foreground: root.foregroundColor
            fontFamily: root.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            onClicked: Quickshell.execDetached(["xdg-open", root.downloadsDir])
          }

          Button {
            width: parent.cellWidth
            iconText: "\uf01c"
            iconSize: Style.font.title
            text: "Sort leftovers"
            fontSize: Style.font.bodySmall
            foreground: root.foregroundColor
            fontFamily: root.fontFamily
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
            bordered: true
            onClicked: root.sortLeftovers()
          }
        }

        PanelSeparator { foreground: root.foregroundColor }

        // ----- category rows
        PanelSectionHeader {
          text: "CATEGORIES"
          foreground: root.foregroundColor
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.categories

            delegate: Item {
              id: categoryRow
              required property var modelData
              required property int index

              readonly property bool hasCursor: root.cursorActive && root.cursorIndex === index
              readonly property bool isDefault: String(modelData.name).toLowerCase() === String(root.defaultCategory).toLowerCase()

              width: parent.width
              height: Style.space(34)

              Row {
                anchors.fill: parent
                spacing: Style.space(4)

                Button {
                  width: parent.width - parent.spacing - starButton.width
                  height: parent.height
                  iconText: Config.sanitizeIcon(categoryRow.modelData.icon)
                  iconSize: Style.font.body
                  text: categoryRow.modelData.name
                  fontSize: Style.font.bodySmall
                  foreground: root.foregroundColor
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX
                  bordered: false
                  active: false
                  hasCursor: categoryRow.hasCursor
                  onClicked: root.openFolder(categoryRow.modelData.name)
                  onHovered: function(h) {
                    if (h) {
                      root.cursorActive = true
                      root.cursorIndex = categoryRow.index
                    }
                  }
                }

                Button {
                  id: starButton
                  width: Style.space(40)
                  height: parent.height
                  iconText: categoryRow.isDefault ? "\uf005" : "\uf006"
                  iconSize: Style.font.bodySmall
                  text: ""
                  foreground: root.foregroundColor
                  fontFamily: root.fontFamily
                  horizontalPadding: 0
                  verticalPadding: 0
                  bordered: false
                  active: categoryRow.isDefault
                  tooltipText: "Set as default"
                  onClicked: root.setDefault(categoryRow.modelData.name)
                }
              }
            }
          }
        }

        PanelSeparator { foreground: root.foregroundColor }

        // ----- stats section
        PanelSectionHeader {
          text: "STATS"
          foreground: root.foregroundColor
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width * 0.5
              text: "Total sorts:"
              color: root.foregroundColor
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width * 0.5
              text: String(root.totalSorts)
              color: root.foregroundColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width * 0.5
              text: "Top category:"
              color: root.foregroundColor
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width * 0.5
              text: root.topCategoryName
              color: root.foregroundColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }
          }
        }

        PanelSeparator { foreground: root.foregroundColor }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "click opens · star sets default · → also sets default"
          color: root.foregroundColor
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}

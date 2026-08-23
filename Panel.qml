import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Gmail: unread count in the bar, with a panel listing the inbox.
//
// Each row is one message: a dot while it is unread, the subject, how long
// ago it arrived, and the sender plus the first words of the body underneath.
// Clicking one opens it in the browser and marks it read; the check button in
// the header clears the whole inbox at once.
//
// Data comes from `bin/gmail-inbox`, which talks to the Google Workspace CLI
// (`gws`). No token or address is handled here — the script hands over a
// finished list and this file only draws it.
//
// Every string below the header comes from a mail someone else wrote, so each
// Text carries `textFormat: Text.PlainText`. Left on the default AutoText, Qt
// decides for itself that a subject looks like markup and renders it as rich
// text, and rich text really does load `<img src="http://...">` — a request
// out of the shell process to a server the sender picked.
//
// Glyphs are \u escapes rather than literal characters, so the source
// survives editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.gmail-inbox"
  ipcTarget: "jankeesvw.gmail-inbox"

  // The script sits next to this file, so the plugin runs from wherever it
  // was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/gmail-inbox").toString().replace(/^file:\/\//, "")

  readonly property string iconEnvelope: "\uF0E0"
  readonly property string iconDot: "\uF111"
  readonly property string iconCheck: "\uF00C"
  readonly property string iconExternal: "\uF08E"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  // A full inbox is normal, not an alarm, so the badge takes the theme accent
  // rather than the bar's urgent red.
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var messages: []
  property int unread: 0
  property string email: ""
  property bool reachable: true
  property string errorText: ""
  // Message the script is currently writing to, so its row can dim.
  property string pendingId: ""
  property bool markingAll: false
  property int cursor: -1

  // Ages are drawn from this rather than from a fresh clock per row, so the
  // whole list ticks over together and only once a minute.
  property double now: 0

  readonly property int badgeCount: unread
  readonly property bool hasUnread: unread > 0

  // Width of the badge and of the whole icon+badge row. Computed here rather
  // than read off the Row, because iconComponent is a Component with its own
  // scope: ids inside it are not visible out here.
  readonly property int badgeWidth: badgeCount > 0
    ? Math.max(Style.space(12), String(badgeCount).length * Style.space(6) + Style.space(8))
    : 0
  readonly property int barContentWidth: Style.bar.iconFont + badgeWidth + Style.space(5)

  // Panel is a bare Item with no size of its own, so the bar would give this
  // widget zero width. Set it from the computed content width, never from a
  // child that fills this item: that is a loop where nothing decides the size
  // and everything collapses to zero.
  readonly property int barSlot: barContentWidth + Style.space(10)

  readonly property real openPanelIndicatorWidth: barContentWidth
  readonly property real openPanelIndicatorHeight: barContentWidth
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  // Message ids come from the API, so they are input, and this one ends up in
  // a URL a browser opens. A value shaped like anything else means the other
  // side is not what we think it is — refuse it instead of tidying it up.
  function validId(id) {
    return /^[0-9a-f]{1,32}$/.test(String(id))
  }

  // Which account the browser opens. `/mail/u/<address>/` is not a path Gmail
  // has — it 404s, encoded or not; only `/mail/u/<index>/` exists. The address
  // goes in `authuser`, which is a query and therefore belongs before the
  // fragment. Anything not shaped like an address is left off entirely, so the
  // link falls back to whichever account the browser is already signed in to.
  function accountQuery() {
    if (/^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(root.email))
      return "?authuser=" + encodeURIComponent(root.email)
    return ""
  }

  // Gmail addresses a conversation by its thread, which is what its own URLs
  // carry. For a single-message thread the two ids are the same; for a reply
  // chain only the thread id resolves.
  function messageUrl(threadId) {
    return "https://mail.google.com/mail/u/0/" + accountQuery() + "#inbox/" + threadId
  }

  function inboxUrl() {
    return "https://mail.google.com/mail/u/0/" + accountQuery() + "#inbox"
  }

  // The list is a plain JS array, so a row is updated by handing over a new
  // one. Done locally as well as on the server: the badge should drop the
  // moment you click, not a refresh later.
  function markLocalRead(id) {
    var next = []
    var changed = false
    for (var i = 0; i < messages.length; i++) {
      var m = messages[i]
      if (m.id === id && m.unread) {
        changed = true
        next.push({
          id: m.id, threadId: m.threadId, subject: m.subject, from: m.from,
          snippet: m.snippet, ts: m.ts, unread: false
        })
      } else {
        next.push(m)
      }
    }
    if (!changed) return
    messages = next
    if (unread > 0) unread -= 1
  }

  function openMessage(message) {
    if (!message || !validId(message.id)) return
    var thread = validId(message.threadId) ? message.threadId : message.id
    // An array, never one string for a shell to split: the ids are external.
    Quickshell.execDetached(["xdg-open", root.messageUrl(thread)])
    markRead(message.id)
    close()
  }

  function openInbox() {
    Quickshell.execDetached(["xdg-open", root.inboxUrl()])
    close()
  }

  function markRead(id) {
    if (!validId(id) || readProc.running) return
    root.markLocalRead(id)
    pendingId = id
    readProc.command = [root.script, "read", id]
    readProc.running = true
  }

  function markAllRead() {
    if (readAllProc.running) return
    markingAll = true
    readAllProc.command = [root.script, "read-all"]
    readAllProc.running = true
  }

  function moveCursor(delta) {
    if (messages.length === 0) return
    var next = cursor + delta
    if (next < 0) next = 0
    if (next > messages.length - 1) next = messages.length - 1
    cursor = next
    list.positionViewAtIndex(next, ListView.Contain)
  }

  function activateCursor() {
    if (cursor < 0 || cursor >= messages.length) return
    openMessage(messages[cursor])
  }

  // "2m", "4h", "3d" — a mail's age is a glance, not a timestamp. Anything
  // past a month is dated instead, because "6w" stops meaning much.
  function ageLabel(ts) {
    if (!ts || ts <= 0) return ""
    var seconds = Math.max(0, root.now - ts)
    if (seconds < 60) return "now"
    if (seconds < 3600) return Math.floor(seconds / 60) + "m"
    if (seconds < 86400) return Math.floor(seconds / 3600) + "h"
    if (seconds < 604800) return Math.floor(seconds / 86400) + "d"
    if (seconds < 2592000) return Math.floor(seconds / 604800) + "w"
    return Qt.formatDate(new Date(ts * 1000), "d MMM")
  }

  function applyPayload(text) {
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true
      errorText = data.error || ""
      if (!reachable) return
      messages = data.messages || []
      unread = data.unread || 0
      email = data.email || ""
      if (cursor > messages.length - 1) cursor = messages.length - 1
    } catch (e) {
      reachable = false
      errorText = "unexpected output from gmail-widget"
    }
  }

  onOpenedChanged: {
    if (opened) {
      now = Date.now() / 1000
      refresh()
    } else {
      cursor = -1
    }
  }

  Component.onCompleted: now = Date.now() / 1000

  Process {
    id: listProc
    command: [root.script, "list"]
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(text)
    }
  }

  Process {
    id: readProc
    onExited: function(exitCode) {
      root.pendingId = ""
      root.refresh()
    }
  }

  Process {
    id: readAllProc
    onExited: function(exitCode) {
      root.markingAll = false
      root.refresh()
    }
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.now = Date.now() / 1000
      root.refresh()
    }
  }

  // iconComponent rather than a text label, so the count can sit in a badge.
  // Same hook the stock Basecamp plugin uses for its logo.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    opacity: root.reachable ? 1 : 0.5
    slotSize: root.barSlot
    // The icon component is loaded into a square canvas of opticalSize, meant
    // for one glyph. Widen it too, or the icon falls outside it and only the
    // badge survives.
    opticalSize: root.barContentWidth
    // No hover tooltip: the panel is the detail view.
    tooltipText: ""

    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(5)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.iconEnvelope
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
            color: root.opened ? root.accent : root.foreground
          }

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.reachable && root.badgeCount > 0
            height: Style.space(12)
            width: root.badgeWidth
            radius: height / 2
            color: root.accent

            Text {
              anchors.centerIn: parent
              text: root.badgeCount
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              renderType: Text.NativeRendering
              color: Color.background
            }
          }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.openInbox()
      } else if (b === Qt.MiddleButton) {
        root.refresh()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      // Only activateRequested, never returnRequested as well: Enter fires
      // both, and a handler on each runs the action twice.
      onActivateRequested: root.activateCursor()
      onTextKey: function(t) {
        if (t === "r" && root.cursor >= 0 && root.cursor < root.messages.length)
          root.markRead(root.messages[root.cursor].id)
        else if (t === "a")
          root.markAllRead()
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(6)

        // ------------------------------------------------------- header

        Item {
          width: parent.width
          height: Math.max(heading.implicitHeight, allReadButton.height)

          Column {
            id: heading
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(1)

            PanelSectionHeader {
              width: parent.width
              text: root.unread > 0 ? "INBOX  " + root.unread : "INBOX"
              textFormat: Text.PlainText
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              visible: root.email !== ""
              text: root.email
              textFormat: Text.PlainText
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.foreground, 1.6)
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PanelActionButton {
              id: allReadButton
              iconText: root.iconCheck
              tooltipText: "Mark all as read"
              enabled: root.unread > 0 && !root.markingAll
              opacity: enabled ? 1 : 0.35
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.iconSmall
              onClicked: root.markAllRead()
            }

            PanelActionButton {
              iconText: root.iconExternal
              tooltipText: "Open Gmail"
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.iconSmall
              onClicked: root.openInbox()
            }
          }
        }

        PanelSeparator { width: parent.width }

        // --------------------------------------------------------- list

        ListView {
          id: list
          width: parent.width
          visible: root.messages.length > 0
          clip: true
          model: root.messages
          spacing: Style.space(1)
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          // Grows with what it holds and stops at whatever the card has left
          // once the header and the footer have had their share.
          readonly property int cap: {
            var chrome = Style.space(70)
            return Math.max(Style.space(200),
                            panel.availableCardHeight - panel.verticalContentInset - chrome)
          }
          height: Math.min(contentHeight, cap)

          delegate: Rectangle {
            id: row
            required property var modelData
            required property int index

            readonly property bool active: root.cursor === row.index || rowMouse.containsMouse

            width: list.width - (list.interactive ? Style.space(10) : 0)
            height: rowContent.implicitHeight + Style.space(10)
            radius: Style.cornerRadius
            opacity: root.pendingId === modelData.id ? 0.4 : 1
            color: active
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
              : "transparent"

            Behavior on color { ColorAnimation { duration: 80 } }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onContainsMouseChanged: if (containsMouse) root.cursor = row.index
              onClicked: root.openMessage(row.modelData)
            }

            Row {
              id: rowContent
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(7)

              // The dot is the read state and the button that clears it, so
              // one message can be dismissed without opening it. It keeps its
              // width when read, otherwise every row shifts as the list is
              // worked through.
              Item {
                width: Style.space(14)
                height: Style.space(14)
                anchors.top: parent.top
                anchors.topMargin: Style.space(2)

                Text {
                  anchors.centerIn: parent
                  visible: row.modelData.unread
                  text: root.iconDot
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(7)
                  color: root.accent
                }

                MouseArea {
                  anchors.fill: parent
                  enabled: row.modelData.unread
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.markRead(row.modelData.id)
                }
              }

              Column {
                width: parent.width - Style.space(21)
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: subject.implicitHeight

                  Text {
                    id: subject
                    anchors.left: parent.left
                    anchors.right: age.left
                    anchors.rightMargin: Style.space(8)
                    text: row.modelData.subject
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    // Weight carries the read state along with the dot, so
                    // the list can be read without hunting for the marker.
                    font.bold: row.modelData.unread
                    color: row.modelData.unread ? root.foreground : Qt.darker(root.foreground, 1.3)
                  }

                  Text {
                    id: age
                    anchors.right: parent.right
                    anchors.baseline: subject.baseline
                    text: root.ageLabel(row.modelData.ts)
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(root.foreground, 1.7)
                  }
                }

                // Who it is from carries as much as the subject does, so it
                // gets its own weight and colour instead of disappearing into
                // the preview text beside it. It takes at most half the row:
                // past that a long sender name would leave nothing of the
                // message itself.
                Row {
                  width: parent.width
                  spacing: 0

                  Text {
                    id: fromLabel
                    text: row.modelData.from || ""
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, parent.width * 0.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    color: Qt.darker(root.foreground, 1.15)
                  }

                  Text {
                    text: {
                      var body = row.modelData.snippet || ""
                      if (body === "") return ""
                      return (fromLabel.text !== "" ? "  —  " : "") + body
                    }
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    width: parent.width - fromLabel.width
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(root.foreground, 1.7)
                  }
                }
              }
            }
          }
        }

        // -------------------------------------------------- empty states

        Item {
          width: parent.width
          height: root.messages.length === 0 ? Style.space(60) : 0
          visible: root.messages.length === 0

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(20)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.reachable
              ? "Inbox zero."
              : (root.errorText !== "" ? root.errorText : "Gmail unreachable")
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            color: root.foreground
            opacity: 0.6
          }
        }
      }
    }
  }
}

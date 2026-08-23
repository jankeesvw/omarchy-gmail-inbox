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
  readonly property string iconDotOpen: "\uF10C"
  readonly property string iconCheck: "\uF00C"
  readonly property string iconExternal: "\uF08E"
  readonly property string iconStar: "\uF005"
  readonly property string iconStarEmpty: "\uF006"
  readonly property string iconClip: "\uF0C6"
  readonly property string iconPrev: "\uF053"
  readonly property string iconNext: "\uF054"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  // A full inbox is normal, not an alarm, so the badge takes the theme accent
  // rather than the bar's urgent red.
  readonly property color accent: Color.accent
  // The one colour here that does not come from the theme. A star is amber in
  // every mail client there is, and a star in the theme's accent would be
  // indistinguishable from the unread dot right beside it.
  readonly property color starColor: "#E5A44B"
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var messages: []
  property int unread: 0
  property int total: 0
  property string email: ""
  property bool reachable: true
  property string errorText: ""
  // Message the script is currently writing to, so its row can dim.
  property string pendingId: ""
  property bool markingAll: false
  property int cursor: -1

  // Paging. Gmail's tokens only point forward, so going back means keeping
  // the ones already used: the stack is the history, `pageToken` is where we
  // are, and `nextPage` is what the last response offered.
  property string pageToken: ""
  property var pageStack: []
  property string nextPage: ""
  property bool unreadOnly: false
  readonly property bool hasPrev: pageStack.length > 0
  readonly property bool hasNext: nextPage !== ""

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
    if (listProc.running) return
    var argv = [root.script, "list"]
    if (unreadOnly) argv.push("--unread")
    if (pageToken !== "") argv.push("--page", pageToken)
    listProc.command = argv
    listProc.running = true
  }

  function goNextPage() {
    if (!hasNext || listProc.running) return
    var stack = pageStack.slice()
    stack.push(pageToken)
    pageStack = stack
    pageToken = nextPage
    cursor = -1
    refresh()
  }

  function goPrevPage() {
    if (!hasPrev || listProc.running) return
    var stack = pageStack.slice()
    pageToken = stack.pop()
    pageStack = stack
    cursor = -1
    refresh()
  }

  function firstPage() {
    pageToken = ""
    pageStack = []
    cursor = -1
  }

  // Switching the filter changes what the pages are, so the old tokens point
  // into a list that no longer exists. Start over rather than carry them.
  function toggleUnreadOnly() {
    if (listProc.running) return
    unreadOnly = !unreadOnly
    firstPage()
    refresh()
  }

  // Message ids come from the API, so they are input, and this one ends up in
  // a URL a browser opens. A value shaped like anything else means the other
  // side is not what we think it is — refuse it instead of tidying it up.
  function validId(id) {
    return /^[0-9a-f]{1,32}$/.test(String(id))
  }

  // "Inbox (10 emails, 6 unread)", with the address on the line underneath.
  // Both counts describe the whole label rather than the slice on screen,
  // which is the same thing the badge counts — the panel lists at most
  // OMARCHY_GMAIL_MAX of them.
  function titleText() {
    return "Inbox (" + root.total + (root.total === 1 ? " email" : " emails")
         + ", " + root.unread + " unread)"
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
  // one. Applied locally as well as on the server: the badge and the star
  // should follow the click, not the refresh a moment later.
  function patchMessage(id, changes) {
    var next = []
    var changed = false
    for (var i = 0; i < messages.length; i++) {
      var m = messages[i]
      if (m.id !== id) {
        next.push(m)
        continue
      }
      var copy = {}
      for (var key in m) copy[key] = m[key]
      for (var field in changes) copy[field] = changes[field]
      next.push(copy)
      changed = true
    }
    if (changed) messages = next
    return changed
  }

  function setLocalRead(id, wanted) {
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].id !== id) continue
      if (messages[i].unread === !wanted) return
      patchMessage(id, { unread: !wanted })
      if (wanted) { if (unread > 0) unread -= 1 }
      else unread += 1
      return
    }
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

  function setRead(id, wanted) {
    if (!validId(id) || readProc.running) return
    root.setLocalRead(id, wanted)
    pendingId = id
    readProc.command = [root.script, wanted ? "read" : "unread", id]
    readProc.running = true
  }

  // Opening a message always means read; only the dot toggles both ways.
  function markRead(id) { setRead(id, true) }

  function toggleRead(message) {
    if (!message) return
    setRead(message.id, message.unread === true)
  }

  function markAllRead() {
    if (readAllProc.running) return
    markingAll = true
    readAllProc.command = [root.script, "read-all"]
    readAllProc.running = true
  }

  function toggleStar(message) {
    if (!message || !validId(message.id) || starProc.running) return
    var wanted = !message.starred
    patchMessage(message.id, { starred: wanted })
    starProc.command = [root.script, wanted ? "star" : "unstar", message.id]
    starProc.running = true
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
      total = data.total || 0
      email = data.email || ""
      nextPage = data.nextPage || ""
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
      // A panel reopened on page 7 of a mailbox is disorienting; the top of
      // the list is where anyone expects to land.
      firstPage()
    }
  }

  Component.onCompleted: now = Date.now() / 1000

  Process {
    id: listProc
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

  // No refresh on exit: the star is already drawn, and a reload here would
  // pull the whole list out from under a run of quick stars.
  Process {
    id: starProc
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
    // No fixed ceiling: a page of 25 rows is taller than any number picked
    // here would be, and a card that stops at 620 while the list inside it
    // keeps going draws rows onto the desktop below. fittedContentHeight
    // already clamps to what the screen has left, which is the real limit.
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      // Only activateRequested, never returnRequested as well: Enter fires
      // both, and a handler on each runs the action twice.
      onActivateRequested: root.activateCursor()
      onTextKey: function(t) {
        var onCursor = root.cursor >= 0 && root.cursor < root.messages.length
        if (t === "r" && onCursor)
          root.toggleRead(root.messages[root.cursor])
        else if (t === "s" && onCursor)
          root.toggleStar(root.messages[root.cursor])
        else if (t === "a")
          root.markAllRead()
        else if (t === "u")
          root.toggleUnreadOnly()
        else if (t === "n")
          root.goNextPage()
        else if (t === "p")
          root.goPrevPage()
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
              text: root.titleText()
              textFormat: Text.PlainText
              elide: Text.ElideRight
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

            // Filter first: it changes what the other two act on.
            PanelActionButton {
              // Same language as the rows: filled means unread, an outline
              // means everything is on show.
              iconText: root.unreadOnly ? root.iconDot : root.iconDotOpen
              tooltipText: root.unreadOnly ? "Showing unread only" : "Show unread only"
              foreground: root.unreadOnly ? root.accent : root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.iconSmall
              onClicked: root.toggleUnreadOnly()
            }

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

        // A failed refresh keeps the list it already had, because a stale inbox
        // beats an empty one. But then the only sign that anything is wrong is
        // a slightly dimmer icon in the bar, and a list that quietly stops
        // moving reads as a quiet mailbox — so say it here as well. Expired
        // credentials are the case this exists for.
        Item {
          width: parent.width
          height: root.reachable ? 0 : staleWarning.implicitHeight + Style.space(6)
          visible: !root.reachable

          Text {
            id: staleWarning
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: root.errorText !== ""
              ? root.errorText
              : "Could not reach Gmail. Showing the last list."
            textFormat: Text.PlainText
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: bar ? bar.urgent : Color.urgent
          }
        }

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
          // Everything that is not the list needs its share of the card first.
          // Leave the pager out of this and a full page of mail pushes it off
          // the bottom, which is exactly where the buttons are not.
          readonly property int cap: {
            var chrome = Style.space(70)
            if (root.hasPrev || root.hasNext) chrome += Style.space(38)
            if (!root.reachable) chrome += Style.space(24)
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
                  text: row.modelData.unread ? root.iconDot : root.iconDotOpen
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  // The outline needs the extra pixels: at the size the filled
                  // dot works, its stroke lands under one pixel and vanishes.
                  font.pixelSize: row.modelData.unread ? Style.space(7) : Style.space(10)
                  // Filled and in the accent while unread, an outline once it
                  // has been read — faint enough to stay a marker rather than
                  // become a second row of bullets down the list.
                  color: row.modelData.unread
                    ? root.accent
                    : Qt.darker(root.foreground, row.active ? 1.4 : 1.8)
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleRead(row.modelData)
                }
              }

              Column {
                width: parent.width - Style.space(21)
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: subject.implicitHeight

                  // Labels first, the way Gmail itself puts them: they say
                  // which pile a message belongs to, which is the thing you
                  // want before you have read the subject. Two at most, and
                  // never the system ones — the script has already dropped
                  // INBOX, the CATEGORY_ tabs and the star colour.
                  Row {
                    id: line
                    anchors.left: parent.left
                    anchors.right: clip.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(5)

                    Row {
                      id: chips
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(3)
                      visible: (row.modelData.labels || []).length > 0

                      Repeater {
                        model: (row.modelData.labels || []).slice(0, 2)

                        Rectangle {
                          required property string modelData
                          anchors.verticalCenter: parent.verticalCenter
                          height: chipText.implicitHeight + Style.space(3)
                          width: chipText.implicitWidth + Style.space(8)
                          radius: Style.space(3)
                          color: Qt.rgba(root.foreground.r, root.foreground.g,
                                         root.foreground.b, 0.14)

                          Text {
                            id: chipText
                            anchors.centerIn: parent
                            text: parent.modelData
                            textFormat: Text.PlainText
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            color: Qt.darker(root.foreground, 1.35)
                          }
                        }
                      }
                    }

                    Text {
                      id: subject
                      anchors.verticalCenter: parent.verticalCenter
                      width: line.width - (chips.visible ? chips.width + line.spacing : 0)
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
                  }

                  // A paperclip earns no reserved slot: unlike the star it is
                  // never a control, so nothing shifts under the pointer when
                  // it is absent, and the subject gets the room back.
                  Text {
                    id: clip
                    visible: row.modelData.attachment === true
                    width: visible ? implicitWidth : 0
                    anchors.right: starSlot.left
                    anchors.rightMargin: visible ? Style.space(5) : 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.iconClip
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: Qt.darker(root.foreground, 1.75)
                  }

                  // The star keeps its slot whether it is set or not, so the
                  // ages stay in one column down the list. Empty and faint on
                  // the row under the cursor, invisible everywhere else: it is
                  // a control where you are looking and nothing where you are
                  // not.
                  Item {
                    id: starSlot
                    anchors.right: age.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(14)
                    height: Style.space(14)

                    Text {
                      anchors.centerIn: parent
                      visible: row.modelData.starred || row.active
                      text: row.modelData.starred ? root.iconStar : root.iconStarEmpty
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: row.modelData.starred
                        ? root.starColor
                        : Qt.darker(root.foreground, 1.9)
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleStar(row.modelData)
                    }
                  }

                  Text {
                    id: age
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
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

        // ------------------------------------------------------- paging

        // Only there when there is somewhere to go. Gmail hands out one token
        // at a time and only forwards, so "how many pages" is a question the
        // API cannot answer — hence a position rather than a count.
        Item {
          width: parent.width
          height: (root.hasPrev || root.hasNext) ? pagerRow.implicitHeight + Style.space(8) : 0
          visible: root.hasPrev || root.hasNext

          Row {
            id: pagerRow
            anchors.centerIn: parent
            spacing: Style.space(10)

            PanelActionButton {
              iconText: root.iconPrev
              tooltipText: "Previous page"
              enabled: root.hasPrev
              opacity: enabled ? 1 : 0.3
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.iconSmall
              onClicked: root.goPrevPage()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "page " + (root.pageStack.length + 1)
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.foreground, 1.7)
            }

            PanelActionButton {
              iconText: root.iconNext
              tooltipText: "Next page"
              enabled: root.hasNext
              opacity: enabled ? 1 : 0.3
              foreground: root.foreground
              hoverColor: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.iconSmall
              onClicked: root.goNextPage()
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
              ? (root.unreadOnly ? "Nothing unread." : "Inbox zero.")
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

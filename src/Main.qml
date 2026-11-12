import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Dialogs as Dialogs
import QtQuick.Layouts
import QtQuick.Window
import "EditorMutations.js" as EditorMutations

ApplicationWindow {
    id: win
    width: 1280
    height: 820
    minimumWidth: 720
    minimumHeight: 520
    visible: true
    title: backend.fileName + " - Omawrite+"

    readonly property bool darkMode: backend.darkMode
    readonly property color pageColor: backend.themeBackground
    readonly property color textColor: backend.themeForeground
    readonly property color mutedColor: darkMode ? "#909191" : "#aeb1b5"
    readonly property color selectionFill: backend.themeSelection
    readonly property color selectionTextColor: backend.themeSelectionForeground
    // The desktop's text size knob (GNOME's text-scaling-factor, which
    // `omarchy display text size` drives) anchored so its 12px default leaves
    // the app at the sizes it was designed around, times the user's own
    // text size set with Ctrl+= / Ctrl+- / Ctrl+wheel.
    readonly property real textScale: backend.textScale
    readonly property int editorFontPixelSize: scaledSize(20)
    readonly property int footerHeight: scaledSize(32)
    // Never wider than the Flickable's viewport, whatever the floor asks for:
    // a tiling compositor can resize the window below its minimum width.
    readonly property int editorWidth: Math.min(
        Math.round(writerFontMetrics.averageCharacterWidth * 65),
        Math.max(360, editorArea.width - Math.round(writerFontMetrics.averageCharacterWidth * 20)),
        Math.max(0, editorArea.width - 48))
    property bool sidebarOpen: true
    readonly property int sidebarWidth: scaledSize(270)
    // The ids the sidebar shows: every note, or the ones matching the search.
    property var visibleNoteIds: []
    property bool closeConfirmed: false
    property bool searchOpen: false
    property bool searchUpdating: false
    property var searchMatches: []
    property int searchMatchIndex: -1
    property url pendingOpenUrl
    property string pendingAction: ""
    property bool replaceOpen: false
    property bool awaitingPendingSave: false

    Material.theme: darkMode ? Material.Dark : Material.Light
    Material.accent: backend.themeAccent
    color: pageColor

    onClosing: function(close) {
        if (closeConfirmed || !backend.modified)
            return;

        // Notes save themselves, so closing just writes the last few words.
        // Only a save that fails stops the window to ask.
        backend.save();
        if (!backend.modified)
            return;

        close.accepted = false;
        pendingAction = "close";
        if (!unsavedChangesDialog.opened)
            unsavedChangesDialog.open();
    }

    function requestOpen(url) {
        if (!backend.modified) {
            backend.open(url);
            return;
        }
        pendingOpenUrl = url;
        pendingAction = "open";
        unsavedChangesDialog.open();
    }

    function completePendingAction() {
        var action = pendingAction;
        pendingAction = "";
        if (action === "close") {
            closeConfirmed = true;
            close();
        } else if (action === "open") {
            backend.open(pendingOpenUrl);
        }
    }

    function refreshNoteFilter() {
        visibleNoteIds = notes.search(noteSearchField.text);
    }

    function newNote() {
        notes.createNote();
        titleInput.forceActiveFocus();
    }

    // Steps through the notes as the sidebar lists them.
    function stepNote(direction) {
        var ids = visibleNoteIds;
        if (ids.length === 0)
            return;
        var index = ids.indexOf(notes.currentId);
        var next = index < 0 ? 0 : Math.max(0, Math.min(ids.length - 1, index + direction));
        notes.openNote(ids[next]);
    }

    function askToDeleteNote(id) {
        deleteNoteDialog.noteId = id;
        deleteNoteDialog.noteTitle = notes.displayTitle(id);
        deleteNoteDialog.open();
    }

    function focusNoteSearch() {
        sidebarOpen = true;
        noteSearchField.forceActiveFocus();
        noteSearchField.selectAll();
    }

    Connections {
        target: notes

        function onCurrentChanged() {
            if (titleInput.text !== notes.currentTitle)
                titleInput.text = notes.currentTitle;
            editorFlick.scrollTo(0);
            noteList.positionViewAtIndex(Math.max(0, win.visibleNoteIds.indexOf(notes.currentId)),
                                         ListView.Contain);
        }

        function onNotesChanged() {
            win.refreshNoteFilter();
        }
    }

    FontMetrics {
        id: writerFontMetrics
        font.family: backend.editorFont
        font.pixelSize: win.editorFontPixelSize
    }

    // Every hardcoded size in the interface is expressed at text scale 1.
    function scaledSize(pixels) {
        return Math.max(1, Math.round(pixels * win.textScale));
    }

    function toggleFullScreen() {
        win.visibility = win.visibility === Window.FullScreen
            ? Window.Windowed
            : Window.FullScreen;
    }

    // Only the search field and the next and previous controls select a
    // match. When the document changes underneath, the matches follow along
    // without taking the writer's caret.
    function updateSearch(selectMatch) {
        searchDelay.stop();
        var previous = searchMatchIndex >= 0 ? searchMatches[searchMatchIndex] : 0;
        searchMatches = backend.searchMatches(searchField.text);
        searchMatchIndex = selectMatch ? (searchMatches.length > 0 ? 0 : -1)
                                       : matchAtOrAfter(previous);
        showSearchMatch(selectMatch);
    }

    function matchAtOrAfter(position) {
        for (var i = 0; i < searchMatches.length; ++i) {
            if (searchMatches[i] >= position)
                return i;
        }
        return searchMatches.length > 0 ? 0 : -1;
    }

    function showSearchMatch(selectMatch) {
        var start = searchMatchIndex >= 0 ? searchMatches[searchMatchIndex] : -1;
        searchUpdating = true;
        backend.setSearchHighlight(searchField.text, start);
        if (selectMatch && start >= 0) {
            editor.select(start, start + searchField.text.length);
            editorFlick.ensureCursorVisible();
        }
        searchUpdating = false;
    }

    // Typing in the search field waits for a pause before searching, so
    // anything that acts on the matches catches up with the field first.
    function flushSearch() {
        if (searchDelay.running)
            updateSearch(true);
    }

    function moveSearch(direction) {
        // A pending search lands on its first match, which is where the
        // writer meant to go, rather than one past it.
        if (searchDelay.running) {
            updateSearch(true);
            return;
        }
        if (searchMatches.length === 0)
            return;
        searchMatchIndex = (searchMatchIndex + direction + searchMatches.length)
                           % searchMatches.length;
        showSearchMatch(true);
    }

    // The matches stop following the field and the text while the bar is
    // closed, and a search still waiting for a pause is dropped on closing,
    // so opening the bar searches again for what the field holds.
    function openSearch(withReplace) {
        searchOpen = true;
        if (withReplace)
            replaceOpen = true;
        searchField.forceActiveFocus();
        searchField.selectAll();
        // A search still waiting in an open bar lands on its first match.
        updateSearch(searchDelay.running);
    }

    function closeSearch() {
        searchDelay.stop();
        // Hand focus to the editor before hiding the bar. Hiding the field
        // that holds focus leaves the input method with nothing focused for
        // a moment, and fcitx5 can then miss the next Ctrl+F.
        Qt.inputMethod.reset();
        editor.forceActiveFocus();
        searchOpen = false;
        searchUpdating = true;
        backend.setSearchHighlight("", -1);
        editor.deselect();
        searchUpdating = false;
        replaceOpen = false;
    }

    // Restyling a large document for each letter typed makes typing a word
    // stall, so the search waits until the typing pauses.
    Timer {
        id: searchDelay
        interval: 150
        onTriggered: win.updateSearch(true)
    }

    Shortcut {
        sequence: "Ctrl+S"
        onActivated: backend.save()
    }

    Shortcut {
        sequence: "Ctrl+H"
        onActivated: win.openSearch(true)
    }

    Shortcut {
        sequence: "Ctrl+B"
        context: Qt.WindowShortcut
        onActivated: editor.wrapSelection("**")
    }

    Shortcut {
        sequence: "Ctrl+I"
        context: Qt.WindowShortcut
        onActivated: editor.wrapSelection("*")
    }

    Shortcut {
        sequence: "Ctrl+Shift+X"
        context: Qt.WindowShortcut
        onActivated: editor.wrapSelection("~~")
    }

    Shortcut {
        sequence: "Ctrl+U"
        context: Qt.WindowShortcut
        onActivated: editor.toggleUnderline()
    }

    Shortcut {
        sequences: ["Ctrl+Shift+8", "Ctrl+*", "Ctrl+Shift+*"]
        context: Qt.WindowShortcut
        onActivated: editor.toggleList("bullet")
    }

    Shortcut {
        sequences: ["Ctrl+Shift+7", "Ctrl+&", "Ctrl+Shift+&"]
        context: Qt.WindowShortcut
        onActivated: editor.toggleList("number")
    }

    Shortcut {
        sequence: "Ctrl+Shift+L"
        context: Qt.WindowShortcut
        onActivated: editor.toggleList("check")
    }

    Shortcut {
        sequence: "Ctrl+Shift+T"
        context: Qt.WindowShortcut
        onActivated: editor.setHeading(1)
    }

    Shortcut {
        sequence: "Ctrl+Shift+H"
        context: Qt.WindowShortcut
        onActivated: editor.setHeading(2)
    }

    Shortcut {
        sequence: "Ctrl+Shift+J"
        context: Qt.WindowShortcut
        onActivated: editor.setHeading(3)
    }

    Shortcut {
        sequence: "Ctrl+Shift+B"
        context: Qt.WindowShortcut
        onActivated: editor.setHeading(0)
    }

    Shortcut {
        sequences: ["Ctrl+Return", "Ctrl+Enter"]
        context: Qt.WindowShortcut
        enabled: editor.activeFocus
        onActivated: editor.toggleCheck()
    }

    Shortcut {
        sequence: "Ctrl+K"
        context: Qt.WindowShortcut
        onActivated: editor.insertLink()
    }

    Shortcut {
        sequences: ["Ctrl+?", "Ctrl+/", "F1"]
        onActivated: shortcutsDialog.open()
    }

    Shortcut {
        // Ctrl++ is a different shortcut to Qt, not a shifted Ctrl+=, and it is
        // the only one a layout that puts + on its own key can reach.
        sequences: ["Ctrl+=", "Ctrl++"]
        onActivated: backend.increaseTextSize()
    }

    Shortcut {
        sequence: "Ctrl+-"
        onActivated: backend.decreaseTextSize()
    }

    Shortcut {
        sequence: "Ctrl+0"
        onActivated: backend.resetTextSize()
    }

    Shortcut {
        sequence: "Ctrl+N"
        onActivated: win.newNote()
    }

    Shortcut {
        sequences: ["Alt+Down", "Ctrl+PgDown"]
        onActivated: win.stepNote(1)
    }

    Shortcut {
        sequences: ["Alt+Up", "Ctrl+PgUp"]
        onActivated: win.stepNote(-1)
    }

    Shortcut {
        sequence: "Ctrl+Shift+F"
        onActivated: win.focusNoteSearch()
    }

    Shortcut {
        sequence: "Ctrl+\\"
        onActivated: win.sidebarOpen = !win.sidebarOpen
    }

    Shortcut {
        sequence: "Ctrl+L"
        onActivated: titleInput.forceActiveFocus()
    }

    Shortcut {
        sequence: "Ctrl+Shift+Backspace"
        onActivated: win.askToDeleteNote(notes.currentId)
    }

    Shortcut {
        sequence: "Ctrl+P"
        onActivated: backend.printDocument()
    }

    Shortcut {
        sequence: "Ctrl+Shift+C"
        onActivated: backend.copyAsHtml()
    }

    Shortcut {
        sequences: ["Meta+F", "F11"]
        onActivated: toggleFullScreen()
    }

    Shortcut {
        sequence: "Ctrl+Z"
        context: Qt.WindowShortcut
        onActivated: editor.undoKeepingPlace(false)
    }

    Shortcut {
        sequences: ["Ctrl+Shift+Z", "Ctrl+Y"]
        context: Qt.WindowShortcut
        onActivated: editor.undoKeepingPlace(true)
    }

    Shortcut {
        sequence: "Ctrl+F"
        onActivated: win.openSearch(false)
    }

    Shortcut {
        sequence: "Ctrl+G"
        enabled: win.searchOpen
        onActivated: win.moveSearch(1)
    }

    Connections {
        target: backend

        function onOpenDialogRequested() {
            openFileDialog.open();
        }

        function onSaveDialogRequested(suggestedUrl) {
            saveFileDialog.selectedFile = suggestedUrl;
            saveFileDialog.open();
        }

        function onSaveSucceeded() {
            // Only a save the writer chose in the prompt carries out the
            // pending close or open, never an auto-save that lands meanwhile.
            const confirmed = win.awaitingPendingSave;
            win.awaitingPendingSave = false;
            if (confirmed && win.pendingAction !== "")
                win.completePendingAction();
        }

        function onSaveFailed() {
            // A failed save leaves the document as it was, so the close or
            // open it was for is off; a later save must not carry it out.
            win.awaitingPendingSave = false;
            win.pendingAction = "";
        }

        function onExternalChangeDetected(deleted, locallyModified) {
            externalChangeDialog.deleted = deleted;
            externalChangeDialog.locallyModified = locallyModified;
            externalChangeDialog.open();
        }
    }

    Dialogs.FileDialog {
        id: openFileDialog
        title: "Open File"
        fileMode: Dialogs.FileDialog.OpenFile
        nameFilters: ["Markdown files (*.md *.markdown)", "All files (*)"]
        onAccepted: win.requestOpen(selectedFile)
    }

    Dialogs.FileDialog {
        id: saveFileDialog
        title: "Save File"
        fileMode: Dialogs.FileDialog.SaveFile
        nameFilters: ["Markdown files (*.md *.markdown)", "All files (*)"]
        onAccepted: backend.saveAs(selectedFile)
        onRejected: {
            win.awaitingPendingSave = false;
            win.pendingAction = "";
        }
    }

    UnsavedChangesDialog {
        id: unsavedChangesDialog
        objectName: "unsavedChangesDialog"
        fileName: backend.fileName
        darkMode: win.darkMode
        textScale: win.textScale
        textColor: win.textColor
        strongTextColor: win.textColor
        activeButtonColor: backend.themeAccent
        containerWidth: win.width
        containerHeight: win.height

        // Discard must still mean discard, so nothing is auto-saved while
        // the writer decides.
        onAboutToShow: backend.holdAutoSave(true)
        onClosed: backend.holdAutoSave(false)

        onDiscardRequested: {
            backend.discardRecovery();
            win.completePendingAction();
        }

        onSaveRequested: {
            win.awaitingPendingSave = true;
            backend.save();
        }
        onCancelRequested: win.pendingAction = ""
    }

    DeleteNoteDialog {
        id: deleteNoteDialog
        darkMode: win.darkMode
        textScale: win.textScale
        textColor: win.textColor
        strongTextColor: win.textColor
        activeButtonColor: backend.themeAccent
        containerWidth: win.width
        containerHeight: win.height

        onDeleteRequested: function(id) {
            notes.deleteNote(id);
            editor.forceActiveFocus();
        }
        onClosed: if (!titleInput.activeFocus && !noteSearchField.activeFocus) editor.forceActiveFocus()
    }

    ExternalChangeDialog {
        id: externalChangeDialog
        darkMode: win.darkMode
        textScale: win.textScale
        textColor: win.textColor
        strongTextColor: win.textColor
        activeButtonColor: backend.themeAccent
        containerWidth: win.width
        containerHeight: win.height

        onKeepRequested: backend.keepExternalVersion()
        onReloadRequested: backend.reloadFromDisk()
    }

    ShortcutsDialog {
        id: shortcutsDialog
        darkMode: win.darkMode
        textScale: win.textScale
        textColor: win.textColor
        activeButtonColor: backend.themeAccent
        containerWidth: win.width
        containerHeight: win.height
    }

    // The notes list, newest first, like the middle column of Notes on the
    // Mac. Ctrl+\\ hides it for writing with nothing beside the page.
    Rectangle {
        id: sidebar
        objectName: "noteSidebar"
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: win.sidebarOpen ? win.sidebarWidth : 0
        visible: win.sidebarOpen
        clip: true
        color: win.darkMode ? Qt.darker(win.pageColor, 1.18) : Qt.darker(win.pageColor, 1.035)

        readonly property color accent: backend.themeAccent
        readonly property color hairline: Qt.rgba(win.textColor.r, win.textColor.g,
                                                  win.textColor.b, 0.09)

        function formatWhen(when) {
            var now = new Date();
            if (when.toDateString() === now.toDateString())
                return Qt.formatTime(when, Qt.locale().timeFormat(Locale.ShortFormat));
            var yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
            if (when.toDateString() === yesterday.toDateString())
                return qsTr("Yesterday");
            if (when.getFullYear() === now.getFullYear())
                return Qt.formatDate(when, "d MMM");
            return Qt.formatDate(when, Qt.locale().dateFormat(Locale.ShortFormat));
        }

        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: sidebar.hairline
        }

        Item {
            id: sidebarHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: win.scaledSize(14)
            anchors.leftMargin: win.scaledSize(12)
            anchors.rightMargin: win.scaledSize(12)
            height: win.scaledSize(32)

            Rectangle {
                anchors.left: parent.left
                anchors.right: newNoteButton.left
                anchors.rightMargin: win.scaledSize(12)
                anchors.verticalCenter: parent.verticalCenter
                height: win.scaledSize(30)
                color: Qt.rgba(win.textColor.r, win.textColor.g, win.textColor.b, 0.06)
                border.color: noteSearchField.activeFocus ? sidebar.accent : "transparent"
                radius: 0

                TextInput {
                    id: noteSearchField
                    objectName: "noteSearchField"
                    anchors.fill: parent
                    anchors.leftMargin: win.scaledSize(9)
                    anchors.rightMargin: win.scaledSize(9)
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    color: win.textColor
                    selectionColor: win.selectionFill
                    selectedTextColor: win.selectionTextColor
                    selectByMouse: true
                    font.family: "IBM Plex Mono"
                    font.pixelSize: win.scaledSize(12)
                    onTextChanged: win.refreshNoteFilter()

                    function leave() {
                        editor.forceActiveFocus();
                    }

                    Keys.onEscapePressed: {
                        text = "";
                        leave();
                    }
                    function openFirst() {
                        if (win.visibleNoteIds.length > 0)
                            notes.openNote(win.visibleNoteIds[0]);
                        leave();
                    }

                    Keys.onReturnPressed: openFirst()
                    Keys.onEnterPressed: openFirst()
                    Keys.onDownPressed: openFirst()

                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        text: qsTr("Search")
                        visible: noteSearchField.length === 0
                        color: win.mutedColor
                        font: noteSearchField.font
                    }
                }
            }

            FooterIconButton {
                id: newNoteButton
                objectName: "newNoteButton"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconName: "new"
                iconColor: win.mutedColor
                tooltip: qsTr("New Note (Ctrl+N)")
                onClicked: win.newNote()
            }
        }

        ListView {
            id: noteList
            objectName: "noteList"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: sidebarHeader.bottom
            anchors.bottom: parent.bottom
            anchors.topMargin: win.scaledSize(10)
            anchors.leftMargin: win.scaledSize(6)
            anchors.rightMargin: win.scaledSize(7)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: {
                // Rebuilt from the notes list each time it or the search
                // changes, so titles, previews and order stay current.
                var all = notes.notes;
                var shown = win.visibleNoteIds;
                return all.filter(function(note) { return shown.indexOf(note.id) >= 0; });
            }
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Rectangle {
                id: noteRow
                required property var modelData
                readonly property bool current: modelData.id === notes.currentId
                width: ListView.view.width
                height: win.scaledSize(62)
                color: current
                    ? Qt.rgba(sidebar.accent.r, sidebar.accent.g, sidebar.accent.b, 0.22)
                    : rowHover.hovered
                        ? Qt.rgba(win.textColor.r, win.textColor.g, win.textColor.b, 0.05)
                        : "transparent"

                HoverHandler { id: rowHover }

                TapHandler {
                    onTapped: {
                        notes.openNote(noteRow.modelData.id);
                        editor.forceActiveFocus();
                    }
                }

                Column {
                    anchors.left: parent.left
                    anchors.right: deleteButton.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: win.scaledSize(12)
                    anchors.rightMargin: win.scaledSize(8)
                    spacing: win.scaledSize(4)

                    Label {
                        width: parent.width
                        text: noteRow.modelData.title
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: win.textColor
                        font.family: "IBM Plex Mono"
                        font.pixelSize: win.scaledSize(13)
                        font.bold: true
                    }

                    Label {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: sidebar.formatWhen(noteRow.modelData.modified)
                              + "   " + (noteRow.modelData.preview.length > 0
                                         ? noteRow.modelData.preview : qsTr("No additional text"))
                        elide: Text.ElideRight
                        color: win.mutedColor
                        font.family: "IBM Plex Mono"
                        font.pixelSize: win.scaledSize(11)
                    }
                }

                FooterIconButton {
                    id: deleteButton
                    anchors.right: parent.right
                    anchors.rightMargin: win.scaledSize(10)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: rowHover.hovered
                    iconName: "trash"
                    iconColor: win.mutedColor
                    tooltip: qsTr("Delete Note")
                    onClicked: win.askToDeleteNote(noteRow.modelData.id)
                }
            }
        }
    }

    Item {
        id: editorArea
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        Flickable {
            id: editorFlick
            objectName: "editorScroll"
            anchors.fill: parent
            anchors.leftMargin: 24
            anchors.rightMargin: 24
            // Inset the scrolling area by the footer strip at both ends, so
            // scrolled text never runs under the footer buttons, status, or
            // word count, and stops just as far short of the top edge.
            anchors.topMargin: win.footerHeight
            anchors.bottomMargin: win.footerHeight
            clip: true
            contentWidth: width
            contentHeight: Math.max(height, editor.y + editor.implicitHeight + 220)
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {
                policy: ScrollBar.AsNeeded
                // Wheel scrolling moves contentY directly rather than
                // flicking the Flickable, so the bar has to be told about
                // that activity; linger briefly after the last event.
                active: hovered || pressed || wheelScroll.running || scrollLinger.running
            }

            // Also lingers after paging through the document from the
            // keyboard, so the bar shows where the jump landed. Writing past
            // the bottom edge scrolls too, but leaves the bar hidden.
            Timer {
                id: scrollLinger
                objectName: "scrollLinger"
                interval: 600
            }

            // Flickable turns a wheel notch into a flick sized by the small
            // application font, which crawls next to a browser. Reproduce
            // Chromium's wheel physics instead (cc::ScrollOffsetAnimationCurve):
            // each notch moves 3 lines of 40px towards a running target, the
            // animation gets shorter as the outstanding distance grows, and a
            // notch landing mid-animation carries the current velocity into
            // the new curve, so sustained spinning keeps picking up speed.
            readonly property real wheelStep: win.scaledSize(120)

            FrameAnimation {
                id: wheelScroll
                running: false

                property real startY: 0
                property real targetY: 0
                property real duration: 0.2
                // Cubic bezier easing; ease-in-out (0.42, 0, 0.58, 1) for a
                // fresh scroll, with y1 tilted on retarget so the curve's
                // initial slope matches the velocity it inherits.
                property real cx1: 0.42
                property real cy1: 0
                readonly property real cx2: 0.58
                readonly property real cy2: 1

                onTriggered: {
                    var x = elapsedTime / duration;
                    if (x >= 1) {
                        editorFlick.contentY = editorFlick.snapToPixel(targetY);
                        stop();
                        return;
                    }
                    editorFlick.contentY = editorFlick.snapToPixel(
                        startY + (targetY - startY) * curveY(solveCurve(x)));
                }

                function begin(from, to, dur, slope) {
                    startY = from;
                    targetY = to;
                    duration = dur;
                    cx1 = 0.42;
                    cy1 = 0.42 * Math.max(-1000, Math.min(1000, slope));
                    restart();
                }

                function retarget(newTarget) {
                    var s = solveCurve(Math.min(1, elapsedTime / duration));
                    var pos = startY + (targetY - startY) * curveY(s);
                    var delta = newTarget - pos;
                    if (Math.abs(delta) < 0.5) {
                        editorFlick.contentY = newTarget;
                        stop();
                        return;
                    }

                    var velocity = curveDY(s) / Math.max(1e-6, curveDX(s))
                        * (targetY - startY) / duration;
                    var dur = editorFlick.wheelDuration(delta);
                    // When already moving faster than the eased curve would,
                    // bound the duration by the time to target at the current
                    // velocity; the 2.5x covers the ease-out tail.
                    if (velocity !== 0 && delta / velocity > 0)
                        dur = Math.min(dur, delta / velocity * 2.5);
                    begin(pos, newTarget, dur, velocity * dur / delta);
                }

                // Cubic bezier through (0,0), (cx1,cy1), (cx2,cy2), (1,1),
                // evaluated by Newton-solving the curve parameter from x.
                function curveX(s) { return 3 * s * (1 - s) * ((1 - s) * cx1 + s * cx2) + s * s * s; }
                function curveY(s) { return 3 * s * (1 - s) * ((1 - s) * cy1 + s * cy2) + s * s * s; }
                function curveDX(s) { return 3 * (1 - s) * (1 - s) * cx1 + 6 * (1 - s) * s * (cx2 - cx1) + 3 * s * s * (1 - cx2); }
                function curveDY(s) { return 3 * (1 - s) * (1 - s) * cy1 + 6 * (1 - s) * s * (cy2 - cy1) + 3 * s * s * (1 - cy2); }

                function solveCurve(x) {
                    var s = x;
                    for (var i = 0; i < 8; ++i) {
                        var error = curveX(s) - x;
                        if (Math.abs(error) < 0.001)
                            break;
                        var d = curveDX(s);
                        if (Math.abs(d) < 1e-6)
                            break;
                        s = Math.max(0, Math.min(1, s - error / d));
                    }
                    return s;
                }
            }

            WheelHandler {
                // Wayland compositors route every pointer's scroll through
                // one seat device that Qt classifies as a touchpad, so the
                // device type cannot tell a mouse wheel from two-finger
                // scrolling. Distinguish by event shape instead: discrete
                // wheel notches arrive with only angleDelta set, while
                // finger scrolling carries pixel-precise pixelDelta.
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: function(wheel) {
                    if (wheel.modifiers & Qt.ControlModifier) {
                        editorFlick.zoomByWheel(wheel);
                        wheel.accepted = true;
                        return;
                    }

                    scrollLinger.restart();
                    if (wheel.pixelDelta.y !== 0)
                        editorFlick.scrollTo(editorFlick.clampContentY(editorFlick.contentY - wheel.pixelDelta.y));
                    else
                        editorFlick.scrollByWheel(wheel);
                    wheel.accepted = true;
                }
            }

            onMovementStarted: wheelScroll.stop()
            onContentYChanged: editor.hoveredLinkUrl = ""

            // Ctrl+wheel changes the text size, as it does in a browser. A
            // wheel notch is a whole step, but a touchpad trickles in pixels,
            // so bank the fractions and step once a whole one is scrolled.
            property real zoomNotches: 0

            function zoomByWheel(wheel) {
                // Finger scrolling synthesizes an angleDelta too, so pixelDelta
                // is the one to test first, as in onWheel.
                var notches = wheel.pixelDelta.y !== 0
                    ? wheel.pixelDelta.y / 50
                    : wheel.angleDelta.y / 120;
                if (zoomNotches * notches < 0)
                    zoomNotches = 0;

                zoomNotches += notches;
                while (zoomNotches >= 1) {
                    backend.increaseTextSize();
                    zoomNotches -= 1;
                }
                while (zoomNotches <= -1) {
                    backend.decreaseTextSize();
                    zoomNotches += 1;
                }
            }

            function scrollByWheel(wheel) {
                // High-resolution wheels report fractional notches; feed
                // those through the same animated path, like Chromium does
                // for every wheel-source event.
                var notches = wheel.angleDelta.y / 120;
                if (notches === 0)
                    return;

                if (wheelScroll.running) {
                    wheelScroll.retarget(clampContentY(wheelScroll.targetY - notches * wheelStep));
                    return;
                }

                var target = clampContentY(contentY - notches * wheelStep);
                if (target !== contentY)
                    wheelScroll.begin(contentY, target, wheelDuration(target - contentY), 0);
            }

            // Chromium's inverse-delta duration: 200ms for a single notch,
            // ramping down to 100ms once 480px are outstanding.
            function wheelDuration(delta) {
                var pixels = Math.abs(delta) / win.textScale;
                return Math.max(6, Math.min(12, 14 - pixels / 60)) / 60;
            }

            function clampContentY(y) {
                return Math.max(0, Math.min(Math.max(0, contentHeight - height), y));
            }

            // Whole device pixels keep natively hinted glyphs from
            // re-rasterizing mid-animation, which reads as shimmer.
            function snapToPixel(y) {
                return Math.round(y * Screen.devicePixelRatio) / Screen.devicePixelRatio;
            }

            // Jump to a position, abandoning any wheel animation still running.
            function scrollTo(y) {
                wheelScroll.stop();
                contentY = snapToPixel(y);
            }

            // Keep the editing caret within the viewport so writing past the
            // bottom edge scrolls the page along with the text.
            function ensureCursorVisible() {
                var margin = win.editorFontPixelSize * 2;
                var cursorTop = editor.y + editor.cursorRectangle.y;
                var cursorBottom = cursorTop + editor.cursorRectangle.height;
                var maxContentY = Math.max(0, contentHeight - height);

                if (cursorBottom + margin > contentY + height)
                    scrollTo(Math.min(maxContentY, cursorBottom + margin - height));
                else if (cursorTop - margin < contentY)
                    scrollTo(Math.max(0, cursorTop - margin));
            }

            // The note's title, which is also its name in the sidebar. Enter
            // or Down moves on into the text.
            TextInput {
                id: titleInput
                objectName: "titleInput"
                x: editor.x
                y: Math.max(0, Math.max(42, Math.round(win.height * 0.05)) - win.footerHeight)
                width: editor.width
                color: win.textColor
                selectedTextColor: win.selectionTextColor
                selectionColor: win.selectionFill
                selectByMouse: true
                clip: true
                font.family: backend.editorFont
                font.pixelSize: win.scaledSize(30)
                font.weight: Font.Bold
                onTextEdited: notes.setTitle(text)
                Keys.onReturnPressed: editor.focusTop()
                Keys.onEnterPressed: editor.focusTop()
                Keys.onDownPressed: editor.focusTop()
                Keys.onTabPressed: editor.focusTop()

                Text {
                    anchors.fill: parent
                    text: qsTr("Title")
                    visible: titleInput.length === 0
                    color: win.mutedColor
                    font: titleInput.font
                }
            }

            TextEdit {
                id: editor
                objectName: "sourceEditor"
                x: Math.round((editorFlick.width - width) / 2)
                y: titleInput.y + titleInput.height + win.scaledSize(18)

                function focusTop() {
                    forceActiveFocus();
                    cursorPosition = 0;
                }
                width: win.editorWidth
                height: Math.max(editorFlick.height - y - 96, implicitHeight + 20)
                text: ""
                textFormat: TextEdit.PlainText
                wrapMode: TextEdit.Wrap
                selectByMouse: true
                persistentSelection: true
                activeFocusOnPress: true
                color: win.textColor
                selectedTextColor: win.selectionTextColor
                selectionColor: win.selectionFill
                font.family: backend.editorFont
                font.pixelSize: win.editorFontPixelSize
                font.weight: Font.Normal
                // Native rendering hints glyphs to the pixel grid, which is
                // crispest at whole scale factors but misplaces and unevenly
                // rasterizes glyphs at fractional ones (and goes stale when
                // the compositor delivers the fractional scale after the
                // first frame). Fall back to Qt's scalable renderer there.
                renderType: Screen.devicePixelRatio % 1 === 0 ? TextEdit.NativeRendering : TextEdit.QtRendering
                cursorDelegate: Rectangle {
                    width: 1
                    color: win.textColor
                }
                onCursorRectangleChanged: editorFlick.ensureCursorVisible()
                onCursorPositionChanged: backend.setCaretPosition(cursorPosition)
                onFontChanged: backend.documentFontChanged()

                // One edit command, so a single undo takes the change back.
                function replaceText(start, end, replacement) {
                    backend.replaceRange(start, end, replacement);
                }

                function replaceSelectionWith(replacement) {
                    EditorMutations.replaceRange(editor, selectionStart, selectionEnd, replacement);
                }

                // Markdown has no underline, so it is the <u> tag Markdown
                // lets through, wrapped and unwrapped like the other styles.
                function toggleUnderline() {
                    forceActiveFocus();
                    var start = selectionStart;
                    var end = selectionEnd;
                    if (start === end) {
                        var span = backend.emphasisSpanAt(cursorPosition, "<u>");
                        if (span && span.start !== undefined)
                            EditorMutations.toggleWrap(editor, "<u>", span);
                        else
                            EditorMutations.replaceRange(editor, start, end, "<u></u>", 3, 3);
                        return;
                    }
                    var selected = text.slice(start, end);
                    if (text.slice(start - 3, start) === "<u>" && text.slice(end, end + 4) === "</u>") {
                        EditorMutations.replaceRange(editor, start - 3, end + 4, selected,
                                                     0, selected.length);
                        return;
                    }
                    var wrapped = selected.match(/^<u>([\s\S]*)<\/u>$/);
                    if (wrapped) {
                        EditorMutations.replaceRange(editor, start, end, wrapped[1],
                                                     0, wrapped[1].length);
                        return;
                    }
                    EditorMutations.replaceRange(editor, start, end, "<u>" + selected + "</u>",
                                                 3, 3 + selected.length);
                }

                // Turns the lines the caret or selection touches into a
                // bulleted, numbered or check list, or back into plain lines
                // when they already all are one. Like Notes on the Mac.
                function toggleList(kind) {
                    forceActiveFocus();
                    var from = text.lastIndexOf("\n", selectionStart - 1) + 1;
                    var toBreak = text.indexOf("\n", selectionEnd);
                    var to = toBreak < 0 ? text.length : toBreak;
                    var lines = text.slice(from, to).split("\n");
                    var itemRe = /^(\s*)(?:([-+*])\s+(?:\[([ xX])\]\s+)?|(\d+)[.)]\s+)?(.*)$/;
                    var kindOf = function(m) {
                        if (m[4] !== undefined) return "number";
                        if (m[3] !== undefined) return "check";
                        if (m[2] !== undefined) return "bullet";
                        return "";
                    };
                    var allAlready = lines.every(function(line) {
                        var m = line.match(itemRe);
                        return m[5].length === 0 && kindOf(m) === "" || kindOf(m) === kind;
                    }) && lines.some(function(line) { return kindOf(line.match(itemRe)) === kind; });
                    var number = 0;
                    var result = lines.map(function(line) {
                        var m = line.match(itemRe);
                        if (allAlready)
                            return m[1] + m[5];
                        if (m[5].length === 0 && lines.length > 1)
                            return line;
                        if (kind === "bullet")
                            return m[1] + "- " + m[5];
                        if (kind === "number")
                            return m[1] + (++number) + ". " + m[5];
                        var mark = m[3] !== undefined ? m[3] : " ";
                        return m[1] + "- [" + mark + "] " + m[5];
                    }).join("\n");
                    var caretFromEnd = to - cursorPosition;
                    EditorMutations.replaceRange(editor, from, to, result);
                    if (lines.length === 1)
                        cursorPosition = Math.max(from, from + result.length - caretFromEnd);
                }

                // Ticks the checklist item on the caret's line, or unticks it.
                // A line that is not a checklist item becomes one.
                function toggleCheck() {
                    forceActiveFocus();
                    var from = text.lastIndexOf("\n", cursorPosition - 1) + 1;
                    var lineBreak = text.indexOf("\n", cursorPosition);
                    var line = text.slice(from, lineBreak < 0 ? text.length : lineBreak);
                    var m = line.match(/^(\s*[-+*]\s+\[)([ xX])\]/);
                    if (!m) {
                        toggleList("check");
                        return;
                    }
                    var caret = cursorPosition;
                    var at = from + m[1].length;
                    EditorMutations.replaceRange(editor, at, at + 1, m[2] === " " ? "x" : " ");
                    cursorPosition = caret;
                }

                // Makes the lines the caret or selection touches a Title (1),
                // Heading (2) or Subheading (3), or plain text (0). Choosing
                // the level the lines already have turns them back into text,
                // the way the list buttons toggle.
                function setHeading(level) {
                    forceActiveFocus();
                    var from = text.lastIndexOf("\n", selectionStart - 1) + 1;
                    var toBreak = text.indexOf("\n", selectionEnd);
                    var to = toBreak < 0 ? text.length : toBreak;
                    var lines = text.slice(from, to).split("\n");
                    var headingRe = /^#{1,6}\s+/;
                    var listRe = /^\s*(?:[-+*]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)/;
                    var marker = level > 0 ? "#".repeat(level) + " " : "";
                    var already = level > 0 && lines.every(function(line) {
                        return line.trim().length === 0 || line.indexOf(marker) === 0;
                    });
                    var result = lines.map(function(line) {
                        if (lines.length > 1 && line.trim().length === 0)
                            return line;
                        var bare = line.replace(headingRe, "");
                        if (already || level === 0)
                            return bare;
                        return marker + bare.replace(listRe, "");
                    }).join("\n");
                    var caretFromEnd = to - cursorPosition;
                    EditorMutations.replaceRange(editor, from, to, result);
                    if (lines.length === 1)
                        cursorPosition = Math.max(from, from + result.length - caretFromEnd);
                }

                // Edits made through the document (styles, lists, sums) undo
                // with the caret thrown to the top of the note. Put it back at
                // the end of whatever the undo or redo changed.
                function undoKeepingPlace(redoing) {
                    var before = text;
                    if (redoing)
                        redo();
                    else
                        undo();
                    var after = text;
                    if (before === after)
                        return;
                    var start = 0;
                    while (start < before.length && start < after.length
                           && before.charCodeAt(start) === after.charCodeAt(start))
                        ++start;
                    var endBefore = before.length;
                    var endAfter = after.length;
                    while (endBefore > start && endAfter > start
                           && before.charCodeAt(endBefore - 1) === after.charCodeAt(endAfter - 1)) {
                        --endBefore;
                        --endAfter;
                    }
                    cursorPosition = endAfter;
                    editorFlick.ensureCursorVisible();
                }

                function wrapSelection(marker) {
                    forceActiveFocus();
                    EditorMutations.toggleWrap(editor, marker,
                                               backend.emphasisSpanAt(cursorPosition, marker));
                }

                function insertLink() {
                    forceActiveFocus();
                    var start = selectionStart;
                    var end = selectionEnd;
                    var selected = text.slice(start, end);
                    var url = backend.clipboardUrl();
                    var label = selected.length > 0 ? selected : "link text";
                    var markdown = markdownLink(label, url.length > 0 ? url : "https://");
                    var labelLength = escapeMarkdownLinkText(label).length;
                    if (selected.length === 0) {
                        EditorMutations.replaceRange(editor, start, end, markdown,
                                                     1, 1 + labelLength);
                    } else if (url.length === 0) {
                        EditorMutations.replaceRange(editor, start, end, markdown,
                                                     labelLength + 3,
                                                     markdown.length - 1);
                    } else {
                        EditorMutations.replaceRange(editor, start, end, markdown);
                    }
                }

                function smartReturn(softBreak) {
                    if (softBreak) {
                        replaceSelectionWith("\n");
                        return;
                    }
                    var lineStart = text.lastIndexOf("\n", cursorPosition - 1) + 1;
                    var line = text.slice(lineStart, cursorPosition);
                    if (backend.insideFence(cursorPosition)) {
                        replaceSelectionWith("\n");
                        return;
                    }
                    // A checklist item carries on with a fresh, unticked box;
                    // Enter on an empty one ends the list.
                    var task = line.match(/^(\s*)([-+*])\s+\[[ xX]\]\s+(.*)$/);
                    if (task) {
                        if (task[3].length === 0)
                            EditorMutations.replaceRange(editor, lineStart, cursorPosition, "\n");
                        else
                            replaceSelectionWith("\n" + task[1] + task[2] + " [ ] ");
                        return;
                    }
                    var match = line.match(/^(\s*)([-+*]|\d+[.)]|>+)\s+(.*)$/);
                    if (match) {
                        if (match[3].length === 0) {
                            EditorMutations.replaceRange(editor, lineStart,
                                                         cursorPosition, "\n");
                        } else {
                            var marker = match[2];
                            if (/^\d/.test(marker))
                                marker = (parseInt(marker) + 1) + marker.slice(-1);
                            replaceSelectionWith("\n" + match[1] + marker + " ");
                        }
                        return;
                    }
                    // A new paragraph stands apart from the one above it by a
                    // blank line, which is the second break here. A line that
                    // is already blank has nothing to stand apart from, so
                    // that break would only be a gap nobody asked for.
                    // The break lands on what the selection leaves behind, which
                    // is not the caret's line when it was dragged right to left.
                    var start = selectionStart;
                    var end = selectionEnd;
                    var head = text.slice(text.lastIndexOf("\n", start - 1) + 1, start);
                    var lineEnd = text.indexOf("\n", end);
                    var rest = lineEnd < 0 ? text.slice(end)
                                           : text.slice(end, lineEnd);
                    if (/^\s*$/.test(head) && /^\s*$/.test(rest)) {
                        replaceSelectionWith("\n");
                        return;
                    }
                    replaceSelectionWith("\n\n");
                }

                // Tab nests the list items the caret or selection touches four
                // spaces deeper, and Shift+Tab lifts them back out by the same
                // step. Lines that are neither items, their indented
                // continuations, nor blank, and code fences, leave Tab alone.
                function indentListItems(outdent) {
                    // "* * *" and "- - -" are rules, not items.
                    var listItem = function(line) {
                        return /^[ \t]*(?:[-+*]|\d+[.)])[ \t]/.test(line)
                            && !/^ {0,3}([-*])([ \t]*\1){2,}[ \t]*$/.test(line);
                    };
                    // A tab runs to the next four-column stop.
                    var columns = function(line) {
                        return line.match(/^[ \t]*/)[0].split("").reduce(function(column, c) {
                            return c === "\t" ? column + 4 - column % 4 : column + 1;
                        }, 0);
                    };

                    // A selection that ends at the start of a line leaves it be.
                    // lastIndexOf would read -1 as 0, a newline right there.
                    var start = selectionStart > 0 ? text.lastIndexOf("\n", selectionStart - 1) + 1 : 0;
                    var end = text.indexOf("\n", Math.max(start, selectionEnd - 1));
                    if (end < 0)
                        end = text.length;
                    var lines = text.slice(start, end).split("\n");
                    // The selection starts at an item and holds only lines that
                    // belong to one: other items, blanks, and indented lines.
                    // A fence indented under an item moves along with it whole;
                    // a selection that starts or ends inside code would split it.
                    var filled = lines.filter(function(line) { return /\S/.test(line); });
                    if (!listItem(filled[0] || "")
                        || filled.some(function(line) { return /^\S/.test(line) && !listItem(line); })
                        || backend.insideFence(start)
                        || backend.insideFence(end))
                        return false;

                    // Every line moves by the same step, so the nesting within
                    // the selection is kept. Four spaces nest under any marker
                    // up to "99.", and Shift+Tab lifts no further than the
                    // shallowest line can go.
                    var step = outdent ? -Math.min.apply(null, [4].concat(filled.map(columns))) : 4;
                    if (step === 0)
                        return true;
                    var moved = lines.map(function(line) {
                        var lead = line.match(/^[ \t]*/)[0];
                        return /\S/.test(line)
                            ? " ".repeat(columns(line) + step) + line.slice(lead.length)
                            : line;
                    });
                    var nested = moved.join("\n");
                    var from = Math.max(start, selectionStart + moved[0].length - lines[0].length);
                    // Neither end of the selection leaves its line, even when
                    // the indent it sat in is gone.
                    var lastStart = start + nested.length - moved[moved.length - 1].length;
                    var to = Math.max(from, lastStart, selectionEnd + nested.length - (end - start));
                    var forward = cursorPosition === selectionEnd;
                    replaceText(start, end, nested);
                    select(forward ? from : to, forward ? to : from);
                    return true;
                }

                function escapeMarkdownLinkText(linkText) {
                    return linkText.replace(/\\/g, "\\\\")
                                   .replace(/\[/g, "\\[")
                                   .replace(/\]/g, "\\]");
                }

                function escapeMarkdownLinkDestination(linkUrl) {
                    return linkUrl.replace(/\\/g, "\\\\")
                                  .replace(/\(/g, "\\(")
                                  .replace(/\)/g, "\\)");
                }

                function markdownLink(label, url) {
                    return "[" + escapeMarkdownLinkText(label) + "]("
                        + escapeMarkdownLinkDestination(url) + ")";
                }

                function pasteClipboardUrlAsMarkdownLink() {
                    var start = selectionStart;
                    var end = selectionEnd;
                    if (start === end)
                        return false;

                    var url = backend.clipboardUrl();
                    if (url === "")
                        return false;

                    var selected = text.slice(start, end);
                    var leading = selected.match(/^\s*/)[0];
                    var trailing = selected.match(/\s*$/)[0];
                    var linkText = selected.slice(leading.length,
                                                  selected.length - trailing.length);
                    if (linkText === "")
                        return false;

                    replaceSelectionWith(leading + markdownLink(linkText, url) + trailing);
                    return true;
                }

                function pasteClipboardAsPlainText() {
                    var pastedText = backend.clipboardText();
                    if (pastedText.length > 0)
                        replaceSelectionWith(pastedText);
                }

                function moveCursorVisibly(direction) {
                    if (selectionStart !== selectionEnd) {
                        cursorPosition = direction > 0 ? selectionEnd : selectionStart;
                        return;
                    }

                    var pos = backend.cursorPositionStep(cursorPosition, direction);
                    cursorPosition = Math.max(0, Math.min(length, pos));
                }

                function movePage(direction, extendSelection) {
                    var pageStep = Math.max(win.editorFontPixelSize,
                                            editorFlick.height - win.editorFontPixelSize * 2);
                    var rect = cursorRectangle;
                    var targetY = rect.y + rect.height / 2 + direction * pageStep;
                    var target = positionAt(rect.x, Math.max(0, targetY));
                    if (extendSelection)
                        moveCursorSelection(target, TextEdit.SelectCharacters);
                    else
                        cursorPosition = target;
                }

                function deleteParagraphBreakBehindCursor() {
                    if (selectionStart !== selectionEnd || cursorPosition < 2)
                        return false;

                    // getText reads just the two characters, where text would
                    // copy the whole document on every Backspace.
                    if (getText(cursorPosition - 2, cursorPosition) !== "\n\n")
                        return false;

                    var start = cursorPosition - 2;
                    var lineEnd = text.indexOf("\n", cursorPosition);
                    var line = lineEnd < 0 ? text.slice(cursorPosition)
                                           : text.slice(cursorPosition, lineEnd);
                    // Something on the caret's line and the pair above it is a
                    // paragraph break and nothing else, either the one Return
                    // wrote to end a paragraph or the one the writer is now
                    // closing to join what it separates. Both breaks go.
                    if (/^\s*$/.test(line)) {
                        // On a blank line Return writes a single break, so up
                        // here the pair may be that break and one that was
                        // already in the document. Above a blank line Return
                        // writes a single break too, and so wrote neither of
                        // these.
                        var above = text.slice(text.lastIndexOf("\n", start - 1) + 1, start);
                        if (/^\s*$/.test(above))
                            return false;
                        // Past that the two Returns leave the same text and the
                        // same caret, and no reading of either says which was
                        // pressed. What decides instead is that the gap is left
                        // standing: both breaks go only while a blank line of
                        // it survives them. The end of the document below the
                        // caret leaves it none...
                        if (lineEnd < 0)
                            return false;
                        // ...and so does the next paragraph, which the pair
                        // would otherwise be pulled up against.
                        var belowEnd = text.indexOf("\n", lineEnd + 1);
                        var below = belowEnd < 0 ? text.slice(lineEnd + 1)
                                                 : text.slice(lineEnd + 1, belowEnd);
                        if (!/^\s*$/.test(below))
                            return false;
                    }

                    remove(start, cursorPosition);
                    cursorPosition = start;
                    return true;
                }

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                    // The text box would take undo and redo itself, and leave
                    // the caret at the top of the note.
                    if (event.matches(StandardKey.Undo) || event.matches(StandardKey.Redo)
                            || (event.key === Qt.Key_Y && event.modifiers === Qt.ControlModifier)) {
                        undoKeepingPlace(!event.matches(StandardKey.Undo));
                        event.accepted = true;
                        return;
                    }
                    // Up from the first line climbs into the title.
                    if (event.key === Qt.Key_Up && event.modifiers === Qt.NoModifier
                            && cursorRectangle.y < cursorRectangle.height / 2) {
                        titleInput.forceActiveFocus();
                        titleInput.cursorPosition = titleInput.length;
                        event.accepted = true;
                        return;
                    }
                    var pasteKey = (event.key === Qt.Key_V)
                        && (event.modifiers & Qt.ControlModifier)
                        && !(event.modifiers & (Qt.AltModifier | Qt.MetaModifier | Qt.ShiftModifier));
                    var shiftInsert = (event.key === Qt.Key_Insert)
                        && (event.modifiers & Qt.ShiftModifier)
                        && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier));
                    if (pasteKey || shiftInsert) {
                        if (!pasteClipboardUrlAsMarkdownLink())
                            pasteClipboardAsPlainText();
                        event.accepted = true;
                        return;
                    }

                    var pageKey = event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp;
                    var documentEdgeKey = (event.key === Qt.Key_Home || event.key === Qt.Key_End)
                        && (event.modifiers & Qt.ControlModifier);
                    if (pageKey || documentEdgeKey)
                        scrollLinger.restart();

                    var returnKey = event.key === Qt.Key_Return || event.key === Qt.Key_Enter;
                    var commandModifier = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier);
                    if (returnKey && !commandModifier) {
                        smartReturn(event.modifiers & Qt.ShiftModifier);
                        event.accepted = true;
                    } else if (!commandModifier && event.key === Qt.Key_Backspace
                               && deleteParagraphBreakBehindCursor()) {
                        event.accepted = true;
                    } else if (!commandModifier && !(event.modifiers & Qt.ShiftModifier)
                               && event.key === Qt.Key_Right) {
                        moveCursorVisibly(1);
                        event.accepted = true;
                    } else if (!commandModifier && !(event.modifiers & Qt.ShiftModifier)
                               && event.key === Qt.Key_Left) {
                        moveCursorVisibly(-1);
                        event.accepted = true;
                    } else if (!commandModifier
                               && (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
                               && indentListItems(event.key === Qt.Key_Backtab
                                                  || (event.modifiers & Qt.ShiftModifier))) {
                        event.accepted = true;
                    } else if (!commandModifier
                               && (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp)) {
                        movePage(event.key === Qt.Key_PageDown ? 1 : -1,
                                 event.modifiers & Qt.ShiftModifier);
                        event.accepted = true;
                    }
                }

                onTextChanged: {
                    hoveredLinkUrl = "";
                    if (win.searchUpdating)
                        return;
                    var contentChanged = backend.editorTextChanged();
                    if (win.searchOpen && contentChanged)
                        win.updateSearch(false);
                }

                Text {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    text: qsTr("Start writing")
                    visible: editor.length === 0 && !editor.activeFocus
                    color: win.mutedColor
                    font.family: editor.font.family
                    font.pixelSize: editor.font.pixelSize
                    font.weight: editor.font.weight
                }

                property string hoveredLinkUrl: ""
                property real linkHoverX: 0
                property real linkHoverY: 0

                // positionAt() snaps to the nearest caret, even past the end of a
                // line, so only count a character the pointer is inside: the one
                // on either side of that caret, whichever way the text runs.
                function linkUrlUnder(x, y) {
                    var caret = positionAt(x, y);
                    for (var position = Math.max(0, caret - 1);
                         position <= caret && position < length; ++position) {
                        var box = positionToRectangle(position);
                        var next = positionToRectangle(position + 1);
                        // A hidden marker has no width; only a line's last
                        // character needs an estimate.
                        var edge = next.y === box.y
                            ? next.x : box.x + writerFontMetrics.averageCharacterWidth;
                        if (y >= box.y && y < box.y + box.height
                                && x >= Math.min(box.x, edge) && x < Math.max(box.x, edge))
                            return backend.linkUrlAt(position);
                    }
                    return "";
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    hoverEnabled: true
                    cursorShape: Qt.IBeamCursor
                    onPositionChanged: (mouse) => {
                        editor.linkHoverX = mouse.x;
                        editor.linkHoverY = mouse.y;
                        editor.hoveredLinkUrl = editor.linkUrlUnder(mouse.x, mouse.y);
                    }
                    onExited: editor.hoveredLinkUrl = ""
                }

                ToolTip {
                    visible: editor.hoveredLinkUrl.length > 0
                    x: editor.linkHoverX + 12
                    y: editor.linkHoverY + 20
                    contentItem: Label {
                        objectName: "linkTooltipText"
                        // A destination is document text; AutoText would render
                        // one that looks like HTML instead of showing it.
                        textFormat: Text.PlainText
                        text: editor.hoveredLinkUrl
                        font.family: backend.editorFont
                        font.pixelSize: win.scaledSize(12)
                        elide: Text.ElideMiddle
                    }
                    width: Math.min(implicitWidth, win.width - 32)
                }

                Component.onCompleted: {
                    backend.attachDocument(textDocument);
                    forceActiveFocus();
                }
            }
        }

        FormatBar {
            id: formatBar
            objectName: "formatBar"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: win.footerHeight
            editor: editor
            textColor: win.textColor
            mutedColor: win.mutedColor
            pageColor: win.pageColor
            textScale: win.textScale
            contentX: editorFlick.x + editor.x
        }

        Row {
            id: footerStatus
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.leftMargin: 12
            anchors.bottomMargin: 10
            spacing: 12
            opacity: 0.55

            FooterIconButton {
                id: fontButton
                objectName: "fontButton"
                iconName: "font"
                iconColor: win.mutedColor
                tooltip: "Font"
                onClicked: fontPicker.opened ? fontPicker.close() : fontPicker.open()
            }

            Label {
                text: backend.status
                color: win.mutedColor
                font.family: "IBM Plex Mono"
                font.pixelSize: win.scaledSize(11)
                visible: text !== ""
                elide: Text.ElideRight
                width: Math.min(360, win.width / 3)
                height: win.scaledSize(16)
                verticalAlignment: Text.AlignVCenter
            }
        }

        FontPicker {
            id: fontPicker
            objectName: "fontPicker"
            // Parented to its button, so a press on the button is not a press
            // outside that closes it only for the click to open it again.
            parent: fontButton
            x: -8
            y: -height - 10
            width: win.scaledSize(320)
            maximumHeight: Math.min(win.scaledSize(440), win.height - 80)
            fonts: backend.availableFonts
            currentFont: backend.editorFont
            defaultFont: "IBM Plex Mono"
            darkMode: win.darkMode
            textScale: win.textScale
            textColor: win.textColor
            mutedColor: win.mutedColor
            highlightColor: backend.themeAccent
            onFontChosen: function(family) { backend.editorFont = family; }
            onClosed: editor.forceActiveFocus()
        }

        Label {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 12
            anchors.bottomMargin: 10
            text: backend.wordCount + (backend.wordCount === 1 ? " Word" : " Words")
            color: win.mutedColor
            opacity: 0.75
            font.family: "IBM Plex Mono"
            font.pixelSize: win.scaledSize(11)
        }


        Pane {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 12
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            height: win.scaledSize(win.replaceOpen ? 104 : 56)
            visible: win.searchOpen
            z: 10
            leftPadding: 16
            rightPadding: 8
            topPadding: 0
            bottomPadding: 0
            Material.elevation: 8
            // Reaches here from either field or the buttons beside them.
            Keys.onEscapePressed: function(event) {
                win.closeSearch();
                event.accepted = true;
            }

            background: Rectangle {
                radius: 9
                color: win.darkMode ? "#22221f" : "#fffef2"
            }

            RowLayout {
                anchors.fill: parent
                spacing: 8

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    TextInput {
                        id: searchField
                        objectName: "searchField"
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: win.replaceOpen ? parent.height / 2 : parent.height
                        verticalAlignment: TextInput.AlignVCenter
                        selectByMouse: true
                        activeFocusOnTab: true
                        color: win.textColor
                        selectionColor: win.selectionFill
                        selectedTextColor: win.selectionTextColor
                        font.pixelSize: win.scaledSize(17)
                        clip: true
                        onTextChanged: searchDelay.restart()
                        Keys.onReturnPressed: function(event) {
                            win.moveSearch((event.modifiers & Qt.ShiftModifier) ? -1 : 1);
                            event.accepted = true;
                        }
                    }

                    TextInput {
                        id: replaceField
                        objectName: "replaceField"
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: parent.height / 2
                        visible: win.replaceOpen
                        verticalAlignment: TextInput.AlignVCenter
                        selectByMouse: true
                        activeFocusOnTab: true
                        clip: true
                        color: win.textColor
                        selectionColor: win.selectionFill
                        selectedTextColor: win.selectionTextColor
                        font.pixelSize: win.scaledSize(17)
                        Keys.onReturnPressed: replaceCurrentButton.clicked()
                    }

                    Label {
                        anchors.verticalCenter: replaceField.verticalCenter
                        text: "Replace with"
                        visible: win.replaceOpen && replaceField.text.length === 0
                        color: win.mutedColor
                        font.pixelSize: win.scaledSize(17)
                    }

                    Label {
                        anchors.verticalCenter: searchField.verticalCenter
                        text: "Find"
                        visible: searchField.text.length === 0
                        color: win.mutedColor
                        font.pixelSize: win.scaledSize(17)
                    }
                }

                Label {
                    Layout.preferredWidth: win.scaledSize(58)
                    Layout.fillHeight: true
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: win.searchMatches.length === 0
                        ? "0/0"
                        : (win.searchMatchIndex + 1) + "/" + win.searchMatches.length
                    color: win.darkMode ? win.textColor : "#62635f"
                    font.pixelSize: win.scaledSize(16)
                }

                Button {
                    id: replaceCurrentButton
                    objectName: "replaceButton"
                    visible: win.replaceOpen
                    text: "Replace"
                    onClicked: {
                        win.flushSearch();
                        if (win.searchMatchIndex < 0) return;
                        var start = win.searchMatches[win.searchMatchIndex];
                        var replacement = replaceField.text;
                        EditorMutations.replaceRange(editor, start,
                                                     start + searchField.text.length,
                                                     replacement);
                        // Carry on past what was just written, so a replacement
                        // the query also matches is not found again.
                        win.searchMatches = backend.searchMatches(searchField.text);
                        win.searchMatchIndex = win.matchAtOrAfter(start + replacement.length);
                        win.showSearchMatch(true);
                    }
                }

                Button {
                    objectName: "replaceAllButton"
                    visible: win.replaceOpen
                    text: "All"
                    onClicked: {
                        win.flushSearch();
                        var query = searchField.text;
                        var matches = win.searchMatches;
                        if (query.length === 0 || matches.length === 0) return;
                        // One replacement over the span of every match, so a
                        // single undo takes them all back.
                        var first = matches[0];
                        var replaced = "";
                        var position = first;
                        for (var i = 0; i < matches.length; ++i) {
                            replaced += editor.text.slice(position, matches[i]) + replaceField.text;
                            position = matches[i] + query.length;
                        }
                        EditorMutations.replaceRange(editor, first, position, replaced);
                        win.updateSearch(false);
                    }
                }

                Rectangle {
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 34
                    color: win.darkMode ? "#6f6f62" : "#d5d56e"
                }

                SearchIconButton {
                    iconName: "up"
                    iconColor: win.darkMode ? win.textColor : "#62635f"
                    onClicked: win.moveSearch(-1)
                }

                SearchIconButton {
                    iconName: "down"
                    iconColor: win.darkMode ? win.textColor : "#62635f"
                    onClicked: win.moveSearch(1)
                }

                SearchIconButton {
                    iconName: "close"
                    iconColor: win.darkMode ? win.textColor : "#62635f"
                    onClicked: win.closeSearch()
                }
            }
        }
    }

    Component.onCompleted: {
        refreshNoteFilter();
        var geometry = backend.windowGeometry();
        if (geometry.x >= 0) x = geometry.x;
        if (geometry.y >= 0) y = geometry.y;
        width = geometry.width;
        height = geometry.height;
        if (geometry.maximized) showMaximized();
    }

    Component.onDestruction: backend.saveWindowGeometry(x, y, width, height, visibility === Window.Maximized)

}

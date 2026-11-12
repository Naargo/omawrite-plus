import QtQuick
import QtQuick.Controls
import QtQuick.Window

// The formatting strip across the top of the editor: a heading menu, the
// text styles, and the three kinds of list. Every button is a shortcut the
// editor already has; the bar only shows them, lit up when the caret sits in
// that style. It never takes focus, so the caret stays where it was.
Item {
    id: bar

    // The TextEdit it formats, with the editor's own formatting functions.
    property var editor
    property color textColor: "#eeeeee"
    property color mutedColor: "#909191"
    property color pageColor: "#101010"
    property real textScale: 1
    // Where the text column starts, so the buttons line up with the text.
    property real contentX: 0

    readonly property color hairline: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.09)
    readonly property color activeFill: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.11)
    readonly property int buttonSize: Math.round(26 * textScale)

    // What the caret's line is: its heading level (0 for body text) and list
    // kind ("bullet", "number", "check" or "").
    readonly property var lineStyle: {
        if (!editor)
            return { heading: 0, list: "" };
        var text = editor.text;
        var position = editor.cursorPosition;
        var from = text.lastIndexOf("\n", position - 1) + 1;
        var lineBreak = text.indexOf("\n", position);
        var line = text.slice(from, lineBreak < 0 ? text.length : lineBreak);
        var heading = line.match(/^(#{1,6})\s/);
        var list = "";
        if (/^\s*[-+*]\s+\[[ xX]\]\s/.test(line))
            list = "check";
        else if (/^\s*[-+*]\s/.test(line))
            list = "bullet";
        else if (/^\s*\d+[.)]\s/.test(line))
            list = "number";
        return { heading: heading ? heading[1].length : 0, list: list };
    }

    function inStyle(marker) {
        if (!editor)
            return false;
        // Read text and caret so the binding follows both.
        var length = editor.text.length;
        var span = backend.emphasisSpanAt(editor.cursorPosition, marker);
        return length >= 0 && span !== undefined && span.start !== undefined;
    }

    readonly property var headingLevels: [
        { level: 1, name: qsTr("Title"), keys: "Ctrl+Shift+T", scale: 1.6 },
        { level: 2, name: qsTr("Heading"), keys: "Ctrl+Shift+H", scale: 1.3 },
        { level: 3, name: qsTr("Subheading"), keys: "Ctrl+Shift+J", scale: 1.12 },
        { level: 0, name: qsTr("Body"), keys: "Ctrl+Shift+B", scale: 1 }
    ]

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: bar.hairline
    }

    component FormatButton: Rectangle {
        id: button

        property string label
        property string iconName
        property bool active: false
        property string tooltip
        property bool bold: false
        property bool italic: false
        property bool underline: false
        property bool strikeout: false

        signal clicked()

        width: bar.buttonSize
        height: bar.buttonSize
        color: active ? bar.activeFill : "transparent"
        readonly property color inkColor: active || hit.containsMouse ? bar.textColor : bar.mutedColor

        ToolTip.visible: hit.containsMouse && tooltip.length > 0
        ToolTip.delay: 500
        ToolTip.text: tooltip

        Text {
            anchors.centerIn: parent
            visible: button.label.length > 0
            text: button.label
            color: button.inkColor
            font.pixelSize: Math.round(15 * bar.textScale)
            font.bold: button.bold
            font.italic: button.italic
            font.underline: button.underline
            font.strikeout: button.strikeout
        }

        Canvas {
            id: canvas
            visible: button.iconName.length > 0
            anchors.centerIn: parent
            // Drawn at the physical size and scaled back, so it stays sharp.
            readonly property real dpr: Screen.devicePixelRatio
            readonly property real side: Math.round(16 * bar.textScale)
            width: side * dpr
            height: side * dpr
            scale: 1 / dpr
            onDprChanged: requestPaint()
            onSideChanged: requestPaint()

            onPaint: {
                var c = getContext("2d");
                var unit = side / 16;
                c.setTransform(dpr * unit, 0, 0, dpr * unit, 0, 0);
                c.clearRect(0, 0, 16, 16);
                c.strokeStyle = button.inkColor;
                c.fillStyle = button.inkColor;
                c.lineWidth = 1.4;
                c.lineCap = "round";
                c.lineJoin = "round";
                var rows = [3.5, 8, 12.5];
                c.beginPath();
                for (var i = 0; i < rows.length; ++i) {
                    c.moveTo(6.5, rows[i]);
                    c.lineTo(14.5, rows[i]);
                }
                c.stroke();
                if (button.iconName === "bullet") {
                    for (var b = 0; b < rows.length; ++b) {
                        c.beginPath();
                        c.arc(2.75, rows[b], 1.25, 0, Math.PI * 2);
                        c.fill();
                    }
                } else if (button.iconName === "number") {
                    c.font = "bold 5px sans-serif";
                    c.textAlign = "center";
                    c.textBaseline = "middle";
                    for (var n = 0; n < rows.length; ++n)
                        c.fillText(String(n + 1), 2.75, rows[n] + 0.3);
                } else if (button.iconName === "check") {
                    c.lineWidth = 1.1;
                    for (var k = 0; k < rows.length; ++k) {
                        c.beginPath();
                        c.rect(1, rows[k] - 1.75, 3.5, 3.5);
                        c.stroke();
                    }
                    c.beginPath();
                    c.moveTo(1.6, rows[0]);
                    c.lineTo(2.6, rows[0] + 1);
                    c.lineTo(4.2, rows[0] - 1.2);
                    c.stroke();
                }
            }

            Connections {
                target: button
                function onInkColorChanged() { canvas.requestPaint(); }
            }
        }

        MouseArea {
            id: hit
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: button.clicked()
        }
    }

    component Divider: Rectangle {
        width: 1
        height: Math.round(bar.buttonSize * 0.6)
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        color: bar.hairline
    }

    Row {
        id: buttons
        x: Math.max(0, bar.contentX - Math.round(6 * bar.textScale))
        anchors.verticalCenter: parent.verticalCenter
        spacing: Math.round(2 * bar.textScale)

        FormatButton {
            id: headingButton
            objectName: "headingButton"
            label: "Aa"
            active: bar.lineStyle.heading > 0 || headingMenu.opened
            tooltip: qsTr("Title, Heading, Subheading, Body")
            onClicked: headingMenu.opened ? headingMenu.close() : headingMenu.open()
        }

        Item { width: Math.round(6 * bar.textScale); height: 1 }
        Divider {}
        Item { width: Math.round(6 * bar.textScale); height: 1 }

        FormatButton {
            objectName: "boldButton"
            label: "B"; bold: true
            active: bar.inStyle("**")
            tooltip: qsTr("Bold (Ctrl+B)")
            onClicked: bar.editor.wrapSelection("**")
        }
        FormatButton {
            objectName: "italicButton"
            label: "I"; italic: true
            active: bar.inStyle("*")
            tooltip: qsTr("Italic (Ctrl+I)")
            onClicked: bar.editor.wrapSelection("*")
        }
        FormatButton {
            objectName: "underlineButton"
            label: "U"; underline: true
            active: bar.inStyle("<u>")
            tooltip: qsTr("Underline (Ctrl+U)")
            onClicked: bar.editor.toggleUnderline()
        }
        FormatButton {
            objectName: "strikeButton"
            label: "S"; strikeout: true
            active: bar.inStyle("~~")
            tooltip: qsTr("Strikethrough (Ctrl+Shift+X)")
            onClicked: bar.editor.wrapSelection("~~")
        }

        Item { width: Math.round(6 * bar.textScale); height: 1 }
        Divider {}
        Item { width: Math.round(6 * bar.textScale); height: 1 }

        FormatButton {
            objectName: "bulletButton"
            iconName: "bullet"
            active: bar.lineStyle.list === "bullet"
            tooltip: qsTr("Bulleted List (Ctrl+Shift+8)")
            onClicked: bar.editor.toggleList("bullet")
        }
        FormatButton {
            objectName: "numberButton"
            iconName: "number"
            active: bar.lineStyle.list === "number"
            tooltip: qsTr("Numbered List (Ctrl+Shift+7)")
            onClicked: bar.editor.toggleList("number")
        }
        FormatButton {
            objectName: "checkButton"
            iconName: "check"
            active: bar.lineStyle.list === "check"
            tooltip: qsTr("Checklist (Ctrl+Shift+L)")
            onClicked: bar.editor.toggleList("check")
        }
    }

    // The app's name signed in the top right corner, in Great Vibes.
    Row {
        id: signature
        objectName: "signature"
        anchors.right: parent.right
        anchors.rightMargin: Math.round(18 * bar.textScale)
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: Math.round(1 * bar.textScale)

        Text {
            anchors.baseline: plusSign.baseline
            text: "Omawrite"
            color: bar.mutedColor
            font.family: "Great Vibes"
            font.pixelSize: Math.round(24 * bar.textScale)
        }
        Text {
            id: plusSign
            text: "+"
            color: bar.mutedColor
            font.family: "Great Vibes"
            font.pixelSize: Math.round(32 * bar.textScale)
        }
    }

    // Title, Heading, Subheading and Body, each shown in its own size.
    Popup {
        id: headingMenu
        objectName: "headingMenu"
        x: buttons.x
        y: bar.height
        padding: 4
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

        property int highlighted: 0

        onAboutToShow: {
            var current = bar.lineStyle.heading;
            highlighted = 3;
            for (var i = 0; i < bar.headingLevels.length; ++i) {
                if (bar.headingLevels[i].level === current)
                    highlighted = i;
            }
        }
        onClosed: if (bar.editor) bar.editor.forceActiveFocus()

        function choose(index) {
            var level = bar.headingLevels[index].level;
            close();
            bar.editor.setHeading(level);
        }

        background: Rectangle {
            color: bar.pageColor
            border.width: 1
            border.color: Qt.rgba(bar.textColor.r, bar.textColor.g, bar.textColor.b, 0.18)
        }

        contentItem: Column {
            focus: true
            Keys.onUpPressed: headingMenu.highlighted = Math.max(0, headingMenu.highlighted - 1)
            Keys.onDownPressed: headingMenu.highlighted
                = Math.min(bar.headingLevels.length - 1, headingMenu.highlighted + 1)
            Keys.onReturnPressed: headingMenu.choose(headingMenu.highlighted)
            Keys.onEnterPressed: headingMenu.choose(headingMenu.highlighted)

            Repeater {
                model: bar.headingLevels

                Rectangle {
                    required property var modelData
                    required property int index
                    width: Math.round(250 * bar.textScale)
                    height: Math.round(Math.max(30, 18 * modelData.scale + 14) * bar.textScale)
                    color: headingMenu.highlighted === index ? bar.activeFill : "transparent"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: Math.round(10 * bar.textScale)
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.name
                        color: bar.textColor
                        font.pixelSize: Math.round(15 * modelData.scale * bar.textScale)
                        font.bold: modelData.level > 0
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: Math.round(10 * bar.textScale)
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.keys
                        color: bar.mutedColor
                        font.pixelSize: Math.round(11 * bar.textScale)
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: headingMenu.highlighted = index
                        onClicked: headingMenu.choose(index)
                    }
                }
            }
        }
    }
}

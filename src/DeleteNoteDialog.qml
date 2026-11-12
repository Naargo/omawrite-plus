import QtQuick
import QtQuick.Controls

Dialog {
    id: root

    property string noteId: ""
    property string noteTitle: ""
    property bool darkMode: true
    property color textColor: darkMode ? "#d0d0d0" : "#42464c"
    property color strongTextColor: darkMode ? "#eeeeee" : "#222324"
    property color activeButtonColor: "#428bca"
    property int containerWidth: 420
    property int containerHeight: 320
    property real textScale: 1

    signal deleteRequested(string id)

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape

    // Cancel holds the focus, so a stray Enter keeps the note.
    onOpened: cancelButton.forceActiveFocus()
    width: Math.min(420, containerWidth - 48)
    x: Math.round((containerWidth - width) / 2)
    y: Math.round((containerHeight - height) / 2)
    padding: 20

    Shortcut {
        sequence: "Alt+C"
        enabled: root.opened
        onActivated: cancelButton.clicked()
    }

    Shortcut {
        sequence: "Alt+D"
        enabled: root.opened
        onActivated: deleteButton.clicked()
    }


    background: Rectangle {
        color: root.darkMode ? "#1a1a1a" : "#ffffff"
        border.color: root.darkMode ? "#343434" : "#d8d8d8"
        radius: 0
    }

    contentItem: Column {
        spacing: 12

        Label {
            text: qsTr("Delete note")
            color: root.strongTextColor
            font.family: "IBM Plex Mono"
            font.pixelSize: Math.round(16 * root.textScale)
            font.bold: true
        }

        Label {
            width: parent.width
            text: qsTr("Delete \u201c%1\u201d? This can't be undone.").arg(root.noteTitle)
            textFormat: Text.PlainText
            color: root.textColor
            wrapMode: Text.Wrap
            font.family: "IBM Plex Mono"
            font.pixelSize: Math.round(13 * root.textScale)
        }
    }

    footer: Item {
        implicitHeight: dialogButtons.implicitHeight + 20

        Row {
            id: dialogButtons
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            SquareDialogButton {
                id: cancelButton
                text: qsTr("Cancel")
                formattedText: qsTr("<u>C</u>ancel")
                darkMode: root.darkMode
                textScale: root.textScale
                labelColor: root.textColor
                KeyNavigation.left: deleteButton
                KeyNavigation.right: deleteButton
                KeyNavigation.tab: deleteButton
                KeyNavigation.backtab: deleteButton
                onClicked: root.reject()
            }

            SquareDialogButton {
                id: deleteButton
                text: qsTr("Delete")
                formattedText: qsTr("<u>D</u>elete")
                primary: true
                darkMode: root.darkMode
                textScale: root.textScale
                activeColor: root.activeButtonColor
                KeyNavigation.left: cancelButton
                KeyNavigation.right: cancelButton
                KeyNavigation.tab: cancelButton
                KeyNavigation.backtab: cancelButton
                onClicked: {
                    root.close();
                    root.deleteRequested(root.noteId);
                }
            }
        }
    }
}

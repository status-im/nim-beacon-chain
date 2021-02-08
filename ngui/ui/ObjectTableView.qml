import QtQuick 2.12
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.12

TableView {
    topMargin: columnsHeader.implicitHeight

    id: tableView
    Layout.fillHeight: true
    Layout.fillWidth: true
    clip: true

    columnWidthProvider: function (column) { return tableView.columns > 0 && tableView.width > 10 ? tableView.width / tableView.columns : 100; }
    rowHeightProvider: function (column) { return 30; }
    onWidthChanged: forceLayout()

    ScrollBar.horizontal: ScrollBar{}
    ScrollBar.vertical: ScrollBar{}

    delegate: Rectangle {
        clip: true
        TextEdit {
            anchors.fill: parent
            anchors.margins: 10

            text: display
            textFormat: TextEdit.RichText
            readOnly: true
            selectByMouse: true

            onLinkActivated: main.openUrl(link)
        }
    }

    Rectangle { // mask the headers
        z: 3
        color: "#222222"
        y: tableView.contentY
        x: tableView.contentX
        width: tableView.leftMargin
        height: tableView.topMargin
    }

    Row {
        id: columnsHeader
        y: tableView.contentY
        z: 2
        Repeater {
            model: tableView.columns > 0 ? tableView.columns : 1
            Label {
                property bool sortDirection
                width: tableView.columnWidthProvider(modelData)
                height: 35
                text: tableView.model.headerData(modelData, Qt.Horizontal)
                color: '#aaaaaa'
                font.pixelSize: 15
                padding: 10
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
                clip: true
                background: Rectangle { color: "#333333" }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        tableView.model.sort(modelData, sortDirection)
                        sortDirection = !sortDirection
                    }
                }
            }
        }
    }
}

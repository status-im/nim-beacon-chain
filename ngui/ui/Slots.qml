import QtQuick 2.12
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.12

ColumnLayout {
    property var viewData

    id: layout

    RowLayout {
        Layout.alignment: Qt.AlignHCenter
        spacing: 5
        Button {
            text: "Prev"
            onClicked: viewData.prev()
        }
        Text {
            text: "Epoch"
        }
        Text {
            text: viewData.epoch
        }

        Button {
            text: "Next"
            onClicked: viewData.next()
        }
    }

    ObjectTableView {
        model: viewData.slotList
        Layout.alignment: Qt.AlignHCenter

        columnWidthProvider: function (column) {
            if(column == 0) return 70;
            if(column == 1) return 70;
            return 450;
        }
    }
}

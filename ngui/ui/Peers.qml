import QtQuick 2.12
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.12

RowLayout {
    property var viewData

    id: layout

    ObjectTableView {
        Layout.fillHeight: true
        Layout.fillWidth: true

        id: tableView
        model: viewData
    }
}

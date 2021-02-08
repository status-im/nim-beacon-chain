import QtQuick 2.12
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.12

Rectangle {
    property var viewData

    ColumnLayout {
        anchors.fill: parent
        RowLayout {
            Label {
                text: "Root / slot"
            }
            TextField {
                selectByMouse: true
                id: urlTextField
                Layout.fillWidth: true
                text: "head"
            }
            Button {
                text: "Load"
                onClicked: main.onLoadState(urlTextField.text)
                enabled: urlTextField.text !== ""
            }
        }

        GridLayout {
            columns: 2

            Text {
                text: "Data"
            }
            TextEdit {
                text: viewData.state
                readOnly: true
                selectByMouse: true
            }
        }
    }
}

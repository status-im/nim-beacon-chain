import QtQuick 2.12
import QtQuick.Controls 2.3
import QtQuick.Layouts 1.12

ApplicationWindow {
    width: 1400
    height: 900
    title: "ngui"
    visible: true

    header: TabBar {
        id: tabBar

        currentIndex: main.currentIndex

        TabButton {
            text: "Slots"
            onClicked: main.updateSlots()
        }
        TabButton { text: "Blocks" }
        TabButton {
            text: "Peers"
            onClicked: main.updatePeers()
        }
        TabButton {
            text: "Node"
            onClicked: main.nodeModel.update()
        }
    }

    footer: RowLayout {
        Text { text: "Finalized" }
        Text { text: main.footer.finalized }

        Text { text: "Head" }
        Text { text: main.footer.head }

        Text { text: "Sync state" }
        Text { text: main.footer.syncing }

        Timer {
            interval: 1000
            running: true
            repeat: true
            onTriggered: main.updateFooter()
        }
    }

    StackLayout {
        anchors.fill: parent
        currentIndex: tabBar.currentIndex

        Slots { viewData: main.epochModel }
        Blocks { viewData: main.blck }
        Peers { viewData: main.peerList }
        Node { viewData: main.nodeModel }
    }
}

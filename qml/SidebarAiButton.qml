import QtQuick
import qs.Common
import qs.Services
import qs.Widgets.common

Item {
    id: root

    readonly property int baseSize: Sizes.barControlCircleSize
    readonly property int hoverSize: 34
    // Literal Chinese: the .qm catalogs ship inside the Clavis C++ plugin, so
    // a new qsTr() key cannot have a zh_CN entry.
    readonly property string label: "AI 用量"
    readonly property bool active: WidgetState.dashboardSidebarOpen && WidgetState.dashboardSidebarView
                                   === "ai"

    function toggleView() {
        if (root.active) {
            WidgetState.dashboardSidebarOpen = false;
            return;
        }
        WidgetState.dashboardSidebarView = "ai";
        WidgetState.dashboardSidebarOpen = true;
    }

    implicitWidth: root.baseSize
    implicitHeight: root.baseSize

    RippleButton {
        id: button

        anchors.centerIn: parent
        width: pointerHovered ? root.hoverSize : root.baseSize
        height: width
        buttonRadius: width / 2
        containerColor: Appearance.colors.colSecondaryContainer
        rippleColor: Appearance.colors.colOnSecondaryContainer
        stateLayerEnabled: false
        Accessible.name: root.label
        releaseAction: () => {
            return root.toggleView();
        }

        Behavior on width {
            NumberAnimation {
                duration: Appearance.animation.expressiveFastEffects.duration
                easing.type: Appearance.animation.expressiveFastEffects.type
                easing.bezierCurve: Appearance.animation.expressiveFastEffects.bezierCurve
            }
        }

        contentItem: Item {
            anchors.fill: parent

            Image {
                anchors.centerIn: parent
                width: button.pointerHovered ? 21 : 19
                height: width
                source: Qt.resolvedUrl("../../Sidebars/Dashboard/claude-logo.svg")
                sourceSize.width: 64
                sourceSize.height: 64
                fillMode: Image.PreserveAspectFit

                Behavior on width {
                    NumberAnimation {
                        duration: Appearance.animation.expressiveFastEffects.duration
                        easing.type: Appearance.animation.expressiveFastEffects.type
                        easing.bezierCurve: Appearance.animation.expressiveFastEffects.bezierCurve
                    }
                }
            }
        }
    }

    StyledToolTip {
        text: root.label
        extraVisibleCondition: button.pointerHovered
    }
}

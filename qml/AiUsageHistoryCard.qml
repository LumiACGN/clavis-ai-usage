import QtQuick
import QtQuick.Layouts
import qs.Common

// Daily token composition (stacked bars) and cache-hit-rate line for the
// "AI 用量" dashboard page.  Deliberately data-free: AiView hands it the
// already-sliced window of daily rows (oldest → newest) produced by
// ~/.local/bin/clavis-ai-usage, so no price or source logic lives in QML.
Item {
    id: root

    property var entries: []
    property bool foreground: false
    property real barHeight: 132
    property real rateHeight: 96

    readonly property int count: entries && entries.length ? entries.length : 0
    readonly property real slot: root.count > 0 ? width / root.count : width
    readonly property real barWidth: Math.max(4, Math.min(18, root.slot * 0.62))
    // Keep at most ~6 date labels no matter how many days are shown.
    readonly property int labelStep: Math.max(1, Math.ceil(root.count / 6))
    readonly property color hitColor: Appearance.colors.colPrimary
    readonly property color missColor: Appearance.colors.colTertiary
    readonly property color outColor: Appearance.colors.colSecondary
    readonly property color mutedColor: Appearance.colors.colOnLayer1
    readonly property color gridColor: Appearance.colors.colOutlineVariant
    // Headroom so the tallest bar never touches the top edge.
    readonly property real stackScale: {
        let maximum = 0;
        for (let index = 0; index < root.count; index += 1)
            maximum = Math.max(maximum, root.stackTotal(root.entries[index]));
        return Math.max(1, maximum * 1.12);
    }

    implicitHeight: column.implicitHeight

    function value(row, key) {
        const raw = row ? row[key] : 0;
        const number = Number(raw);
        return isFinite(number) ? number : 0;
    }

    function stackTotal(row) {
        return root.value(row, "cache_read") + root.value(row, "input_uncached") + root.value(row, "output");
    }

    function hitRate(row) {
        const rate = row ? row.hit_rate : null;
        if (rate === null || rate === undefined)
            return null;
        const number = Number(rate);
        return isFinite(number) ? number : null;
    }

    function pointX(index) {
        return index * root.slot + root.slot / 2;
    }

    function segmentColor(key) {
        if (key === "cache_read")
            return root.hitColor;
        if (key === "input_uncached")
            return root.missColor;
        return root.outColor;
    }

    function formatTokens(value) {
        const count = Number(value) || 0;
        if (count >= 1e9)
            return (count / 1e9).toFixed(2) + "B";
        if (count >= 1e6)
            return (count / 1e6).toFixed(1) + "M";
        if (count >= 1e3)
            return (count / 1e3).toFixed(1) + "K";
        return String(Math.round(count));
    }

    function alpha(color, opacity) {
        return Qt.rgba(color.r, color.g, color.b, opacity);
    }

    // Only the top of the stack is rounded — a full roundedRect would turn
    // every segment into a bead.
    function shapeTopRounded(ctx, centerX, topY, bottomY, width) {
        const height = Math.max(2, bottomY - topY);
        const radius = Math.min(width / 2, height);
        const left = centerX - width / 2;
        ctx.beginPath();
        ctx.moveTo(left, topY + height);
        ctx.lineTo(left, topY + radius);
        ctx.arcTo(left, topY, left + radius, topY, radius);
        ctx.lineTo(left + width - radius, topY);
        ctx.arcTo(left + width, topY, left + width, topY + radius, radius);
        ctx.lineTo(left + width, topY + height);
        ctx.closePath();
        ctx.fill();
    }

    function repaint() {
        barCanvas.requestPaint();
        rateCanvas.requestPaint();
    }

    onEntriesChanged: root.repaint()
    onForegroundChanged: root.repaint()
    onWidthChanged: root.repaint()
    Component.onCompleted: root.repaint()

    ColumnLayout {
        id: column

        width: parent.width
        spacing: Metrics.spacingXS

        RowLayout {
            Layout.fillWidth: true
            spacing: Metrics.spacingM

            Repeater {
                model: [
                    {
                        "label": qsTr("缓存命中"),
                        "color": root.hitColor
                    },
                    {
                        "label": qsTr("未命中"),
                        "color": root.missColor
                    },
                    {
                        "label": qsTr("输出"),
                        "color": root.outColor
                    }
                ]

                RowLayout {
                    required property var modelData

                    spacing: Metrics.spacingXXS

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        implicitWidth: 8
                        implicitHeight: 8
                        radius: 2
                        color: modelData.color
                    }

                    Text {
                        Layout.alignment: Qt.AlignVCenter
                        text: modelData.label
                        color: root.mutedColor
                        font.family: Typography.labelSmall.family
                        font.pixelSize: Typography.labelSmall.pixelSize
                    }
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: root.barHeight

            Canvas {
                id: barCanvas

                width: parent.width
                height: root.barHeight - 18

                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    ctx.clearRect(0, 0, width, height);
                    if (!root.foreground || root.count === 0)
                        return;
                    // 16px of headroom keeps the scale label clear of the bars.
                    const top = 16;
                    const bottom = height - 4;
                    ctx.lineWidth = 1;
                    ctx.strokeStyle = root.alpha(root.gridColor, 0.35);
                    for (let guide = 0; guide <= 2; guide += 1) {
                        const y = bottom - (bottom - top) * guide / 2;
                        ctx.beginPath();
                        ctx.moveTo(0, y);
                        ctx.lineTo(width, y);
                        ctx.stroke();
                    }
                    const keys = ["cache_read", "input_uncached", "output"];
                    for (let index = 0; index < root.count; index += 1) {
                        const row = root.entries[index];
                        const parts = [];
                        for (let k = 0; k < keys.length; k += 1) {
                            const v = root.value(row, keys[k]);
                            if (v > 0)
                                parts.push({
                                    "key": keys[k],
                                    "value": v
                                });
                        }
                        if (parts.length === 0)
                            continue;
                        let cursor = bottom;
                        for (let p = 0; p < parts.length; p += 1) {
                            // 2px floor keeps a tiny output slice visible.
                            const sliceHeight = Math.max(2, parts[p].value / root.stackScale * (bottom - top));
                            const segmentTop = Math.max(top, cursor - sliceHeight - (p < parts.length - 1 ? 1 : 0));
                            ctx.fillStyle = root.segmentColor(parts[p].key);
                            if (p === parts.length - 1)
                                root.shapeTopRounded(ctx, root.pointX(index), segmentTop, cursor, root.barWidth);
                            else
                                ctx.fillRect(root.pointX(index) - root.barWidth / 2, segmentTop, root.barWidth,
                                             cursor - segmentTop);
                            cursor = segmentTop;
                        }
                    }
                    ctx.fillStyle = root.alpha(root.mutedColor, 0.9);
                    ctx.font = "600 11px " + Fonts.cssFamily(Fonts.numeric);
                    ctx.textAlign = "left";
                    ctx.fillText(root.formatTokens(root.stackScale / 1.12), 2, 11);
                }
            }

            Repeater {
                model: root.count

                Text {
                    required property int index

                    x: index * root.slot
                    y: barCanvas.height + 4
                    width: root.slot
                    text: (root.count - 1 - index) % root.labelStep === 0
                          && root.entries[index] ? String(root.entries[index].date || "").slice(5) : ""
                    color: root.mutedColor
                    font.family: Typography.labelSmall.family
                    font.pixelSize: Typography.labelSmall.pixelSize
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Metrics.spacingXS

            Text {
                Layout.fillWidth: true
                text: qsTr("缓存命中率")
                color: Appearance.colors.colOnSurface
                font.family: Typography.labelLarge.family
                font.pixelSize: Typography.labelLarge.pixelSize
            }

            Text {
                text: qsTr("虚线 90%")
                color: root.mutedColor
                font.family: Typography.labelSmall.family
                font.pixelSize: Typography.labelSmall.pixelSize
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: root.rateHeight

            Canvas {
                id: rateCanvas

                anchors.fill: parent

                // Left gutter for the 0/50/100% scale so labels never sit on
                // the gridlines or the 90% reference dashes.
                readonly property real plotLeft: 30
                readonly property real plotTop: 6
                readonly property real plotBottom: height - 6
                readonly property real plotSlot: root.count > 0 ? (width - plotLeft) / root.count : width

                function rateY(rate) {
                    const clamped = Math.max(0, Math.min(100, rate));
                    return plotTop + (1 - clamped / 100) * (plotBottom - plotTop);
                }

                function rateX(index) {
                    return plotLeft + index * plotSlot + plotSlot / 2;
                }

                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    ctx.clearRect(0, 0, width, height);
                    if (!root.foreground || root.count === 0)
                        return;
                    ctx.lineWidth = 1;
                    ctx.strokeStyle = root.alpha(root.gridColor, 0.35);
                    ctx.fillStyle = root.alpha(root.mutedColor, 0.9);
                    ctx.font = "600 11px " + Fonts.cssFamily(Fonts.numeric);
                    ctx.textAlign = "left";
                    const guides = [0, 50, 100];
                    for (let g = 0; g < guides.length; g += 1) {
                        const y = rateY(guides[g]);
                        ctx.beginPath();
                        ctx.moveTo(plotLeft, y);
                        ctx.lineTo(width, y);
                        ctx.stroke();
                        ctx.fillText(guides[g] + "%", 2, y + 4);
                    }
                    ctx.setLineDash([4, 4]);
                    ctx.strokeStyle = root.alpha(root.missColor, 0.8);
                    const referenceY = rateY(90);
                    ctx.beginPath();
                    ctx.moveTo(plotLeft, referenceY);
                    ctx.lineTo(width, referenceY);
                    ctx.stroke();
                    ctx.setLineDash([]);
                    const points = [];
                    for (let index = 0; index < root.count; index += 1) {
                        const rate = root.hitRate(root.entries[index]);
                        if (rate === null) {
                            points.push(null);
                            continue;
                        }
                        points.push({
                            "x": rateX(index),
                            "y": rateY(rate)
                        });
                    }
                    ctx.strokeStyle = root.hitColor;
                    ctx.lineWidth = 2;
                    ctx.lineJoin = "round";
                    ctx.lineCap = "round";
                    ctx.beginPath();
                    let drawing = false;
                    for (let index = 0; index < points.length; index += 1) {
                        const point = points[index];
                        // Day with no prompt tokens: break the line instead of
                        // pretending the rate dropped to zero.
                        if (point === null) {
                            drawing = false;
                            continue;
                        }
                        if (drawing)
                            ctx.lineTo(point.x, point.y);
                        else
                            ctx.moveTo(point.x, point.y);
                        drawing = true;
                    }
                    ctx.stroke();
                    ctx.fillStyle = root.hitColor;
                    for (let index = 0; index < points.length; index += 1) {
                        if (points[index] === null)
                            continue;
                        ctx.beginPath();
                        ctx.arc(points[index].x, points[index].y, 2.5, 0, Math.PI * 2);
                        ctx.fill();
                    }
                }
            }
        }
    }
}

import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Components
import qs.Services
import qs.Widgets.common
import qs.Modules.SystemCards
import "./drawer"

// Full-page AI usage dashboard: provider balances/quotas, local Claude Code
// usage with a 14-day trend, and data-source status.  All data comes from the
// AiUsageService singleton, which runs ~/.local/bin/clavis-ai-usage.
Item {
    id: root

    property bool foreground: false
    // Drives re-evaluation of relative time labels once a minute.
    property int tick: 0

    readonly property var service: AiUsageService
    readonly property var providers: root.service.providers
    readonly property var local: root.service.localUsage
    readonly property bool localReady: root.local !== null && String(root.local.status || "") === "ready"
    // Not service.hasData: that only counts providers and would hide the
    // page when only the local ccusage data is available.
    readonly property bool hasAnyData: root.providers.length > 0 || root.localReady
    readonly property bool failed: !root.hasAnyData && !root.service.busy && root.service.status === "error"
    readonly property bool waiting: !root.hasAnyData && !root.failed
    // Real spend today in CNY, derived from the balance-provider delta (the
    // balance is the source of truth); -1 when no balance is available yet.
    readonly property real spendToday: root.localReady && root.local.today_spend_cny !== null
                                       && root.local.today_spend_cny !== undefined
                                       ? Number(root.local.today_spend_cny) : -1
    readonly property bool spendTopup: root.localReady && root.local.spend_topup === true
    readonly property var history: root.localReady && Array.isArray(root.local.history) ? root.local.history : []
    // Window selected in the 历史用量 section (7 / 14 / 30 days).
    property int historyRange: 14
    readonly property var historyWindow: root.history.slice(Math.max(0, root.history.length - root.historyRange))
    // Only days that actually carry usage, newest first — the chart above
    // keeps the empty days so the time axis stays honest.
    readonly property var historyDetail: root.historyWindow.filter(entry => (Number(entry.tokens) || 0) > 0).slice().reverse()
    readonly property int historyActiveDays: root.localReady ? Number(root.local.history_active_days) || 0 : 0
    readonly property var pricing: root.localReady && root.local.pricing ? root.local.pricing : null
    readonly property var official: root.localReady && root.local.official ? root.local.official : null
    readonly property color hitBarColor: Appearance.colors.colPrimary
    readonly property color missBarColor: Appearance.colors.colTertiary
    readonly property color outBarColor: Appearance.colors.colSecondary
    readonly property var staleSources: Array.isArray(root.service.payload.stale_sources)
                                        ? root.service.payload.stale_sources : []
    readonly property color mutedColor: Appearance.colors.colOnLayer1
    readonly property color trackColor: Appearance.colors.colOutlineVariant

    // Providers with a real brand mark render an SVG asset instead of a glyph.
    function providerLogoSource(entry) {
        return String(entry.id || "") === "deepseek" ? Qt.resolvedUrl("deepseek-logo.svg") : "";
    }

    function providerIcon(entry) {
        switch (String(entry.id || "")) {
        case "deepseek":
            return "neurology";
        case "openrouter":
            return "route";
        case "zai":
        case "glm":
            return "auto_awesome";
        case "kimi":
        case "moonshot":
            return "psychology";
        default:
            return String(entry.id || "").indexOf("relay") === 0 ? "dns" : "insights";
        }
    }

    function severityColor(entry) {
        const text = String(entry.severity || "").toLowerCase();
        if (text.indexOf("crit") >= 0 || text.indexOf("high") >= 0 || text.indexOf("error") >= 0
                || text.indexOf("danger") >= 0)
            return Appearance.colors.colError;
        const percent = Number(entry.percent);
        if (isFinite(percent) && percent >= 85)
            return Appearance.colors.colError;
        if (text.indexOf("warn") >= 0 || text.indexOf("medium") >= 0)
            return Appearance.colors.colTertiary;
        if (isFinite(percent) && percent >= 65)
            return Appearance.colors.colTertiary;
        return Appearance.colors.colPrimary;
    }

    function barFraction(entry) {
        const percent = Number(entry.percent);
        return isFinite(percent) && percent >= 0 ? Math.max(0, Math.min(1, percent / 100)) : -1;
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

    function formatMinutes(value) {
        const minutes = Math.max(0, Math.round(Number(value) || 0));
        return minutes >= 60 ? Math.floor(minutes / 60) + "h" + ("0" + (minutes % 60)).slice(-2) + "m" : minutes + "m";
    }

    function entryDetail(entry) {
        const parts = [];
        if (entry.stale === true)
            parts.push(qsTr("缓存数据"));
        if (String(entry.detail || "") !== "")
            parts.push(String(entry.detail));
        return parts.join(" · ");
    }

    function generatedAtMs() {
        const seconds = Number(root.service.payload.generated_at);
        return seconds > 0 ? seconds * 1000 : 0;
    }

    function relativeAgeText(milliseconds) {
        root.tick;
        const minutes = Math.max(0, Math.round((Date.now() - milliseconds) / 60000));
        if (minutes <= 0)
            return qsTr("刚刚");
        if (minutes < 60)
            return qsTr("%1 分钟前").arg(minutes);
        if (minutes < 1440)
            return qsTr("%1 小时前").arg(Math.floor(minutes / 60));
        return qsTr("%1 天前").arg(Math.floor(minutes / 1440));
    }

    function lastUpdatedText() {
        const milliseconds = root.generatedAtMs();
        if (!(milliseconds > 0))
            return qsTr("尚未获取到数据");
        return qsTr("%1 更新 · %2").arg(UiPreferences.shortTime(new Date(milliseconds))).arg(
            root.relativeAgeText(milliseconds));
    }

    // Prefer a locally computed countdown (the script's reset_text goes stale
    // between its own refreshes); fall back to the script text when reset_at
    // is unavailable.
    function resetCountdown(entry) {
        root.tick;
        const at = Number(entry.reset_at);
        if (isFinite(at) && at > 0) {
            const left = at - Math.floor(Date.now() / 1000);
            if (left > 0)
                return qsTr("%1 后重置").arg(root.formatMinutes(Math.ceil(left / 60)));
        }
        return String(entry.reset_text || "");
    }

    function blockRemainingText() {
        root.tick;
        if (!root.localReady)
            return "";
        return qsTr("剩余 %1").arg(root.formatMinutes(root.local.block_remaining_min));
    }

    function blockRateText() {
        if (!root.localReady)
            return "—";
        const perMinute = Number(root.local.block_tokens_per_min) || 0;
        return perMinute > 0 ? root.formatTokens(perMinute) + "/min" : "—";
    }

    function blockProjectionText() {
        if (!root.localReady || root.local.block_active !== true)
            return "";
        const tokens = Number(root.local.block_projection_tokens) || 0;
        if (tokens <= 0)
            return "";
        return qsTr("按当前速率本块预计 ~%1 tok").arg(root.formatTokens(tokens));
    }

    // ------------------------------------------------- 历史用量 helpers
    // Every CNY figure below is derived (and pre-priced) by the data script
    // from the configured price table; the page only sums the slice it shows.
    function sumWindow(key) {
        let total = 0;
        for (let index = 0; index < root.historyWindow.length; index += 1) {
            const value = Number(root.historyWindow[index][key]);
            if (isFinite(value))
                total += value;
        }
        return total;
    }

    function countableDays() {
        let days = 0;
        for (let index = 0; index < root.historyWindow.length; index += 1) {
            if ((Number(root.historyWindow[index].tokens) || 0) > 0)
                days += 1;
        }
        return days;
    }

    function percentText(value) {
        if (value === null || value === undefined || !isFinite(Number(value)))
            return "—";
        return Number(value).toFixed(1) + "%";
    }

    function moneyText(value) {
        if (value === null || value === undefined || !isFinite(Number(value)))
            return "—";
        return "¥" + Number(value).toFixed(2);
    }

    function daysLeftText() {
        if (!root.localReady)
            return "—";
        const left = Number(root.local.balance_days_left);
        if (!isFinite(left) || left <= 0)
            return "—";
        if (left > 365)
            return qsTr("> 365 天");
        if (left < 1)
            return qsTr("< 1 天");
        return qsTr("~%1 天").arg(Math.round(left));
    }

    function balanceSupportText() {
        if (!root.localReady)
            return "";
        const balance = Number(root.local.balance_cny);
        const average = Number(root.local.avg_daily_cny);
        const parts = [];
        if (isFinite(balance))
            parts.push(qsTr("余额 ¥%1").arg(balance.toFixed(2)));
        if (isFinite(average) && average > 0)
            parts.push(qsTr("日均 ¥%1").arg(average.toFixed(2)));
        return parts.join(" · ");
    }

    function priceNoteText() {
        if (!root.pricing || !root.pricing.off_peak)
            return "";
        const offPeak = root.pricing.off_peak;
        const hasOfficial = root.official !== null && root.official.enabled === true;
        const sourceLine = hasOfficial ? qsTr("口径：有官方账单数据的日子，token / 命中率 / 金额都用官方值（官方按 UTC 日界，与本地日志的北京时间差 8 小时）；其余日子用本地 ccusage 日志（含子代理重复计数，token 偏高）。") :
                                         qsTr("口径：本地 ccusage 日志（token 数比账单口径偏大）。");
        return sourceLine + "\n" + qsTr("费用优先级 官方 > 余额实扣 > 价目表估算；价目表（谷时）命中 ¥%1/M · 未命中 ¥%2/M · 输出 ¥%3/M，峰时 ×%4。").arg(
                   offPeak.cache_hit).arg(offPeak.cache_miss).arg(offPeak.output).arg(
                   root.pricing.peak_multiplier);
    }

    function todayHitSupportText() {
        const row = root.localReady && root.local.today ? root.local.today : null;
        if (!row)
            return "";
        return qsTr("命中 %1 · 未命中 %2").arg(root.formatTokens(row.cache_read)).arg(
            root.formatTokens(row.input_uncached));
    }

    function dayLabel(date) {
        const text = String(date || "");
        if (text.length < 10)
            return text;
        const parsed = new Date(text + "T00:00:00");
        if (isNaN(parsed.getTime()))
            return text;
        const weekdays = ["日", "一", "二", "三", "四", "五", "六"];
        return text.slice(5) + " 周" + weekdays[parsed.getDay()];
    }

    function costSourceLabel(row) {
        switch (String(row && row.cost_source || "")) {
        case "official":
            return qsTr("官方");
        case "spend":
            return qsTr("实扣");
        case "estimate":
            return qsTr("估算");
        default:
            return "";
        }
    }

    function costText(row) {
        if (!row)
            return "—";
        if (row.cost_display_cny === null || row.cost_display_cny === undefined)
            return row.spend_topup === true ? qsTr("当日充值") : "—";
        const label = root.costSourceLabel(row);
        const amount = root.moneyText(row.cost_display_cny);
        return label.length > 0 ? amount + " " + label : amount;
    }

    function officialStatusText() {
        const entry = root.official;
        if (!entry || entry.enabled !== true)
            return qsTr("未启用");
        const status = String(entry.status || "");
        if (status === "ready")
            return qsTr("官方口径 · %1 天").arg(Number(entry.days) || 0);
        if (status === "stale")
            return qsTr("缓存数据 · %1").arg(String(entry.error || ""));
        return String(entry.error || qsTr("不可用"));
    }

    function officialStatusColor() {
        const entry = root.official;
        if (!entry || entry.enabled !== true)
            return root.mutedColor;
        return String(entry.status || "") === "ready" ? Appearance.colors.colPrimary :
                                                        Appearance.colors.colError;
    }

    Accessible.name: qsTr("AI 用量")

    onForegroundChanged: {
        if (root.foreground)
            root.service.requestRefresh(60000);
    }

    Timer {
        interval: 60000
        repeat: true
        running: root.foreground
        onTriggered: root.tick += 1
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Metrics.spacingM
        visible: root.hasAnyData

        RowLayout {
            Layout.fillWidth: true
            spacing: Metrics.spacingS

            Image {
                // Official Claude mark (Simple Icons, CC0; brand colour baked in).
                Layout.preferredWidth: Metrics.iconL
                Layout.preferredHeight: Metrics.iconL
                source: Qt.resolvedUrl("claude-logo.svg")
                sourceSize.width: 64
                sourceSize.height: 64
                fillMode: Image.PreserveAspectFit
            }

            Text {
                Layout.fillWidth: true
                text: qsTr("AI 用量")
                color: Appearance.colors.colOnSurface
                font.family: Typography.titleLarge.family
                font.pixelSize: Typography.titleLarge.pixelSize
                font.weight: Typography.titleLarge.weight
                elide: Text.ElideRight
            }

            InlineBusyIndicator {
                Layout.alignment: Qt.AlignVCenter
                busy: root.service.busy
                spinnerColor: Appearance.colors.colPrimary
            }

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                iconName: "refresh"
                variant: "tonal"
                controlSize: Metrics.controlHeightM
                iconSize: Metrics.iconM
                enabled: !root.service.busy
                accessibleName: qsTr("刷新 AI 用量")
                onClicked: root.service.refresh()
            }
        }

        StyledFlickable {
            id: flick

            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: body.implicitHeight + Metrics.spacingS

            ColumnLayout {
                id: body

                width: flick.width - Metrics.spacingS
                spacing: Metrics.spacingL

                InlineStatusBanner {
                    Layout.fillWidth: true
                    visible: root.service.status === "error"
                    tone: "error"
                    message: root.service.errorMessage.length > 0 ? root.service.errorMessage :
                                                                    qsTr("刷新失败，显示上次成功的数据")
                }

                InlineStatusBanner {
                    Layout.fillWidth: true
                    visible: String(root.service.payload.error || "") !== ""
                    tone: "warning"
                    message: String(root.service.payload.error || "")
                }

                Text {
                    Layout.fillWidth: true
                    text: root.lastUpdatedText()
                    color: root.mutedColor
                    font.family: Typography.labelSmall.family
                    font.pixelSize: Typography.labelSmall.pixelSize
                    elide: Text.ElideRight
                }

                SettingsSection {
                    Layout.fillWidth: true
                    title: qsTr("供应商")
                    iconName: "neurology"

                    Repeater {
                        model: root.providers.length

                        ColumnLayout {
                            id: providerRow

                            required property int index

                            readonly property var entry: root.providers[providerRow.index] || ({})

                            Layout.fillWidth: true
                            spacing: Metrics.spacingXXS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Metrics.spacingXS

                                Item {
                                    Layout.preferredWidth: Metrics.iconM
                                    Layout.preferredHeight: Metrics.iconM

                                    MaterialSymbol {
                                        anchors.fill: parent
                                        visible: root.providerLogoSource(providerRow.entry) === ""
                                        text: root.providerIcon(providerRow.entry)
                                        iconSize: Metrics.iconM
                                        color: root.severityColor(providerRow.entry)
                                    }

                                    Image {
                                        anchors.fill: parent
                                        visible: root.providerLogoSource(providerRow.entry) !== ""
                                        source: root.providerLogoSource(providerRow.entry)
                                        sourceSize.width: 48
                                        sourceSize.height: 48
                                        fillMode: Image.PreserveAspectFit
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    Text {
                                        Layout.fillWidth: true
                                        text: String(providerRow.entry.name || providerRow.entry.id || "")
                                        color: Appearance.colors.colOnSurface
                                        font.family: Typography.labelLarge.family
                                        font.pixelSize: Typography.labelLarge.pixelSize
                                        font.weight: Typography.labelLarge.weight
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: String(providerRow.entry.plan || "").length > 0
                                        text: String(providerRow.entry.plan || "")
                                        color: root.mutedColor
                                        font.family: Typography.labelSmall.family
                                        font.pixelSize: Typography.labelSmall.pixelSize
                                        elide: Text.ElideRight
                                    }
                                }

                                Text {
                                    text: String(providerRow.entry.display || (providerRow.entry.status === "error"
                                                                               ? qsTr("不可用") : "—"))
                                    color: providerRow.entry.status === "error" ? root.mutedColor :
                                                                                  Appearance.colors.colOnSurface
                                    font.family: Typography.titleMedium.family
                                    font.pixelSize: Typography.titleMedium.pixelSize
                                    font.weight: Typography.titleMedium.weight
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: Metrics.spacingS
                                radius: height / 2
                                color: root.trackColor
                                visible: root.barFraction(providerRow.entry) >= 0

                                Rectangle {
                                    width: parent.width * Math.max(0, root.barFraction(providerRow.entry))
                                    height: parent.height
                                    radius: parent.radius
                                    color: root.severityColor(providerRow.entry)

                                    Behavior on width {
                                        NumberAnimation {
                                            duration: Appearance.animation.expressiveSlowSpatial.duration
                                            easing.type: Appearance.animation.expressiveSlowSpatial.type
                                            easing.bezierCurve: Appearance.animation.expressiveSlowSpatial.bezierCurve
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true

                                Text {
                                    Layout.fillWidth: true
                                    text: root.entryDetail(providerRow.entry)
                                    color: root.mutedColor
                                    font.family: Typography.labelSmall.family
                                    font.pixelSize: Typography.labelSmall.pixelSize
                                    elide: Text.ElideRight
                                }

                                Text {
                                    text: root.resetCountdown(providerRow.entry)
                                    color: root.mutedColor
                                    font.family: Typography.labelSmall.family
                                    font.pixelSize: Typography.labelSmall.pixelSize
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: String(providerRow.entry.error || "") !== ""
                                text: String(providerRow.entry.error || "")
                                color: Appearance.colors.colError
                                font.family: Typography.bodySmall.family
                                font.pixelSize: Typography.bodySmall.pixelSize
                                wrapMode: Text.Wrap
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: Metrics.dividerWidth
                                color: root.trackColor
                                visible: providerRow.index < root.providers.length - 1
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.providers.length === 0
                        text: qsTr("未配置供应商（可在 ~/.config/clavis/ai-usage.json 与 ~/.config/ai-usagebar/config.toml 中配置）")
                        color: root.mutedColor
                        font.family: Typography.bodySmall.family
                        font.pixelSize: Typography.bodySmall.pixelSize
                        wrapMode: Text.Wrap
                    }
                }

                SettingsSection {
                    Layout.fillWidth: true
                    title: qsTr("Claude Code")
                    iconName: "terminal"
                    supportingText: root.localReady ? "" : qsTr("本地日志不可用（ccusage 未安装或未产生日志）")

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.spacingS

                        StatTile {
                            Layout.fillWidth: true
                            label: qsTr("今日 tokens")
                            value: root.localReady ? root.formatTokens(root.local.today_tokens) : "—"
                        }

                        StatTile {
                            Layout.fillWidth: true
                            label: qsTr("今日消耗")
                            value: root.spendToday >= 0 ? "¥" + root.spendToday.toFixed(2) : "—"
                            supporting: root.spendTopup ? qsTr("期间有充值，消耗或偏低") : ""
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: blockColumn.implicitHeight + Metrics.cardPadding * 2
                        radius: Metrics.cornerM
                        color: Appearance.colors.colLayer2

                        ColumnLayout {
                            id: blockColumn

                            anchors.fill: parent
                            anchors.margins: Metrics.cardPadding
                            spacing: Metrics.spacingXS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Metrics.spacingXS

                                MaterialSymbol {
                                    text: "schedule"
                                    iconSize: Metrics.iconS
                                    color: root.mutedColor
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: root.localReady && root.local.block_active === true ? qsTr(
                                                                                                   "当前 5h 块") : qsTr(
                                                                                                   "当前无活跃 5h 块")
                                    color: Appearance.colors.colOnSurface
                                    font.family: Typography.labelLarge.family
                                    font.pixelSize: Typography.labelLarge.pixelSize
                                }

                                Text {
                                    visible: root.localReady && root.local.block_active === true
                                    text: root.blockRemainingText()
                                    color: root.mutedColor
                                    font.family: Typography.labelMedium.family
                                    font.pixelSize: Typography.labelMedium.pixelSize
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Metrics.spacingL
                                visible: root.localReady && root.local.block_active === true

                                BlockStat {
                                    Layout.fillWidth: true
                                    label: qsTr("tokens")
                                    value: root.localReady ? root.formatTokens(root.local.block_tokens) : "—"
                                }

                                BlockStat {
                                    Layout.fillWidth: true
                                    label: qsTr("速率")
                                    value: root.blockRateText()
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: root.blockProjectionText() !== ""
                                text: root.blockProjectionText()
                                color: root.mutedColor
                                font.family: Typography.labelSmall.family
                                font.pixelSize: Typography.labelSmall.pixelSize
                                elide: Text.ElideRight
                            }
                        }
                    }
                }

                SettingsSection {
                    Layout.fillWidth: true
                    title: qsTr("历史用量")
                    iconName: "insights"
                    supportingText: root.historyActiveDays === 0 ? qsTr("暂无历史数据（ccusage 未读到本地日志）") : ""

                    StyledButtonGroup {
                        Layout.fillWidth: true
                        currentValue: root.historyRange
                        model: [
                            {
                                "value": 7,
                                "label": qsTr("7 天")
                            },
                            {
                                "value": 14,
                                "label": qsTr("14 天")
                            },
                            {
                                "value": 30,
                                "label": qsTr("30 天")
                            }
                        ]
                        onValueSelected: (value, modelData) => root.historyRange = Number(value)
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.spacingS

                        StatTile {
                            Layout.fillWidth: true
                            label: qsTr("今日缓存命中率")
                            value: root.localReady && root.local.today ? root.percentText(root.local.today.hit_rate) : "—"
                            supporting: root.todayHitSupportText()
                        }

                        StatTile {
                            Layout.fillWidth: true
                            label: qsTr("近 %1 天 tokens").arg(root.historyRange)
                            value: root.formatTokens(root.sumWindow("tokens"))
                            supporting: root.countableDays() > 0 ? qsTr("日均 %1 · 活跃 %2 天").arg(
                                                                       root.formatTokens(
                                                                           root.sumWindow("tokens") / root.countableDays())).arg(
                                                                       root.countableDays()) : ""
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.spacingS

                        StatTile {
                            Layout.fillWidth: true
                            label: qsTr("缓存少花")
                            value: root.moneyText(root.sumWindow("cache_savings_cny"))
                            supporting: qsTr("按价目表估算")
                        }

                        StatTile {
                            Layout.fillWidth: true
                            label: qsTr("余额可用")
                            value: root.daysLeftText()
                            supporting: root.balanceSupportText()
                        }
                    }

                    AiUsageHistoryCard {
                        Layout.fillWidth: true
                        visible: root.historyActiveDays > 0
                        entries: root.historyWindow
                        foreground: root.foreground
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Metrics.spacingS
                        visible: root.historyDetail.length > 0

                        MaterialSymbol {
                            text: "monitoring"
                            iconSize: Metrics.iconS
                            color: root.mutedColor
                        }

                        Text {
                            Layout.fillWidth: true
                            text: qsTr("每日明细")
                            color: Appearance.colors.colOnSurface
                            font.family: Typography.labelLarge.family
                            font.pixelSize: Typography.labelLarge.pixelSize
                        }

                        Text {
                            text: qsTr("共 %1 天有用量").arg(root.historyDetail.length)
                            color: root.mutedColor
                            font.family: Typography.labelSmall.family
                            font.pixelSize: Typography.labelSmall.pixelSize
                        }
                    }

                    Repeater {
                        model: root.historyDetail

                        ColumnLayout {
                            id: dayRow

                            required property var modelData

                            Layout.fillWidth: true
                            spacing: Metrics.spacingXXS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Metrics.spacingXS

                                Text {
                                    text: root.dayLabel(dayRow.modelData.date)
                                    color: Appearance.colors.colOnSurface
                                    font.family: Typography.labelLarge.family
                                    font.pixelSize: Typography.labelLarge.pixelSize
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: root.formatTokens(dayRow.modelData.tokens) + " tok · " + qsTr("命中率 %1").arg(
                                              root.percentText(dayRow.modelData.hit_rate))
                                    color: root.mutedColor
                                    font.family: Typography.labelSmall.family
                                    font.pixelSize: Typography.labelSmall.pixelSize
                                    elide: Text.ElideRight
                                }

                                Text {
                                    text: root.costText(dayRow.modelData)
                                    color: root.mutedColor
                                    font.family: Typography.labelMedium.family
                                    font.pixelSize: Typography.labelMedium.pixelSize
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Metrics.spacingXS

                                SplitBar {
                                    Layout.alignment: Qt.AlignVCenter
                                    hit: Number(dayRow.modelData.cache_read) || 0
                                    miss: Number(dayRow.modelData.input_uncached) || 0
                                    output: Number(dayRow.modelData.output) || 0
                                }

                                // 三个 token 数依次是 命中 / 未命中 / 输出，顺序与左侧
                                // 分色条（以及上图图例）的颜色一致；标签本身也按该配色着色。
                                SplitStat {
                                    Layout.alignment: Qt.AlignVCenter
                                    label: qsTr("命中")
                                    value: root.formatTokens(dayRow.modelData.cache_read)
                                    tone: root.hitBarColor
                                }

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: "·"
                                    color: root.mutedColor
                                    font.family: Typography.labelSmall.family
                                    font.pixelSize: Typography.labelSmall.pixelSize
                                }

                                SplitStat {
                                    Layout.alignment: Qt.AlignVCenter
                                    label: qsTr("未命中")
                                    value: root.formatTokens(dayRow.modelData.input_uncached)
                                    tone: root.missBarColor
                                }

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: "·"
                                    color: root.mutedColor
                                    font.family: Typography.labelSmall.family
                                    font.pixelSize: Typography.labelSmall.pixelSize
                                }

                                SplitStat {
                                    Layout.alignment: Qt.AlignVCenter
                                    label: qsTr("输出")
                                    value: root.formatTokens(dayRow.modelData.output)
                                    tone: root.outBarColor
                                }

                                Item {
                                    Layout.fillWidth: true
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: Metrics.dividerWidth
                                color: root.trackColor
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.historyActiveDays === 0
                        text: qsTr("历史从今天起累积；ccusage 只能回填本地日志保留期内的数据。")
                        color: root.mutedColor
                        font.family: Typography.bodySmall.family
                        font.pixelSize: Typography.bodySmall.pixelSize
                        wrapMode: Text.Wrap
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: root.priceNoteText() !== ""
                        text: root.priceNoteText()
                        color: root.mutedColor
                        font.family: Typography.labelSmall.family
                        font.pixelSize: Typography.labelSmall.pixelSize
                        wrapMode: Text.Wrap
                    }
                }

                SettingsSection {
                    Layout.fillWidth: true
                    title: qsTr("数据源")
                    iconName: "sync"

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.spacingXS

                        MaterialSymbol {
                            text: "schedule"
                            iconSize: Metrics.iconS
                            color: root.mutedColor
                        }

                        Text {
                            Layout.fillWidth: true
                            text: qsTr("上次更新")
                            color: Appearance.colors.colOnSurface
                            font.family: Typography.labelLarge.family
                            font.pixelSize: Typography.labelLarge.pixelSize
                        }

                        Text {
                            text: root.lastUpdatedText()
                            color: root.mutedColor
                            font.family: Typography.labelSmall.family
                            font.pixelSize: Typography.labelSmall.pixelSize
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.spacingXS

                        MaterialSymbol {
                            text: "terminal"
                            iconSize: Metrics.iconS
                            color: root.mutedColor
                        }

                        Text {
                            text: qsTr("数据脚本")
                            color: Appearance.colors.colOnSurface
                            font.family: Typography.labelLarge.family
                            font.pixelSize: Typography.labelLarge.pixelSize
                        }

                        Text {
                            Layout.fillWidth: true
                            text: root.service.scriptPath
                            color: root.mutedColor
                            font.family: Fonts.mono
                            font.pixelSize: Typography.labelSmall.pixelSize
                            elide: Text.ElideMiddle
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Metrics.spacingXS

                        MaterialSymbol {
                            text: "cloud_sync"
                            iconSize: Metrics.iconS
                            color: root.officialStatusColor()
                        }

                        Text {
                            text: qsTr("DS 官方接口")
                            color: Appearance.colors.colOnSurface
                            font.family: Typography.labelLarge.family
                            font.pixelSize: Typography.labelLarge.pixelSize
                        }

                        Text {
                            Layout.fillWidth: true
                            text: root.officialStatusText()
                            color: root.mutedColor
                            font.family: Typography.labelSmall.family
                            font.pixelSize: Typography.labelSmall.pixelSize
                            horizontalAlignment: Text.AlignRight
                            elide: Text.ElideRight
                        }
                    }

                    InlineStatusBanner {
                        Layout.fillWidth: true
                        visible: root.staleSources.length > 0
                        tone: "warning"
                        message: qsTr("以下数据源暂不可用，正在显示缓存：%1").arg(root.staleSources.join("、"))
                    }
                }
            }
        }
    }

    Item {
        anchors.fill: parent
        visible: !root.hasAnyData

        SystemLoadingState {
            anchors.fill: parent
            active: root.foreground
            visible: root.waiting
            message: qsTr("正在获取 AI 用量")
        }

        SystemUnavailableState {
            anchors.fill: parent
            visible: root.failed
            title: qsTr("AI 用量不可用")
            message: root.service.errorMessage.length > 0 ? root.service.errorMessage :
                                                             qsTr("脚本未返回数据；面板会自动重试。")
            onRetryRequested: root.service.refresh()
        }

        SystemUnavailableState {
            anchors.fill: parent
            visible: !root.failed && !root.waiting
            title: qsTr("尚未配置 AI 用量数据源")
            message: qsTr("在 ~/.config/clavis/ai-usage.json 配置供应商密钥，或安装 ccusage 后点击重试。")
            onRetryRequested: root.service.refresh()
        }
    }

    component StatTile: Rectangle {
        id: tile

        required property string label
        required property string value
        property string supporting: ""

        implicitHeight: tileColumn.implicitHeight + Metrics.cardPadding * 2
        radius: Metrics.cornerM
        color: Appearance.colors.colLayer2

        ColumnLayout {
            id: tileColumn

            anchors.fill: parent
            anchors.margins: Metrics.cardPadding
            spacing: Metrics.spacingXXS

            Text {
                Layout.fillWidth: true
                text: tile.label
                color: root.mutedColor
                font.family: Typography.labelSmall.family
                font.pixelSize: Typography.labelSmall.pixelSize
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                text: tile.value
                color: Appearance.colors.colOnSurface
                font.family: Typography.titleLarge.family
                font.pixelSize: Typography.titleLarge.pixelSize
                font.weight: Typography.titleLarge.weight
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                visible: tile.supporting.length > 0
                text: tile.supporting
                color: root.mutedColor
                font.family: Typography.labelSmall.family
                font.pixelSize: Typography.labelSmall.pixelSize
                elide: Text.ElideRight
            }
        }
    }

    component BlockStat: ColumnLayout {
        id: blockStat

        required property string label
        required property string value

        spacing: 0

        Text {
            Layout.fillWidth: true
            text: blockStat.label
            color: root.mutedColor
            font.family: Typography.labelSmall.family
            font.pixelSize: Typography.labelSmall.pixelSize
            elide: Text.ElideRight
        }

        Text {
            Layout.fillWidth: true
            text: blockStat.value
            color: Appearance.colors.colOnSurface
            font.family: Typography.titleSmall.family
            font.pixelSize: Typography.titleSmall.pixelSize
            elide: Text.ElideRight
        }
    }

    // Miniature hit / miss / output split for a single day row.
    component SplitBar: Row {
        id: splitBar

        property real hit: 0
        property real miss: 0
        property real output: 0

        readonly property real total: Math.max(0, hit) + Math.max(0, miss) + Math.max(0, output)

        width: 84
        height: 6
        spacing: 0

        Rectangle {
            width: splitBar.total > 0 ? splitBar.width * Math.max(0, splitBar.hit) / splitBar.total : 0
            height: splitBar.height
            topLeftRadius: splitBar.height / 2
            bottomLeftRadius: splitBar.height / 2
            color: root.hitBarColor
            visible: width > 0
        }

        Rectangle {
            width: splitBar.total > 0 ? splitBar.width * Math.max(0, splitBar.miss) / splitBar.total : 0
            height: splitBar.height
            color: root.missBarColor
            visible: width > 0
        }

        Rectangle {
            width: splitBar.total > 0 ? splitBar.width * Math.max(0, splitBar.output) / splitBar.total : 0
            height: splitBar.height
            topRightRadius: splitBar.height / 2
            bottomRightRadius: splitBar.height / 2
            color: root.outBarColor
            visible: width > 0
        }
    }

    // A coloured label + token count pair ("命中 40.0M"), used to caption the
    // three numbers of a day row so they are readable without a legend lookup.
    component SplitStat: RowLayout {
        id: splitStat

        required property string label
        required property string value
        required property color tone

        spacing: Metrics.spacingXXS

        Text {
            Layout.alignment: Qt.AlignVCenter
            text: splitStat.label
            color: splitStat.tone
            font.family: Typography.labelSmall.family
            font.pixelSize: Typography.labelSmall.pixelSize
        }

        Text {
            Layout.alignment: Qt.AlignVCenter
            text: splitStat.value
            color: root.mutedColor
            font.family: Typography.labelSmall.family
            font.pixelSize: Typography.labelSmall.pixelSize
        }
    }
}

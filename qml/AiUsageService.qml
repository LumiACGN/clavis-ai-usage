pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

// Runs ~/.local/bin/clavis-ai-usage and exposes the aggregated AI usage
// document to the "AI 用量" system card.  Contract: schema_version 1 with a
// `providers` array and a `local` object; the last successful document is
// kept when a refresh fails so the card never flashes empty.
Singleton {
    id: root

    readonly property int supportedSchemaVersion: 1
    readonly property int refreshIntervalMs: 10 * 60 * 1000
    readonly property int deadlineMs: 60 * 1000
    readonly property int hardStopMs: 15 * 1000
    readonly property string scriptPath: {
        const configured = String(Quickshell.env("CLAVIS_AI_USAGE") || "").trim();
        return configured !== "" ? configured : Paths.binHome + "/clavis-ai-usage";
    }
    readonly property var command: ["bash", root.scriptPath]

    property string status: "idle"
    property string errorMessage: ""
    property bool busy: false
    property bool timedOut: false
    property var payload: ({})
    property double lastUpdatedMs: 0
    property bool _started: false
    property bool _pending: false

    readonly property var providers: Array.isArray(root.payload.providers) ? root.payload.providers : []
    readonly property var localUsage: root.payload.local && typeof root.payload.local === "object"
                                      ? root.payload.local : null
    readonly property bool hasData: root.providers.length > 0

    function requestRefresh(minimumAgeMs) {
        if (root.lastUpdatedMs === 0)
            return root.refresh();

        const age = Date.now() - root.lastUpdatedMs;
        if (age < Number(minimumAgeMs || 0))
            return false;

        return root.refresh();
    }

    function refresh() {
        if (worker.running) {
            root._pending = true;
            return false;
        }

        root.busy = true;
        root.timedOut = false;
        worker.running = true;
        deadline.restart();
        hardStop.restart();
        return true;
    }

    function _finish() {
        deadline.stop();
        hardStop.stop();
        root.busy = false;
        if (root._pending) {
            root._pending = false;
            root.refresh();
        }
    }

    function _consume(text, allowTimedOut) {
        try {
            const parsed = JSON.parse(String(text || "").trim());
            if (Number(parsed.schema_version) !== root.supportedSchemaVersion)
                throw new Error("unsupported schema_version");
            if (!Array.isArray(parsed.providers))
                throw new Error("providers is not an array");

            root.payload = parsed;
            root.status = "ready";
            root.errorMessage = String(parsed.error || "");
            root.lastUpdatedMs = Date.now();
            return true;
        } catch (error) {
            if (!root.hasData) {
                root.status = "error";
                root.errorMessage = allowTimedOut ? qsTr("AI 用量请求超时") : qsTr("AI 用量数据无法解析");
            } else {
                root.status = "error";
                root.errorMessage = qsTr("显示上次成功的数据");
            }
            console.warn("AiUsageService:", error);
            return false;
        }
    }

    Timer {
        id: periodic

        interval: root.refreshIntervalMs
        repeat: true
        running: root._started
        onTriggered: root.refresh()
    }

    Timer {
        id: deadline

        interval: root.deadlineMs
        onTriggered: {
            root.timedOut = true;
            if (worker.running)
                worker.signal(15);
        }
    }

    // Last resort: a child that ignored SIGTERM must not wedge the panel.
    Timer {
        id: hardStop

        interval: root.deadlineMs + root.hardStopMs
        onTriggered: {
            if (worker.running) {
                worker.running = false;
                root.busy = false;
                root.status = "error";
                if (!root.hasData)
                    root.errorMessage = qsTr("AI 用量请求超时");
                root._finish();
            }
        }
    }

    Process {
        id: worker

        command: root.command

        stdout: StdioCollector {
            id: output
        }

        stderr: StdioCollector {
            id: errorOutput

            onStreamFinished: {
                const text = String(errorOutput.text || "").trim();
                if (text !== "")
                    console.warn("AiUsageService:", text);
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root._consume(output.text, false);
            } else if (root.timedOut && root._consume(output.text, true)) {
                // The script's TERM trap printed the last good payload.
            } else if (!root.hasData) {
                root.status = "error";
                root.errorMessage = root.timedOut ? qsTr("AI 用量请求超时") : qsTr("AI 用量脚本执行失败");
                console.warn("AiUsageService: exit", exitCode, exitStatus);
            } else {
                root.status = "error";
                root.errorMessage = qsTr("显示上次成功的数据");
            }
            root._finish();
        }
    }

    Component.onCompleted: {
        root._started = true;
        root.refresh();
    }
}

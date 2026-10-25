/*
 * Release Monitor - KDE Plasma 6 plasmoid
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import QtCore
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import org.kde.notification

import "../code/checkers.js" as Checkers

PlasmoidItem {
    id: root

    // ------------------------------------------------------------ state
    property var items: []          // [{name, url, filter}]
    property var states: ({})       // url -> {id, version, time, timeIsSeen, lastCheck, error, fresh, link, artifacts}
    property var busy: ({})         // url -> bool (request in flight)
    property var dlStatus: ({})     // "url|artifact" -> "busy" | "done" | "failed"
    property var rows: []           // derived: [{name, url, filter, type, st}]
    property int checkingCount: 0
    property int freshCount: 0
    property int cmdSeq: 0

    readonly property var cfg: Plasmoid.configuration
    readonly property string homePath: StandardPaths.writableLocation(StandardPaths.HomeLocation)
                                           .toString().replace(/^file:\/\//, "")

    // ------------------------------------------------------------ plasmoid properties
    Plasmoid.icon: "system-software-update"
    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    Plasmoid.busy: checkingCount > 0

    toolTipMainText: i18n("Release Monitor")
    toolTipSubText: tooltipHtml(rows)
    toolTipTextFormat: Text.RichText

    // "Configure…" is added automatically by Plasma
    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Check for updates now")
            icon.name: "view-refresh"
            onTriggered: root.checkAll(true)
        }
    ]

    // ------------------------------------------------------------ helpers
    function esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function fmtTime(ms) {
        if (!ms) return "—";
        return Qt.formatDateTime(new Date(ms), "yyyy-MM-dd HH:mm");
    }

    function fmtSize(b) {
        if (!b) return "";
        var u = ["B", "KiB", "MiB", "GiB"], i = 0;
        while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
        return (i === 0 ? b : b.toFixed(1)) + " " + u[i];
    }

    function shq(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function safeName(s) {
        var n = String(s).replace(/[\/\\:*?"<>|\u0000]/g, "_").trim();
        return (n === "" || n === "." || n === "..") ? "_" : n;
    }

    function expandPath(p) {
        p = String(p || "~/Downloads").replace(/^file:\/\//, "").replace(/\/+$/, "");
        if (p === "~") return homePath;
        if (p.indexOf("~/") === 0) return homePath + p.substring(1);
        return p;
    }

    function targetDir(item) {
        var d = expandPath(cfg.downloadDir);
        return cfg.subfolders ? d + "/" + safeName(item.name) : d;
    }

    function findItem(url) {
        for (var i = 0; i < items.length; i++)
            if (items[i].url === url) return items[i];
        return null;
    }

    function tooltipHtml(list) {
        if (!list || list.length === 0)
            return i18n("No URLs configured. Right-click the icon and choose “Configure…”.");

        var anySeen = false;
        var h = "<table cellspacing='0' cellpadding='3'>";
        h += "<tr><th align='left'>" + i18n("Name") + "</th>"
           + "<th align='left'>" + i18n("Last release") + "</th>"
           + "<th align='left'>" + i18n("Release time") + "</th>"
           + "<th align='left'>" + i18n("Last check") + "</th></tr>";
        list.forEach(function (r) {
            var st = r.st || {};
            var rel = fmtTime(st.time);
            if (st.time && st.timeIsSeen) { rel += " *"; anySeen = true; }
            h += "<tr>"
               + "<td>" + esc(r.name) + (st.fresh ? " <b>(" + i18n("new") + ")</b>" : "") + "</td>"
               + "<td>" + (st.version ? esc(st.version) : "—") + "</td>"
               + "<td>" + rel + "</td>"
               + "<td>" + (st.lastCheck ? fmtTime(st.lastCheck) : i18n("never")) + "</td>"
               + "</tr>";
            if (st.error)
                h += "<tr><td colspan='4'><font color='#da4453'>⚠ " + esc(st.error) + "</font></td></tr>";
        });
        h += "</table>";
        if (anySeen)
            h += "<br/><i>* " + i18n("time when this widget first saw the release") + "</i>";
        return h;
    }

    // ------------------------------------------------------------ state management
    function loadItems() {
        var arr = [];
        try { arr = JSON.parse(cfg.urlsJson || "[]"); } catch (e) { arr = []; }
        items = arr.filter(function (x) { return x && x.url && String(x.url).trim() !== ""; })
                   .map(function (x) {
                       var url = String(x.url).trim();
                       return {
                           name: (x.name && String(x.name).trim()) ? String(x.name).trim() : Checkers.defaultName(url),
                           url: url,
                           filter: x.filter || ""
                       };
                   });
        rebuildRows();
    }

    function rebuildRows() {
        var fc = 0;
        var r = items.map(function (it) {
            var st = states[it.url] || {};
            if (st.fresh) fc++;
            return { name: it.name, url: it.url, filter: it.filter, type: Checkers.detectType(it.url), st: st };
        });
        freshCount = fc;
        rows = r;
    }

    function persist() {
        cfg.stateJson = JSON.stringify(states);
    }

    function markSeen(url) {
        if (states[url]) states[url].fresh = false;
        persist();
        rebuildRows();
    }

    function markAllSeen() {
        for (var k in states) states[k].fresh = false;
        persist();
        rebuildRows();
    }

    // ------------------------------------------------------------ checking
    function checkAll(manual) {
        items.forEach(function (it) { checkOne(it); });
    }

    function checkOne(item) {
        if (busy[item.url]) return;
        busy[item.url] = true;
        checkingCount++;

        Checkers.check(item, { githubToken: cfg.githubToken, debianArch: cfg.debianArch }, function (err, res) {
            busy[item.url] = false;
            checkingCount--;

            var st = states[item.url] || {};
            st.lastCheck = Date.now();
            if (err) {
                st.error = err;
            } else {
                st.error = "";
                var hadPrevious = !!st.id;
                if (st.id !== res.id) {
                    var oldVersion = st.version;
                    st.id = res.id;
                    st.version = res.version;
                    st.time = res.time || Date.now();
                    st.timeIsSeen = !res.time;
                    st.link = res.link;
                    st.artifacts = res.artifacts;
                    if (hadPrevious) {
                        st.fresh = true;
                        notifyNew(item, st, oldVersion);
                    }
                } else {
                    // same release: refresh artifact list (e.g. late-uploaded assets)
                    st.artifacts = res.artifacts;
                }
            }
            states[item.url] = st;
            persist();
            rebuildRows();
        });
    }

    // ------------------------------------------------------------ notifications
    Component {
        id: newReleaseComponent
        Notification {
            property string itemUrl: ""
            componentName: "plasma_workspace"
            eventId: "notification"
            iconName: "system-software-update"
            actions: [
                NotificationAction {
                    label: i18n("Download")
                    onActivated: root.downloadAll(itemUrl)
                },
                NotificationAction {
                    label: i18n("Show")
                    onActivated: root.expanded = true
                }
            ]
        }
    }

    Component {
        id: doneComponent
        Notification {
            property string folder: ""
            componentName: "plasma_workspace"
            eventId: "notification"
            iconName: "folder-download"
            actions: [
                NotificationAction {
                    label: i18n("Open folder")
                    onActivated: Qt.openUrlExternally("file://" + folder)
                }
            ]
        }
    }

    Component {
        id: infoComponent
        Notification {
            componentName: "plasma_workspace"
            eventId: "notification"
            iconName: "dialog-information"
        }
    }

    function notifyNew(item, st, oldVersion) {
        if (!cfg.notifyEnabled) return;
        var count = (st.artifacts || []).length;
        var text = oldVersion
            ? i18n("Version %1 is available (previously %2).", st.version, oldVersion)
            : i18n("Version %1 is available.", st.version);
        if (count > 0)
            text += " " + i18np("%1 artifact can be downloaded.", "%1 artifacts can be downloaded.", count);
        var n = newReleaseComponent.createObject(root, {
            itemUrl: item.url,
            title: i18n("New release: %1", item.name),
            text: text
        });
        n.sendEvent();
    }

    function notifyDone(title, text, folder) {
        var n = (folder ? doneComponent : infoComponent).createObject(root, folder
            ? { title: title, text: text, folder: folder }
            : { title: title, text: text });
        n.sendEvent();
    }

    // ------------------------------------------------------------ downloads (via curl)
    P5Support.DataSource {
        id: executor
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})

        onNewData: (sourceName, data) => {
            if (data["exit code"] === undefined) return;
            disconnectSource(sourceName);
            var cb = callbacks[sourceName];
            delete callbacks[sourceName];
            if (cb) cb(data["exit code"], data["stderr"] || "");
        }

        function run(cmd, cb) {
            cmd = cmd + " #" + (++root.cmdSeq);   // make identical commands distinct
            callbacks[cmd] = cb;
            connectSource(cmd);
        }
    }

    function setDl(key, value) {
        var o = Object.assign({}, dlStatus);
        o[key] = value;
        dlStatus = o;
    }

    function downloadArtifact(item, art, cb) {
        var key = item.url + "|" + art.name;
        setDl(key, "busy");
        var dir = targetDir(item);
        var file = dir + "/" + safeName(art.name);
        var part = file + ".part";
        var cmd = "mkdir -p " + shq(dir)
                + " && curl -fL --retry 3 --connect-timeout 20 -o " + shq(part) + " " + shq(art.url)
                + " && mv -f " + shq(part) + " " + shq(file)
                + " || { rm -f " + shq(part) + "; exit 1; }";
        executor.run(cmd, function (code, err) {
            var ok = (code === 0);
            setDl(key, ok ? "done" : "failed");
            if (cb) cb(ok, dir);
        });
    }

    function downloadOne(url, art) {
        var item = findItem(url);
        if (!item) return;
        downloadArtifact(item, art, function (ok, dir) {
            if (ok) notifyDone(i18n("Download finished"), art.name, dir);
            else notifyDone(i18n("Download failed"), art.name, "");
        });
    }

    function downloadAll(url) {
        var item = findItem(url), st = states[url];
        if (!item || !st || !st.artifacts || st.artifacts.length === 0) {
            notifyDone(i18n("Nothing to download"),
                       item ? i18n("%1 has no downloadable artifacts (check the filter).", item.name) : "", "");
            return;
        }
        var total = st.artifacts.length, finished = 0, okCount = 0, dirOut = "";
        st.artifacts.forEach(function (a) {
            downloadArtifact(item, a, function (ok, dir) {
                finished++;
                if (ok) { okCount++; dirOut = dir; }
                if (finished === total) {
                    notifyDone(okCount === total ? i18n("Download finished") : i18n("Download completed with errors"),
                               i18n("%1: %2 of %3 files downloaded.", item.name, okCount, total),
                               okCount > 0 ? dirOut : "");
                }
            });
        });
    }

    // ------------------------------------------------------------ scheduling
    Timer {
        id: pollTimer
        interval: Math.max(1, root.cfg.intervalMinutes) * 60 * 1000
        repeat: true
        running: true
        onTriggered: root.checkAll(false)
    }

    Timer {
        id: startupTimer
        interval: 3000
        running: true
        onTriggered: root.checkAll(false)
    }

    Connections {
        target: Plasmoid.configuration
        function onUrlsJsonChanged() {
            root.loadItems();
            Qt.callLater(function () { root.checkAll(false); });
        }
    }

    Component.onCompleted: {
        try { states = JSON.parse(cfg.stateJson || "{}"); } catch (e) { states = {}; }
        loadItems();
    }

    // ------------------------------------------------------------ small reusable button
    component IconButton: PlasmaComponents3.ToolButton {
        display: PlasmaComponents3.AbstractButton.IconOnly
        QQC2.ToolTip.text: text
        QQC2.ToolTip.visible: hovered
        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
    }

    // ------------------------------------------------------------ panel icon
    compactRepresentation: MouseArea {
        id: compactRoot
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        hoverEnabled: true

        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton) root.checkAll(true);
            else root.expanded = !root.expanded;
        }

        Kirigami.Icon {
            anchors.fill: parent
            source: "system-software-update"
            active: compactRoot.containsMouse
        }

        Rectangle {
            visible: root.freshCount > 0
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.min(parent.height * 0.5, Kirigami.Units.gridUnit)
            width: Math.max(height, badgeLabel.implicitWidth + 4)
            radius: height / 2
            color: Kirigami.Theme.highlightColor

            PlasmaComponents3.Label {
                id: badgeLabel
                anchors.centerIn: parent
                text: root.freshCount
                font.pixelSize: parent.height * 0.7
                color: Kirigami.Theme.highlightedTextColor
            }
        }
    }

    // ------------------------------------------------------------ popup
    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 24
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        Layout.preferredWidth: Kirigami.Units.gridUnit * 30
        Layout.preferredHeight: Kirigami.Units.gridUnit * 26

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                PlasmaExtras.Heading {
                    level: 3
                    text: i18n("Release Monitor")
                    Layout.fillWidth: true
                }
                IconButton {
                    icon.name: "dialog-ok-apply"
                    text: i18n("Mark all as seen")
                    visible: root.freshCount > 0
                    onClicked: root.markAllSeen()
                }
                IconButton {
                    icon.name: "view-refresh"
                    text: i18n("Check for updates now")
                    enabled: root.checkingCount === 0
                    onClicked: root.checkAll(true)
                }
            }
        }

        contentItem: PlasmaComponents3.ScrollView {
            ListView {
                id: list
                model: root.rows
                clip: true
                spacing: Kirigami.Units.largeSpacing

                PlasmaExtras.PlaceholderMessage {
                    anchors.centerIn: parent
                    width: parent.width - Kirigami.Units.gridUnit * 4
                    visible: root.rows.length === 0
                    text: i18n("No URLs configured")
                    explanation: i18n("Right-click the icon and choose “Configure…” to add GitHub, F-Droid, Debian or directory-listing URLs.")
                }

                delegate: ColumnLayout {
                    id: del
                    required property var modelData
                    readonly property var st: modelData.st || ({})
                    readonly property int artCount: (st.artifacts || []).length

                    width: ListView.view.width - Kirigami.Units.largeSpacing
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        PlasmaExtras.Heading {
                            level: 4
                            text: del.modelData.name
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        PlasmaComponents3.Label {
                            text: Checkers.typeLabel(del.modelData.type)
                            opacity: 0.6
                        }
                        PlasmaComponents3.Label {
                            visible: del.st.fresh === true
                            text: i18n("NEW")
                            font.bold: true
                            color: Kirigami.Theme.positiveTextColor
                        }
                        IconButton {
                            icon.name: "link"
                            text: i18n("Open release page")
                            onClicked: Qt.openUrlExternally(del.st.link || del.modelData.url)
                        }
                        IconButton {
                            icon.name: "dialog-ok-apply"
                            text: i18n("Mark as seen")
                            visible: del.st.fresh === true
                            onClicked: root.markSeen(del.modelData.url)
                        }
                        IconButton {
                            icon.name: "download"
                            text: i18n("Download all artifacts")
                            enabled: del.artCount > 0
                            onClicked: root.downloadAll(del.modelData.url)
                        }
                        IconButton {
                            icon.name: "view-refresh"
                            text: i18n("Check this URL now")
                            onClicked: root.checkOne(root.findItem(del.modelData.url))
                        }
                    }

                    GridLayout {
                        columns: 2
                        columnSpacing: Kirigami.Units.largeSpacing
                        rowSpacing: 0
                        Layout.fillWidth: true

                        PlasmaComponents3.Label { text: i18n("Last release:"); opacity: 0.7 }
                        PlasmaComponents3.Label {
                            text: del.st.version || "—"
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                        PlasmaComponents3.Label { text: i18n("Release time:"); opacity: 0.7 }
                        PlasmaComponents3.Label {
                            text: root.fmtTime(del.st.time) + (del.st.time && del.st.timeIsSeen ? " " + i18n("(first seen)") : "")
                            Layout.fillWidth: true
                        }
                        PlasmaComponents3.Label { text: i18n("Last check:"); opacity: 0.7 }
                        PlasmaComponents3.Label {
                            text: del.st.lastCheck ? root.fmtTime(del.st.lastCheck) : i18n("never")
                            Layout.fillWidth: true
                        }
                    }

                    PlasmaComponents3.Label {
                        visible: !!del.st.error
                        text: "⚠ " + (del.st.error || "")
                        color: Kirigami.Theme.negativeTextColor
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }

                    Repeater {
                        model: del.st.artifacts || []
                        delegate: RowLayout {
                            id: artRow
                            required property var modelData
                            readonly property string dl: root.dlStatus[del.modelData.url + "|" + modelData.name] || ""
                            Layout.fillWidth: true
                            Layout.leftMargin: Kirigami.Units.largeSpacing

                            PlasmaComponents3.Label {
                                text: artRow.modelData.name
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                            }
                            PlasmaComponents3.Label {
                                visible: !!artRow.modelData.size
                                text: root.fmtSize(artRow.modelData.size)
                                opacity: 0.6
                            }
                            PlasmaComponents3.Label {
                                visible: artRow.dl !== ""
                                text: artRow.dl === "busy" ? i18n("Downloading…")
                                    : artRow.dl === "done" ? "✓" : i18n("Failed")
                                color: artRow.dl === "failed" ? Kirigami.Theme.negativeTextColor
                                     : artRow.dl === "done" ? Kirigami.Theme.positiveTextColor
                                     : Kirigami.Theme.textColor
                            }
                            IconButton {
                                icon.name: "download"
                                text: i18n("Download")
                                enabled: artRow.dl !== "busy"
                                onClicked: root.downloadOne(del.modelData.url, artRow.modelData)
                            }
                        }
                    }

                    Kirigami.Separator { Layout.fillWidth: true }
                }
            }
        }
    }
}

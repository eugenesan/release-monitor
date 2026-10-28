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
    property var dlStatus: ({})     // "url|artifact" -> "busy" | "done" | "failed" | "cancelled"
    property var dlProgress: ({})   // "url|artifact" -> {got, total} bytes (total 0 = unknown)
    property var dlMeta: ({})       // "url|artifact" -> {part, pidf, total, cancelled} of running downloads
    property int activeDownloads: 0
    property bool polling: false
    property var rows: []           // derived: [{name, url, filter, type, st}]
    property int checkingCount: 0
    property int freshCount: 0        // unseen new releases (panel badge)
    property real lastCheckAll: 0     // most recent check over all URLs
    property int newCount: 0          // unseen new releases + just added URLs
    property int revision: 0          // bumped whenever `states` changes, delegates re-read their state
    property real now: Date.now()     // ticks while the tooltip is visible
    property real nextCheck: 0        // ms since epoch of the next scheduled check
    property bool hovered: false
    property int cmdSeq: 0

    readonly property var cfg: Plasmoid.configuration
    readonly property string homePath: StandardPaths.writableLocation(StandardPaths.HomeLocation)
                                           .toString().replace(/^file:\/\//, "")

    // ------------------------------------------------------------ plasmoid properties
    Plasmoid.icon: newCount > 0 ? "update-high" : "update-none"
    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    Plasmoid.busy: checkingCount > 0 || activeDownloads > 0

    // A custom tooltip item (instead of rich-text sub text) gives a real bordered table and
    // does not leave a rich-text format behind in the shared tooltip of other plasmoids.
    toolTipMainText: i18n("Release Monitor")
    toolTipItem: Loader {
        sourceComponent: tooltipComponent
        Layout.minimumWidth: item ? item.implicitWidth : 0
        Layout.minimumHeight: item ? item.implicitHeight : 0
        Layout.maximumWidth: Layout.minimumWidth
        Layout.maximumHeight: Layout.minimumHeight
    }

    // "Configure…" is added automatically by Plasma
    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Check all for updates now")
            icon.name: "view-refresh"
            onTriggered: root.checkAll(true)
        }
    ]

    // ------------------------------------------------------------ helpers
    // Forget everything learned about releases (versions, times, new/seen flags) and check again.
    // Triggered from the settings page through the resetToken counter.
    function resetHistory() {
        states = {};
        persist();
        rebuildRows();
        checkAll(true);
    }

    // QML has no clipboard API: copy through an invisible TextEdit
    TextEdit {
        id: clipHelper
        visible: false
    }

    function copyLinks(urls) {
        if (!urls || urls.length === 0) return;
        clipHelper.text = urls.join("\n");
        clipHelper.selectAll();
        clipHelper.copy();
        notifyDone(i18np("Link copied", "%1 links copied", urls.length),
                   urls.length === 1 ? urls[0] : i18n("One link per line"), "");
    }

    function esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function fmtTime(ms) {
        if (!ms) return i18n("n/a");
        return Qt.formatDateTime(new Date(ms), "yyyy-MM-dd HH:mm");
    }

    // Release time as reported by the source; 0 when it cannot be detected
    // (older saved states stored a "first seen" guess flagged with timeIsSeen: ignore it)
    function releaseTime(st) {
        return (st && st.time && !st.timeIsSeen) ? st.time : 0;
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

    // Flat list of table cells for the tooltip: [{text, header, span, error, lastCol, lastRow}]
    // "New" = unseen release, just added URL (first result not yet acknowledged), or not checked yet
    function isNewState(st) {
        return !!st && (st.fresh === true || st.added === true || !st.lastCheck || (!!st.error && !st.id));
    }

    readonly property var tipRows: rows.filter(function (r) { return root.isNewState(r.st); })

    function fmtIn(ms) {
        var m = Math.max(0, Math.ceil(ms / 60000));
        if (m >= 60) return i18n("%1 h %2 min", Math.floor(m / 60), m % 60);
        return i18n("%1 min", m);
    }

    function nextCheckText() {
        if (nextCheck <= 0) return "—";
        var d = new Date(nextCheck);
        var sameDay = d.toDateString() === new Date(now).toDateString();
        var when = nextCheck - now <= 0 ? i18n("due now") : i18n("in %1", fmtIn(nextCheck - now));
        return Qt.formatDateTime(d, sameDay ? "HH:mm" : "yyyy-MM-dd HH:mm") + " (" + when + ")";
    }

    function intervalMs() {
        return Math.max(1, cfg.intervalMinutes) * 60000;
    }

    // When is this URL due? Each URL keeps its own last-check time (persisted with the release state), so a
    // restart of Plasma or the computer does not re-fetch URLs that were checked recently, and the countdown
    // continues from the time that has already passed. 0 = never checked = due now.
    // Temporary failures (503, 429, no network) are retried with a growing delay: 3, 6, 12 ... minutes,
    // never more than the normal interval, so a blocked API is not hammered.
    function dueAt(it) {
        var st = states[it.url];
        if (!st || !st.lastCheck) return 0;
        var last = Math.min(st.lastCheck, Date.now());          // clock set back: do not wait for the future
        var iv = intervalMs();
        if (isTransient(st.error))
            return last + Math.min(iv, 3 * 60000 * Math.pow(2, Math.max(0, (st.fails || 1) - 1)));
        return last + iv;
    }

    function updateNextCheck() {
        var min = Infinity;
        items.forEach(function (it) { var d = dueAt(it); if (d < min) min = d; });
        nextCheck = !isFinite(min) ? 0 : (min === 0 ? Date.now() : min);
    }

    // Check only the URLs that are due (all of them after a long sleep, none right after a restart)
    function checkDue() {
        var t = Date.now();
        items.forEach(function (it) { if (dueAt(it) <= t) checkOne(it); });
    }

    function tick() {
        if (nextCheck > 0 && Date.now() >= nextCheck) checkDue();
    }

    // Errors that are likely to go away on their own (no network right after a resume, server hiccup)
    function isTransient(err) {
        return !!err && /^(Network error|Timed out|HTTP (5\d\d|429))/.test(err);
    }

    function tooltipCells(list) {
        var cells = [], rowsOut = [];
        rowsOut.push([i18n("Name"), i18n("Last release"), i18n("Release time"), i18n("Last check")]);
        list.forEach(function (r) {
            var st = r.st || {};
            var rel = fmtTime(releaseTime(st));
            rowsOut.push([
                r.name,
                st.version || "—",
                rel,
                st.lastCheck ? fmtTime(st.lastCheck) : i18n("never")
            ]);
            if (st.error) rowsOut.push({ error: "⚠ " + st.error });
        });
        rowsOut.forEach(function (row, ri) {
            var lastRow = (ri === rowsOut.length - 1);
            if (Array.isArray(row)) {
                row.forEach(function (t, ci) {
                    cells.push({ text: t, header: ri === 0, span: 1, error: false, lastCol: ci === 3, lastRow: lastRow });
                });
            } else {
                cells.push({ text: row.error, header: false, span: 4, error: true, lastCol: true, lastRow: lastRow });
            }
        });
        return cells;
    }

    Component {
        id: tooltipComponent
        ColumnLayout {
            id: tip
            spacing: Kirigami.Units.smallSpacing
            readonly property var cells: root.tooltipCells(root.tipRows)

            PlasmaExtras.Heading {
                level: 4
                text: i18n("Release Monitor")
            }

            PlasmaComponents3.Label {
                visible: root.tipRows.length === 0
                text: i18n("No new releases")
            }

            Rectangle {
                visible: root.tipRows.length > 0
                color: "transparent"
                border.width: 1
                border.color: Qt.alpha(Kirigami.Theme.textColor, 0.4)
                implicitWidth: grid.implicitWidth + 2
                implicitHeight: grid.implicitHeight + 2

                GridLayout {
                    id: grid
                    anchors.fill: parent
                    anchors.margins: 1
                    columns: 4
                    columnSpacing: 0
                    rowSpacing: 0

                    Repeater {
                        model: tip.cells
                        delegate: Rectangle {
                            id: cell
                            required property var modelData
                            Layout.columnSpan: modelData.span
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            implicitWidth: modelData.span > 1 ? 1 : cellLabel.implicitWidth + Kirigami.Units.largeSpacing * 2
                            implicitHeight: cellLabel.implicitHeight + Kirigami.Units.smallSpacing * 2
                            color: modelData.header ? Qt.alpha(Kirigami.Theme.textColor, 0.12) : "transparent"

                            // right and bottom rules (outer frame is drawn by the container)
                            Rectangle {
                                visible: !cell.modelData.lastCol
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: 1
                                color: Qt.alpha(Kirigami.Theme.textColor, 0.4)
                            }
                            Rectangle {
                                visible: !cell.modelData.lastRow
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                height: 1
                                color: Qt.alpha(Kirigami.Theme.textColor, 0.4)
                            }

                            PlasmaComponents3.Label {
                                id: cellLabel
                                anchors.left: parent.left
                                anchors.right: cell.modelData.span > 1 ? parent.right : undefined
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Kirigami.Units.largeSpacing
                                anchors.rightMargin: Kirigami.Units.largeSpacing
                                text: cell.modelData.text
                                textFormat: Text.PlainText
                                elide: cell.modelData.span > 1 ? Text.ElideRight : Text.ElideNone
                                font.bold: cell.modelData.header
                                color: cell.modelData.error ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                            }
                        }
                    }
                }
            }

            PlasmaComponents3.Label {
                visible: root.activeDownloads > 0
                text: i18np("Downloading %1 file", "Downloading %1 files", root.activeDownloads)
            }

            PlasmaComponents3.Label {
                text: i18n("Next update: %1", root.nextCheckText())
            }
        }
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
                           filter: x.filter || "",
                           prerelease: x.prerelease === true
                       };
                   });
        rebuildRows();
    }

    function rebuildRows() {
        var fc = 0, nc = 0, lc = 0;
        var r = items.map(function (it) {
            var st = states[it.url] || {};
            if (st.lastCheck > lc) lc = st.lastCheck;
            if (st.fresh) fc++;
            if (st.fresh || st.added) nc++;
            return { name: it.name, url: it.url, filter: it.filter, type: Checkers.detectType(it.url), st: st };
        });
        freshCount = fc;
        newCount = nc;
        lastCheckAll = lc;
        rows = r;
        revision++;
        updateNextCheck();
    }

    function persist() {
        cfg.stateJson = JSON.stringify(states);
    }

    function markSeen(url) {
        if (states[url]) { states[url].fresh = false; states[url].added = false; }
        persist();
        rebuildRows();
    }

    function markAllSeen() {
        for (var k in states) { states[k].fresh = false; states[k].added = false; }
        persist();
        rebuildRows();
    }

    // ------------------------------------------------------------ checking
    function checkAll(manual) {
        items.forEach(function (it) { checkOne(it); });
    }

    property var tokens: ({})       // url -> id of the running check (late answers of timed-out checks are ignored)
    property var startedAt: ({})    // url -> start time of the running check

    function checkOne(item) {
        if (busy[item.url]) return;
        busy[item.url] = true;
        checkingCount++;
        var token = (tokens[item.url] || 0) + 1;
        tokens[item.url] = token;
        startedAt[item.url] = Date.now();

        function finish(err, res) {
            if (tokens[item.url] !== token) return;          // superseded by the watchdog
            busy[item.url] = false;
            checkingCount--;
            delete startedAt[item.url];
            applyResult(item, err, res);
        }

        try {
            Checkers.check(item, { githubToken: cfg.githubToken, debianArch: cfg.debianArch }, finish);
        } catch (e) {
            finish("Internal error: " + e);
        }
    }

    function applyResult(item, err, res) {
        var st = states[item.url] || {};
        st.lastCheck = Date.now();
        try {
            if (err || !res) {
                st.error = err || i18n("Empty result");
                st.fails = isTransient(st.error) ? (st.fails || 0) + 1 : 0;
            } else {
                st.error = "";
                st.fails = 0;
                var hadPrevious = !!st.id;
                if (!hadPrevious) st.added = true;          // first result for this URL: "just added"
                if (st.id !== res.id) {
                    var oldVersion = st.version;
                    st.id = res.id;
                    st.version = res.version;
                    st.time = res.time || 0;           // 0 = not detectable, shown as n/a
                    st.timeIsSeen = false;
                    st.link = res.link;
                    st.typeLabel = res.typeLabel || "";
                    st.artifacts = res.artifacts;
                    if (hadPrevious) {
                        st.fresh = true;
                        notifyNew(item, st, oldVersion);
                    }
                } else {
                    // same release: refresh artifact list (e.g. late-uploaded assets)
                    st.artifacts = res.artifacts;
                    if (res.time) { st.time = res.time; st.timeIsSeen = false; }
                    st.typeLabel = res.typeLabel || "";
                }
            }
        } catch (e) {
            st.error = "Internal error: " + e;
        }
        states[item.url] = st;
        persist();
        rebuildRows();
    }

    // A check that never answers must not leave the item stuck on "never checked"
    Timer {
        interval: 15000
        repeat: true
        running: root.checkingCount > 0
        onTriggered: {
            var limit = Date.now() - 90000;
            Object.keys(root.startedAt).forEach(function (url) {
                if (root.startedAt[url] > limit) return;
                root.tokens[url] = (root.tokens[url] || 0) + 1;
                root.busy[url] = false;
                root.checkingCount--;
                delete root.startedAt[url];
                var item = root.findItem(url);
                if (item) root.applyResult(item, i18n("Timed out"), null);
            });
        }
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
            if (cb) cb(data["exit code"], data["stderr"] || "", data["stdout"] || "");
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
        activeDownloads = Object.keys(o).filter(function (k) { return o[k] === "busy"; }).length;
        if (value !== "busy" && dlProgress[key]) {
            var p = Object.assign({}, dlProgress);
            delete p[key];
            dlProgress = p;
        }
    }

    function downloadArtifact(item, art, cb) {
        var key = item.url + "|" + art.name;
        var dir = targetDir(item);
        var chain, part = "";
        if (art.kind === "dsc") {
            // Equivalent of `dget URL.dsc`: fetches the .dsc and every file it lists.
            // -u skips signature verification (so a missing keyring does not fail the download).
            // Falls back to curl + the "Files:" section when devscripts/dget is not installed.
            var slash = art.url.lastIndexOf("/");
            var baseUrl = art.url.substring(0, slash + 1);
            var fn = art.url.substring(slash + 1);
            chain = "mkdir -p " + shq(dir) + " && cd " + shq(dir)
                + " && if command -v dget >/dev/null 2>&1; then dget -u " + shq(art.url) + "; else"
                + " curl -fL --retry 3 -O " + shq(art.url)
                + " && awk '/^Files:/{f=1;next} /^[^ ]/{f=0} f&&NF==3{print $3}' " + shq(fn)
                + " | while read -r f; do curl -fL --retry 3 -O " + shq(baseUrl) + "\"$f\" || exit 1; done; fi";
        } else {
            var file = dir + "/" + safeName(art.name);
            part = file + ".part";
            // KIO (kioclient6 or kioclient, part of kde-cli-tools): KDE proxy settings, native job handling;
            // curl as fallback (also when KIO fails). The brace group keeps the && chain intact.
            var find = "K=$(command -v kioclient6 || command -v kioclient)";
            var kio = "\"$K\" copy --overwrite --noninteractive " + shq(art.url) + " " + shq(part);
            var curl = "curl -fL --retry 3 --connect-timeout 20 -o " + shq(part) + " " + shq(art.url);
            var mode = cfg.downloader || "auto";
            var fetchCmd = mode === "kio" ? "{ " + find + "; [ -n \"$K\" ] && " + kio + "; }"
                : mode === "curl" ? curl
                : "{ " + find + "; if [ -n \"$K\" ] && " + kio + "; then :; else " + curl + "; fi; }";
            chain = "mkdir -p " + shq(dir)
                + " && " + fetchCmd
                + " && mv -f " + shq(part) + " " + shq(file)
                + " || { rm -f " + shq(part) + "; exit 1; }";
        }

        // Run the download in its own process group (setsid) and remember the group leader's pid,
        // so that it can be cancelled together with every helper it started.
        var pidf = "/tmp/release-monitor-" + Date.now().toString(36) + "-" + (++cmdSeq) + ".pid";
        var script = "echo $$ > " + shq(pidf) + "; ( " + chain + " ); rc=$?; rm -f " + shq(pidf) + "; exit $rc";
        var cmd = "if command -v setsid >/dev/null 2>&1; then setsid -w sh -c " + shq(script)
                + "; else sh -c " + shq(script) + "; fi";

        var meta = { part: part, pidf: pidf, total: (art.exact && art.size) ? art.size : 0, cancelled: false };
        dlMeta[key] = meta;
        setDl(key, "busy");
        if (part && !meta.total) {
            headLength(art.url, function (len) { if (len > 0) meta.total = len; });
        }

        executor.run(cmd, function (code) {
            var wasCancelled = meta.cancelled;
            delete dlMeta[key];
            var ok = (code === 0) && !wasCancelled;
            setDl(key, wasCancelled ? "cancelled" : (ok ? "done" : "failed"));
            if (cb) cb(ok, dir, wasCancelled);
        });
    }

    // size of a file from its Content-Length (for the progress bar); 0 when the server does not tell
    function headLength(url, cb) {
        try {
            var xhr = new XMLHttpRequest();
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== 4) return;
                var n = xhr.status === 200 ? parseInt(xhr.getResponseHeader("Content-Length"), 10) : 0;
                cb(n > 0 ? n : 0);
            };
            xhr.open("HEAD", url);
            xhr.send();
        } catch (e) {
            cb(0);
        }
    }

    // One shell call per second reads the size of every running download's partial file
    // (KIO writes <name>.part.part while it copies, so both names are looked at).
    function pollProgress() {
        if (polling) return;
        var keys = Object.keys(dlMeta).filter(function (k) { return dlMeta[k].part && dlStatus[k] === "busy"; });
        if (!keys.length) return;
        polling = true;
        var cmd = keys.map(function (k, i) {
            var p = dlMeta[k].part;
            return "echo \"" + i + " $(stat -c %s " + shq(p) + " " + shq(p + ".part") + " 2>/dev/null | sort -n | tail -n 1)\"";
        }).join("; ");
        executor.run(cmd, function (code, err, out) {
            polling = false;
            var o = Object.assign({}, dlProgress);
            out.split("\n").forEach(function (line) {
                var m = /^(\d+)\s+(\d+)/.exec(line);
                if (!m) return;
                var key = keys[parseInt(m[1], 10)];
                if (key && dlMeta[key] && dlStatus[key] === "busy") o[key] = { got: parseInt(m[2], 10), total: dlMeta[key].total };
            });
            dlProgress = o;
        });
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.activeDownloads > 0
        onTriggered: root.pollProgress()
    }

    function cancelKey(key) {
        var meta = dlMeta[key];
        if (!meta || meta.cancelled) return;
        meta.cancelled = true;
        // wait briefly for the pid file (download just started), stop the whole process group, remove leftovers
        var cmd = "for i in 1 2 3 4 5; do [ -s " + shq(meta.pidf) + " ] && break; sleep 0.3; done; "
                + "P=$(cat " + shq(meta.pidf) + " 2>/dev/null); "
                + "if [ -n \"$P\" ]; then kill -s TERM -- -\"$P\" 2>/dev/null || kill -s TERM \"$P\" 2>/dev/null; "
                + "sleep 1; kill -s KILL -- -\"$P\" 2>/dev/null; fi; "
                + "rm -f " + shq(meta.pidf) + (meta.part ? " " + shq(meta.part) + " " + shq(meta.part + ".part") : "");
        executor.run(cmd, function () {});
    }

    function cancelDownload(url, art) {
        cancelKey(url + "|" + art.name);
    }

    function cancelGroup(url, group) {
        var st = states[url];
        ((st && st.artifacts) ? st.artifacts : []).forEach(function (a) {
            if (!group || a.group === group) cancelKey(url + "|" + a.name);
        });
    }

    function downloadOne(url, art) {
        var item = findItem(url);
        if (!item) return;
        downloadArtifact(item, art, function (ok, dir, cancelled) {
            if (cancelled) return;
            if (ok) notifyDone(i18n("Download finished"), art.name, dir);
            else notifyDone(i18n("Download failed"), art.name, "");
        });
    }

    function downloadList(item, arts) {
        if (!item || !arts || arts.length === 0) {
            notifyDone(i18n("Nothing to download"),
                       item ? i18n("%1 has no downloadable artifacts (check the filter).", item.name) : "", "");
            return;
        }
        var total = arts.length, finished = 0, okCount = 0, cancelCount = 0, dirOut = "";
        arts.forEach(function (a) {
            downloadArtifact(item, a, function (ok, dir, cancelled) {
                finished++;
                if (ok) { okCount++; dirOut = dir; }
                if (cancelled) cancelCount++;
                if (finished === total && cancelCount < total) {
                    notifyDone(okCount === total ? i18n("Download finished") : i18n("Download completed with errors"),
                               i18n("%1: %2 of %3 files downloaded.", item.name, okCount, total),
                               okCount > 0 ? dirOut : "");
                }
            });
        });
    }

    function downloadAll(url) {
        var st = states[url];
        downloadList(findItem(url), st ? st.artifacts : []);
    }

    function downloadGroup(url, group) {
        var st = states[url];
        downloadList(findItem(url), (st && st.artifacts ? st.artifacts : []).filter(function (a) { return a.group === group; }));
    }

    // aggregate download status of several artifacts: "" | "busy" | "done" | "failed"
    function groupStatus(url, arts) {
        var busyN = 0, doneN = 0, failedN = 0, cancelledN = 0;
        arts.forEach(function (a) {
            var v = dlStatus[url + "|" + a.name];
            if (v === "cancelled") cancelledN++;
            else if (v === "busy") busyN++;
            else if (v === "done") doneN++;
            else if (v === "failed") failedN++;
        });
        if (busyN) return "busy";
        if (failedN) return "failed";
        if (cancelledN) return "cancelled";
        if (doneN === arts.length && doneN > 0) return "done";
        return "";
    }

    // ------------------------------------------------------------ scheduling
    // Wall-clock scheduler. A QML Timer counts monotonic time, which does not advance while the computer
    // sleeps: one long timer would fire hours late after a resume. A short tick compares with the clock instead.
    Timer {
        id: pollTimer
        interval: 60000
        repeat: true
        running: true
        onTriggered: root.tick()
    }

    // keeps "in N min" in the tooltip current, only while it can be seen
    Timer {
        interval: 15000
        repeat: true
        running: root.hovered || root.expanded
        triggeredOnStart: true
        onTriggered: root.now = Date.now()
    }

    Timer {
        id: startupTimer
        interval: 3000
        running: true
        onTriggered: root.checkDue()
    }

    Connections {
        target: Plasmoid.configuration
        function onResetTokenChanged() { root.resetHistory(); }
        function onIntervalMinutesChanged() { root.updateNextCheck(); }
        function onUrlsJsonChanged() {
            root.loadItems();
            Qt.callLater(function () { root.checkDue(); });
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
        onContainsMouseChanged: root.hovered = containsMouse

        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton) root.checkAll(true);
            else root.expanded = !root.expanded;
        }

        Kirigami.Icon {
            anchors.fill: parent
            source: root.newCount > 0 ? "update-high" : "update-none"
            fallback: root.newCount > 0 ? "software-update-available" : "system-software-update"
            active: compactRoot.containsMouse
        }

        Rectangle {
            visible: root.newCount > 0
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.min(parent.height * 0.5, Kirigami.Units.gridUnit)
            width: Math.max(height, badgeLabel.implicitWidth + 4)
            radius: height / 2
            color: Kirigami.Theme.highlightColor

            PlasmaComponents3.Label {
                id: badgeLabel
                anchors.centerIn: parent
                text: root.newCount
                font.pixelSize: parent.height * 0.7
                color: Kirigami.Theme.highlightedTextColor
            }
        }
    }

    // ------------------------------------------------------------ popup
    fullRepresentation: PlasmaExtras.Representation {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 30
        Layout.minimumHeight: Kirigami.Units.gridUnit * 14
        Layout.preferredWidth: Kirigami.Units.gridUnit * 35
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
                    visible: root.newCount > 0
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
            id: scroll
            contentWidth: availableWidth

            // No elastic overscroll: a fast flick could leave the list scrolled outside its range
            Component.onCompleted: {
                if (contentItem) contentItem.boundsBehavior = Flickable.StopAtBounds;
            }

            ColumnLayout {
                width: scroll.availableWidth - Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.largeSpacing

                // list header: when the URLs were last checked / will be checked next
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.items.length > 0
                    spacing: Kirigami.Units.largeSpacing

                    PlasmaComponents3.Label {
                        text: i18n("Last check: %1", root.lastCheckAll > 0 ? root.fmtTime(root.lastCheckAll) : i18n("never"))
                        opacity: 0.8
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents3.Label {
                        text: i18n("Next update: %1", root.nextCheckText())
                        opacity: 0.8
                    }
                }

                Kirigami.Separator {
                    Layout.fillWidth: true
                    visible: root.items.length > 0
                }

                PlasmaExtras.PlaceholderMessage {
                    Layout.fillWidth: true
                    visible: root.items.length === 0
                    text: i18n("No URLs configured")
                    explanation: i18n("Right-click the icon and choose “Configure…” to add GitHub, F-Droid, Debian, directory or web page URLs.")
                }

                // The model only changes with the configured URLs; results update the delegates in place
                Repeater {
                    model: root.items
                    delegate: ColumnLayout {
                    id: del
                    required property var modelData
                    // a fresh copy per revision: `states` is mutated in place, a same-object assignment would not notify
                    readonly property var st: { root.revision; return Object.assign({}, root.states[modelData.url] || {}) }
                    readonly property bool isNew: st.fresh === true || st.added === true
                    readonly property var arts: st.artifacts || []
                    readonly property var plainArts: arts.filter(function (a) { return !a.group; })
                    readonly property var buildArts: arts.filter(function (a) { return a.group === "build"; })
                    readonly property int busyCount: {
                        root.dlStatus;
                        return arts.filter(function (a) { return root.dlStatus[modelData.url + "|" + a.name] === "busy"; }).length;
                    }

                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    // line 1: fixed-width name | version (centered in what is left) | fixed set of icons
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing

                        PlasmaExtras.Heading {
                            level: 4
                            text: del.modelData.name
                            elide: Text.ElideRight
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 9
                            Layout.minimumWidth: Kirigami.Units.gridUnit * 9
                            Layout.maximumWidth: Kirigami.Units.gridUnit * 9
                        }
                        PlasmaComponents3.Label {
                            text: del.st.version || "—"
                            elide: Text.ElideRight
                            horizontalAlignment: Text.AlignHCenter
                            Layout.fillWidth: true
                            color: Kirigami.Theme.highlightColor
                            font.bold: true
                        }
                        // "new" marker: always present, greyed out when inactive
                        Kirigami.Icon {
                            source: "notifications"
                            fallback: "preferences-desktop-notification"
                            Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                            Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                            opacity: del.isNew ? 1.0 : 0.25
                            HoverHandler { id: newHover }
                            QQC2.ToolTip.visible: newHover.hovered
                            QQC2.ToolTip.text: del.st.fresh === true ? i18n("New release")
                                             : del.st.added === true ? i18n("Just added")
                                             : i18n("No new release")
                        }
                        IconButton {
                            icon.name: "dialog-ok-apply"
                            text: i18n("Mark as seen")
                            enabled: del.isNew
                            onClicked: root.markSeen(del.modelData.url)
                        }
                        IconButton {
                            icon.name: "link"
                            text: i18n("Open release page")
                            onClicked: Qt.openUrlExternally(del.st.link || del.modelData.url)
                        }
                        IconButton {
                            icon.name: del.busyCount > 0 ? "process-stop" : "download"
                            text: del.busyCount > 0 ? i18n("Cancel downloads") : i18n("Download all artifacts")
                            enabled: del.arts.length > 0
                            onClicked: del.busyCount > 0 ? root.cancelGroup(del.modelData.url, "") : root.downloadAll(del.modelData.url)
                        }
                        IconButton {
                            icon.name: "view-refresh"
                            text: i18n("Check this URL now")
                            onClicked: root.checkOne(root.findItem(del.modelData.url))
                        }
                    }

                    // line 2: release time + last check + source type
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        PlasmaComponents3.Label {
                            text: i18n("Released: %1", root.fmtTime(root.releaseTime(del.st)))
                            opacity: 0.8
                        }
                        Item { Layout.fillWidth: true }
                        PlasmaComponents3.Label {
                            text: del.st.typeLabel || Checkers.typeLabel(Checkers.detectType(del.modelData.url))
                            opacity: 0.6
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
                        model: del.plainArts
                        delegate: RowLayout {
                            id: artRow
                            required property var modelData
                            readonly property string dl: root.dlStatus[del.modelData.url + "|" + modelData.name] || ""
                            readonly property var prog: root.dlProgress[del.modelData.url + "|" + modelData.name]
                            readonly property bool known: !!prog && prog.total > 0
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
                            PlasmaComponents3.ProgressBar {
                                visible: artRow.dl === "busy"
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                                from: 0
                                to: 1
                                indeterminate: !artRow.known
                                value: artRow.known ? Math.min(0.99, artRow.prog.got / artRow.prog.total) : 0
                            }
                            PlasmaComponents3.Label {
                                visible: artRow.dl === "busy"
                                text: artRow.known ? Math.round(Math.min(0.99, artRow.prog.got / artRow.prog.total) * 100) + " %"
                                    : (artRow.prog && artRow.prog.got > 0 ? root.fmtSize(artRow.prog.got) : "…")
                                opacity: 0.8
                            }
                            PlasmaComponents3.Label {
                                visible: artRow.dl !== "" && artRow.dl !== "busy"
                                text: artRow.dl === "done" ? "✓" : artRow.dl === "cancelled" ? i18n("Cancelled") : i18n("Failed")
                                color: artRow.dl === "failed" ? Kirigami.Theme.negativeTextColor
                                     : artRow.dl === "done" ? Kirigami.Theme.positiveTextColor
                                     : Kirigami.Theme.textColor
                            }
                            IconButton {
                                icon.name: "edit-copy"
                                text: i18n("Copy link")
                                onClicked: root.copyLinks([artRow.modelData.url])
                            }
                            IconButton {
                                icon.name: artRow.dl === "busy" ? "process-stop" : "download"
                                text: artRow.dl === "busy" ? i18n("Cancel download")
                                    : artRow.modelData.kind === "dsc" ? i18n("Download (dget: .dsc and its files)") : i18n("Download")
                                onClicked: artRow.dl === "busy" ? root.cancelDownload(del.modelData.url, artRow.modelData)
                                                                : root.downloadOne(del.modelData.url, artRow.modelData)
                            }
                        }
                    }

                    // F-Droid: source tarball, build log and signature as one download
                    RowLayout {
                        id: buildRow
                        visible: del.buildArts.length > 0
                        readonly property string gs: root.groupStatus(del.modelData.url, del.buildArts)
                        Layout.fillWidth: true
                        Layout.leftMargin: Kirigami.Units.largeSpacing

                        PlasmaComponents3.Label {
                            text: i18np("Build artifacts (%1 file)", "Build artifacts (%1 files)", del.buildArts.length)
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            HoverHandler { id: buildHover }
                            QQC2.ToolTip.visible: buildHover.hovered
                            QQC2.ToolTip.text: del.buildArts.map(function (a) { return a.name; }).join("\n")
                        }
                        PlasmaComponents3.ProgressBar {
                            visible: buildRow.gs === "busy"
                            Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                            indeterminate: true
                        }
                        PlasmaComponents3.Label {
                            visible: buildRow.gs !== ""
                            text: buildRow.gs === "busy" ? i18n("Downloading…")
                                : buildRow.gs === "done" ? "✓" : buildRow.gs === "cancelled" ? i18n("Cancelled") : i18n("Failed")
                            color: buildRow.gs === "failed" ? Kirigami.Theme.negativeTextColor
                                 : buildRow.gs === "done" ? Kirigami.Theme.positiveTextColor
                                 : Kirigami.Theme.textColor
                        }
                        IconButton {
                            icon.name: "edit-copy"
                            text: i18n("Copy links of all build artifacts")
                            onClicked: root.copyLinks(del.buildArts.map(function (a) { return a.url; }))
                        }
                        IconButton {
                            icon.name: buildRow.gs === "busy" ? "process-stop" : "download"
                            text: buildRow.gs === "busy" ? i18n("Cancel download")
                                : i18n("Download build artifacts (source, build log, signature)")
                            onClicked: buildRow.gs === "busy" ? root.cancelGroup(del.modelData.url, "build")
                                                              : root.downloadGroup(del.modelData.url, "build")
                        }
                    }

                    Kirigami.Separator { Layout.fillWidth: true }
                }
                }
            }
        }
    }
}

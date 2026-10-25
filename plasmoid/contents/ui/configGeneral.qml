/*
 * Release Monitor - settings page
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import QtQuick.Dialogs
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.plasma.plasma5support as P5Support

KCM.SimpleKCM {
    id: page

    // Plasma fills these from main.xml and writes them back on Apply/OK
    property string cfg_urlsJson
    property string cfg_urlsJsonDefault
    property int cfg_intervalMinutes
    property int cfg_intervalMinutesDefault
    property string cfg_downloadDir
    property string cfg_downloadDirDefault
    property bool cfg_subfolders
    property bool cfg_subfoldersDefault
    property bool cfg_notifyEnabled
    property bool cfg_notifyEnabledDefault
    property string cfg_githubToken
    property string cfg_githubTokenDefault
    property string cfg_debianArch
    property string cfg_debianArchDefault
    property int cfg_resetToken
    property int cfg_resetTokenDefault

    property bool syncing: false

    ListModel { id: lm }

    function loadList() {
        lm.clear();
        var arr = [];
        try { arr = JSON.parse(cfg_urlsJson || "[]"); } catch (e) { arr = []; }
        arr.forEach(function (x) {
            lm.append({ itemName: x.name || "", itemUrl: x.url || "", itemFilter: x.filter || "" });
        });
    }

    // Remove inside a page function: the delegate that fired the click is destroyed by lm.remove(),
    // so anything after it in the delegate's own handler could silently not run.
    function removeAt(i) {
        lm.remove(i);
        syncList();
    }

    function syncList() {
        var arr = [];
        for (var i = 0; i < lm.count; i++) {
            var e = lm.get(i);
            arr.push({ name: e.itemName, url: e.itemUrl, filter: e.itemFilter });
        }
        syncing = true;
        cfg_urlsJson = JSON.stringify(arr);
        syncing = false;
    }

    // ---- export / import (JSON file with name, url and filter of every entry)
    property string ioMessage: ""
    property bool ioError: false
    property int shellSeq: 0

    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
    function localPath(url) { return decodeURIComponent(url.toString().replace(/^file:\/\//, "")); }

    function exportList(path) {
        var arr = [];
        for (var i = 0; i < lm.count; i++) {
            var e = lm.get(i);
            arr.push({ name: e.itemName, url: e.itemUrl, filter: e.itemFilter });
        }
        var json = JSON.stringify({ format: "release-monitor-urls", version: 1, urls: arr }, null, 2);
        shell.run("printf '%s\\n' " + shq(json) + " > " + shq(path), function (code, out, err) {
            ioError = code !== 0;
            ioMessage = code === 0 ? i18np("Exported %1 URL to %2", "Exported %1 URLs to %2", arr.length, path)
                                   : i18n("Export failed: %1", err);
        });
    }

    // Merge: entries whose URL already exists get the imported name and filter, others are appended
    function importList(path) {
        shell.run("cat " + shq(path), function (code, out, err) {
            if (code !== 0) { ioError = true; ioMessage = i18n("Import failed: %1", err); return; }
            var data;
            try { data = JSON.parse(out); } catch (e) { ioError = true; ioMessage = i18n("Import failed: not a valid JSON file"); return; }
            var list = Array.isArray(data) ? data : (data && Array.isArray(data.urls) ? data.urls : null);
            if (!list) { ioError = true; ioMessage = i18n("Import failed: no URL list found"); return; }
            var added = 0, updated = 0;
            list.forEach(function (x) {
                if (!x || typeof x.url !== "string" || x.url.trim() === "") return;
                var url = x.url.trim(), found = -1;
                for (var i = 0; i < lm.count; i++)
                    if (lm.get(i).itemUrl.trim() === url) { found = i; break; }
                var name = typeof x.name === "string" ? x.name : "";
                var filter = typeof x.filter === "string" ? x.filter : "";
                if (found >= 0) {
                    lm.setProperty(found, "itemName", name);
                    lm.setProperty(found, "itemFilter", filter);
                    updated++;
                } else {
                    lm.append({ itemName: name, itemUrl: url, itemFilter: filter });
                    added++;
                }
            });
            syncList();
            ioError = false;
            ioMessage = i18n("Imported: %1 added, %2 updated", added, updated);
        });
    }

    P5Support.DataSource {
        id: shell
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        onNewData: (sourceName, data) => {
            if (data["exit code"] === undefined) return;
            disconnectSource(sourceName);
            var cb = callbacks[sourceName];
            delete callbacks[sourceName];
            if (cb) cb(data["exit code"], data["stdout"] || "", data["stderr"] || "");
        }
        function run(cmd, cb) {
            cmd = cmd + " #" + (++page.shellSeq);
            callbacks[cmd] = cb;
            connectSource(cmd);
        }
    }

    FileDialog {
        id: exportDialog
        title: i18n("Export URLs")
        fileMode: FileDialog.SaveFile
        nameFilters: [i18n("JSON files (*.json)")]
        defaultSuffix: "json"
        onAccepted: page.exportList(page.localPath(selectedFile))
    }

    FileDialog {
        id: importDialog
        title: i18n("Import URLs")
        fileMode: FileDialog.OpenFile
        nameFilters: [i18n("JSON files (*.json)"), i18n("All files (*)")]
        onAccepted: page.importList(page.localPath(selectedFile))
    }

    onCfg_urlsJsonChanged: if (!syncing) loadList()
    Component.onCompleted: loadList()

    property bool resetPending: false

    Kirigami.PromptDialog {
        id: resetDialog
        title: i18n("Forget release history?")
        subtitle: i18n("All remembered versions, release times and new/seen markers will be deleted and every URL will be checked again as if it was just added. Your URL list and settings are kept. This takes effect when you press Apply or OK.")
        standardButtons: Kirigami.Dialog.Ok | Kirigami.Dialog.Cancel
        onAccepted: {
            page.cfg_resetToken = page.cfg_resetToken + 1;
            page.resetPending = true;
        }
    }

    FolderDialog {
        id: folderDialog
        title: i18n("Select download directory")
        onAccepted: page.cfg_downloadDir = decodeURIComponent(selectedFolder.toString().replace(/^file:\/\//, ""))
    }

    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        Kirigami.FormLayout {
            Layout.fillWidth: true

            QQC2.SpinBox {
                Kirigami.FormData.label: i18n("Check every (minutes):")
                from: 1
                to: 10080
                editable: true
                value: page.cfg_intervalMinutes
                onValueModified: page.cfg_intervalMinutes = value
            }

            RowLayout {
                Kirigami.FormData.label: i18n("Download directory:")
                QQC2.TextField {
                    Layout.fillWidth: true
                    Layout.minimumWidth: Kirigami.Units.gridUnit * 18
                    text: page.cfg_downloadDir
                    placeholderText: "~/Downloads"
                    onTextEdited: page.cfg_downloadDir = text
                }
                QQC2.Button {
                    icon.name: "folder-open"
                    QQC2.ToolTip.text: i18n("Browse…")
                    QQC2.ToolTip.visible: hovered
                    onClicked: folderDialog.open()
                }
            }

            QQC2.CheckBox {
                text: i18n("Save each item in its own subfolder")
                checked: page.cfg_subfolders
                onToggled: page.cfg_subfolders = checked
            }

            QQC2.CheckBox {
                text: i18n("Show a desktop notification for new releases")
                checked: page.cfg_notifyEnabled
                onToggled: page.cfg_notifyEnabled = checked
            }

            QQC2.TextField {
                Kirigami.FormData.label: i18n("Debian architecture:")
                text: page.cfg_debianArch
                placeholderText: "amd64"
                onTextEdited: page.cfg_debianArch = text
            }

            QQC2.TextField {
                Kirigami.FormData.label: i18n("GitHub token (optional):")
                echoMode: TextInput.Password
                text: page.cfg_githubToken
                placeholderText: i18n("Raises the API rate limit")
                onTextEdited: page.cfg_githubToken = text
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        Kirigami.Heading {
            level: 3
            text: i18n("Monitored URLs")
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: true
            text: i18n("Supported: github.com/OWNER/REPO/releases, f-droid.org/packages/APP.ID, packages.debian.org/SUITE/PACKAGE, or any web directory listing (release folders such as 7.1.4/ are entered automatically; a listing with .dsc files is treated as a Debian package) or a normal web page with download links. The optional filter is a case-insensitive regular expression; only artifacts / files whose name matches are kept. Example for 7-Zip: linux-x64|lzma|src")
        }

        Repeater {
            model: lm
            delegate: ColumnLayout {
                id: entry
                required property int index
                required property string itemName
                required property string itemUrl
                required property string itemFilter

                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    QQC2.TextField {
                        Layout.fillWidth: true
                        Layout.horizontalStretchFactor: 2
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 6
                        placeholderText: i18n("Name")
                        text: entry.itemName
                        onTextEdited: { lm.setProperty(entry.index, "itemName", text); page.syncList(); }
                    }
                    QQC2.TextField {
                        Layout.fillWidth: true
                        Layout.horizontalStretchFactor: 5
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 12
                        placeholderText: i18n("URL")
                        text: entry.itemUrl
                        onTextEdited: { lm.setProperty(entry.index, "itemUrl", text); page.syncList(); }
                    }
                    QQC2.Button {
                        icon.name: "list-remove"
                        QQC2.ToolTip.text: i18n("Remove")
                        QQC2.ToolTip.visible: hovered
                        onClicked: page.removeAt(entry.index)
                    }
                }
                QQC2.TextField {
                    Layout.fillWidth: true
                    placeholderText: i18n("Filter (regular expression, optional)")
                    text: entry.itemFilter
                    onTextEdited: { lm.setProperty(entry.index, "itemFilter", text); page.syncList(); }
                }
                Kirigami.Separator { Layout.fillWidth: true }
            }
        }

        RowLayout {
            spacing: Kirigami.Units.smallSpacing

            QQC2.Button {
                text: i18n("Add URL")
                icon.name: "list-add"
                onClicked: {
                    lm.append({ itemName: "", itemUrl: "", itemFilter: "" });
                    page.syncList();
                }
            }
            QQC2.Button {
                text: i18n("Import…")
                icon.name: "document-import"
                onClicked: importDialog.open()
            }
            QQC2.Button {
                text: i18n("Export…")
                icon.name: "document-export"
                enabled: lm.count > 0
                onClicked: exportDialog.open()
            }
        }

        Kirigami.Separator { Layout.fillWidth: true }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            QQC2.Button {
                text: i18n("Forget release history…")
                icon.name: "edit-clear-history"
                enabled: !page.resetPending
                onClicked: resetDialog.open()
            }
            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.7
                text: page.resetPending ? i18n("The history will be cleared when you press Apply or OK.")
                                        : i18n("Deletes remembered versions, times and new/seen markers.")
            }
        }

        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.ioMessage !== ""
            type: page.ioError ? Kirigami.MessageType.Error : Kirigami.MessageType.Positive
            text: page.ioMessage
        }

        // the message clears itself (InlineMessage's own close button would break the visible binding)
        Timer {
            running: page.ioMessage !== ""
            interval: 10000
            onTriggered: page.ioMessage = ""
        }
    }
}

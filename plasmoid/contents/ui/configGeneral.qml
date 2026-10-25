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

    onCfg_urlsJsonChanged: if (!syncing) loadList()
    Component.onCompleted: loadList()

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

        QQC2.Button {
            text: i18n("Add URL")
            icon.name: "list-add"
            onClicked: {
                lm.append({ itemName: "", itemUrl: "", itemFilter: "" });
                page.syncList();
            }
        }
    }
}

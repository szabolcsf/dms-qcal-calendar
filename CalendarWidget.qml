import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // ── Persisted settings ──────────────────────────────────────────
    property int lookAheadDays: 7
    property int refreshInterval: 5       // minutes
    property bool showLocation: true
    property bool showCalendarName: false
    property bool notificationsEnabled: true
    property int notifyMinutes: 15        // notify N minutes before event
    property string caldavUrl: ""
    property string caldavUsername: ""
    property string caldavPassword: ""
    property string _lastSyncedCreds: ""
    property bool _credsSeeded: false

    // ── Runtime state ───────────────────────────────────────────────
    property var events: []
    property int eventCount: 0
    property bool isLoading: true
    property bool hasError: false
    property string errorText: ""
    property string lastUpdated: ""
    property var calendars: []            // [{index, name, host}]
    property bool showAddForm: false
    property string addError: ""

    // New event form state
    property int addCalendarIdx: 0
    property string addTitle: ""
    property var addStartDate: new Date()
    property var addEndDate: {
        var d = new Date();
        d.setHours(d.getHours() + 1);
        return d;
    }
    property bool addAllDay: false
    property string addLocation: ""

    // Edit event form state
    property bool showEditForm: false
    property var editEvent: null        // the event object being edited
    property string editTitle: ""
    property var editStartDate: new Date()
    property var editEndDate: new Date()
    property bool editAllDay: false
    property string editError: ""
    property string editLocation: ""

    // ── Internal ────────────────────────────────────────────────────
    property string _pendingOutput: ""
    property string _notifyOutput: ""
    property string _addOutput: ""
    property string _calOutput: ""
    property string _editOutput: ""
    property string _deleteOutput: ""

    property string wrapperPath: {
        var qmlPath = Qt.resolvedUrl(".");
        var dir = qmlPath.toString().replace(/^file:\/\//, "");
        return dir + "qcal-wrapper.py";
    }

    // ── Load settings ───────────────────────────────────────────────
    function loadSettings() {
        if (!pluginService || !pluginService.loadPluginData) return;
        lookAheadDays = pluginService.loadPluginData(pluginId, "lookAheadDays", 7) || 7;
        refreshInterval = pluginService.loadPluginData(pluginId, "refreshInterval", 5) || 5;
        showLocation = pluginService.loadPluginData(pluginId, "showLocation", true) !== false;
        showCalendarName = pluginService.loadPluginData(pluginId, "showCalendarName", false) === true;
        notificationsEnabled = pluginService.loadPluginData(pluginId, "notificationsEnabled", true) !== false;
        notifyMinutes = pluginService.loadPluginData(pluginId, "notifyMinutes", 15) || 15;
        caldavUrl = pluginService.loadPluginData(pluginId, "caldavUrl", "") || "";
        caldavUsername = pluginService.loadPluginData(pluginId, "caldavUsername", "") || "";
        caldavPassword = pluginService.loadPluginData(pluginId, "caldavPassword", "") || "";
        if (!_credsSeeded) seedCredsFromConfig();
        else syncQcalConfig();
    }

    function seedCredsFromConfig() {
        _credsSeeded = true;
        seedProc.command = ["python3", "-c",
            "import json, os, sys\n" +
            "f = os.path.expanduser('~/.config/qcal/config.json')\n" +
            "try:\n" +
            "    cfg = json.load(open(f))\n" +
            "except: sys.exit(0)\n" +
            "cals = cfg.get('Calendars', [])\n" +
            "if not cals: sys.exit(0)\n" +
            "c = cals[0]\n" +
            "u = c.get('Username', '')\n" +
            "p = c.get('Password', '')\n" +
            "if not p and c.get('PasswordCmd'):\n" +
            "    import subprocess\n" +
            "    try: p = subprocess.run(['sh','-c',c['PasswordCmd']], capture_output=True, text=True, timeout=5).stdout.strip()\n" +
            "    except: pass\n" +
            "urls = [x.get('Url','') for x in cals if x.get('Username') == u]\n" +
            "from os.path import commonprefix\n" +
            "base = commonprefix(urls).rstrip('/').rsplit('/',1)[0] + '/' if len(urls) > 1 else (urls[0] if urls else '')\n" +
            "json.dump({'url': base, 'username': u, 'password': p}, sys.stdout)\n"
        ];
        seedProc.running = true;
    }

    Process {
        id: seedProc
        running: false
        property string _out: ""
        stdout: SplitParser {
            onRead: data => { seedProc._out += data; }
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 || !_out.trim()) return;
            try {
                var creds = JSON.parse(_out.trim());
                if (creds.url && !root.caldavUrl) {
                    root.caldavUrl = creds.url;
                    if (root.pluginService) root.pluginService.savePluginData(root.pluginId, "caldavUrl", creds.url);
                }
                if (creds.username && !root.caldavUsername) {
                    root.caldavUsername = creds.username;
                    if (root.pluginService) root.pluginService.savePluginData(root.pluginId, "caldavUsername", creds.username);
                }
                if (creds.password && !root.caldavPassword) {
                    root.caldavPassword = creds.password;
                    if (root.pluginService) root.pluginService.savePluginData(root.pluginId, "caldavPassword", creds.password);
                }
                root._lastSyncedCreds = root.caldavUrl + "|" + root.caldavUsername + "|" + root.caldavPassword;
            } catch (e) {}
            _out = "";
        }
    }

    function syncQcalConfig() {
        if (!caldavUrl || !caldavUsername || !caldavPassword) return;
        var credsKey = caldavUrl + "|" + caldavUsername + "|" + caldavPassword;
        if (credsKey === _lastSyncedCreds) return;
        _lastSyncedCreds = credsKey;
        _syncOutput = "";
        syncProc.command = ["python3", root.wrapperPath, "discover",
            caldavUrl, caldavUsername, caldavPassword];
        syncProc.running = true;
    }

    property string _syncOutput: ""

    Process {
        id: syncProc
        running: false
        stdout: SplitParser {
            onRead: data => { root._syncOutput += data; }
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                root.fetchEvents();
                root.fetchCalendars();
            }
        }
    }

    Component.onCompleted: {
        loadSettings();
        fetchEvents();
        fetchCalendars();
    }

    Timer {
        interval: 3000
        running: true
        repeat: true
        onTriggered: root.loadSettings()
    }

    // ── Refresh timer ───────────────────────────────────────────────
    Timer {
        id: refreshTimer
        interval: root.refreshInterval * 60 * 1000
        running: true
        repeat: true
        onTriggered: {
            root.fetchEvents();
            if (root.notificationsEnabled) root.checkNotifications();
        }
    }

    // More frequent notification check (every minute)
    Timer {
        id: notifyTimer
        interval: 60000
        running: root.notificationsEnabled
        repeat: true
        onTriggered: root.checkNotifications()
    }

    // ── Fetch events ────────────────────────────────────────────────
    function fetchEvents() {
        _pendingOutput = "";
        fetchProc.command = ["python3", root.wrapperPath, "list", "--days", "" + root.lookAheadDays];
        fetchProc.running = true;
    }

    Process {
        id: fetchProc
        running: false
        stdout: SplitParser {
            onRead: data => { root._pendingOutput += data + "\n"; }
        }
        onExited: (exitCode, exitStatus) => {
            try {
                var json = JSON.parse(root._pendingOutput.trim());
                if (json.error) {
                    root.hasError = true;
                    root.errorText = json.error;
                } else {
                    root.events = json.events || [];
                    root.eventCount = json.count || 0;
                    root.hasError = false;
                }
            } catch (e) {
                // No config or empty response
                if (root._pendingOutput === "") {
                    root.hasError = true;
                    root.errorText = "Configure your CalDAV account in plugin settings";
                } else {
                    root.hasError = true;
                    root.errorText = "Parse error";
                }
            }
            root.isLoading = false;

            var now = new Date();
            root.lastUpdated = ("0" + now.getHours()).slice(-2) + ":" + ("0" + now.getMinutes()).slice(-2);
        }
    }

    // ── Fetch calendars (for add form) ──────────────────────────────
    function fetchCalendars() {
        _calOutput = "";
        calProc.command = ["python3", root.wrapperPath, "calendars"];
        calProc.running = true;
    }

    Process {
        id: calProc
        running: false
        stdout: SplitParser {
            onRead: data => { root._calOutput += data + "\n"; }
        }
        onExited: {
            try {
                var json = JSON.parse(root._calOutput.trim());
                root.calendars = json.calendars || [];
            } catch (e) {
                root.calendars = [];
            }
        }
    }

    // ── Check notifications ─────────────────────────────────────────
    function checkNotifications() {
        _notifyOutput = "";
        notifyProc.command = ["python3", root.wrapperPath, "notify", "--minutes", "" + root.notifyMinutes];
        notifyProc.running = true;
    }

    Process {
        id: notifyProc
        running: false
        stdout: SplitParser {
            onRead: data => { root._notifyOutput += data + "\n"; }
        }
        onExited: {}  // fire and forget
    }

    // ── Add event ───────────────────────────────────────────────────
    function pad2(n) { return ("0" + n).slice(-2); }

    function formatQcalDate(d) {
        return "" + d.getFullYear() + pad2(d.getMonth() + 1) + pad2(d.getDate());
    }

    function formatQcalTime(d) {
        return pad2(d.getHours()) + pad2(d.getMinutes());
    }

    function addEvent() {
        if (!addTitle) return;

        var eventData;
        if (addAllDay) {
            eventData = formatQcalDate(addStartDate) + " " + addTitle;
        } else {
            eventData = formatQcalDate(addStartDate) + " " + formatQcalTime(addStartDate) + " " + formatQcalTime(addEndDate) + " " + addTitle;
        }

        _addOutput = "";
        var cmd = ["python3", root.wrapperPath, "add", "" + addCalendarIdx, eventData];
        if (addLocation) { cmd.push("--location"); cmd.push(addLocation); }
        addProc.command = cmd;
        addProc.running = true;
    }

    Process {
        id: addProc
        running: false
        stdout: SplitParser {
            onRead: data => { root._addOutput += data + "\n"; }
        }
        onExited: (exitCode, exitStatus) => {
            try {
                var json = JSON.parse(root._addOutput.trim());
                if (json.success) {
                    root.addTitle = "";
                    root.addLocation = "";
                    root.addStartDate = new Date();
                    var d = new Date();
                    d.setHours(d.getHours() + 1);
                    root.addEndDate = d;
                    root.addError = "";
                    root.showAddForm = false;
                    // Refresh events after adding
                    root.fetchEvents();
                } else {
                    root.addError = json.error || "Failed to add event";
                }
            } catch (e) {
                root.addError = "Failed to add event";
            }
        }
    }

    // ── Edit event ────────────────────────────────────────────────────
    function openEditForm(ev) {
        editEvent = ev;
        editTitle = ev.title;
        editAllDay = ev.allDay;
        editLocation = ev.location || "";
        editError = "";

        if (ev.allDay) {
            var parts = ev.start.split("-");
            editStartDate = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
            var eParts = ev.end.split("-");
            editEndDate = new Date(parseInt(eParts[0]), parseInt(eParts[1]) - 1, parseInt(eParts[2]));
        } else {
            editStartDate = new Date(ev.start);
            editEndDate = new Date(ev.end);
        }

        showEditForm = true;
        showAddForm = false;
    }

    function saveEdit() {
        if (!editEvent || !editEvent.filename) return;

        var cmdArgs = ["python3", root.wrapperPath, "edit",
            "" + editEvent.calendarIndex, editEvent.filename,
            "--title", editTitle];

        if (editAllDay) {
            cmdArgs.push("--all-day");
            cmdArgs.push("--start-date");
            cmdArgs.push(formatQcalDate(editStartDate));
            cmdArgs.push("--end-date");
            // All-day end in CalDAV is exclusive, so add 1 day
            var endD = new Date(editStartDate.getTime() + 86400000);
            cmdArgs.push(formatQcalDate(endD));
        } else {
            cmdArgs.push("--start-date");
            cmdArgs.push(formatQcalDate(editStartDate));
            cmdArgs.push("--start-time");
            cmdArgs.push(formatQcalTime(editStartDate));
            cmdArgs.push("--end-date");
            cmdArgs.push(formatQcalDate(editEndDate));
            cmdArgs.push("--end-time");
            cmdArgs.push(formatQcalTime(editEndDate));
        }

        cmdArgs.push("--location");
        cmdArgs.push(editLocation);

        _editOutput = "";
        editProc.command = cmdArgs;
        editProc.running = true;
    }

    function deleteEvent() {
        if (!editEvent || !editEvent.filename) return;
        _deleteOutput = "";
        deleteProc.command = ["python3", root.wrapperPath, "delete",
            "" + editEvent.calendarIndex, editEvent.filename];
        deleteProc.running = true;
    }

    Process {
        id: editProc
        running: false
        stdout: SplitParser {
            onRead: data => { root._editOutput += data + "\n"; }
        }
        onExited: (exitCode, exitStatus) => {
            try {
                var json = JSON.parse(root._editOutput.trim());
                if (json.success) {
                    root.showEditForm = false;
                    root.editEvent = null;
                    root.editError = "";
                    root.fetchEvents();
                } else {
                    root.editError = json.error || "Failed to save changes";
                }
            } catch (e) {
                root.editError = "Failed to save changes";
            }
        }
    }

    Process {
        id: deleteProc
        running: false
        stdout: SplitParser {
            onRead: data => { root._deleteOutput += data + "\n"; }
        }
        onExited: (exitCode, exitStatus) => {
            try {
                var json = JSON.parse(root._deleteOutput.trim());
                if (json.success) {
                    root.showEditForm = false;
                    root.editEvent = null;
                    root.editError = "";
                    root.fetchEvents();
                } else {
                    root.editError = json.error || "Failed to delete event";
                }
            } catch (e) {
                root.editError = "Failed to delete event";
            }
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────
    function nextEventSummary() {
        if (isLoading) return "Cal ...";
        if (hasError) return "Cal \u2013";
        if (events.length === 0) return "No events";
        var ev = events[0];
        var timeStr = formatEventTime(ev);
        var dayPrefix = eventDayPrefix(ev);
        // Truncate title for bar pill
        var maxTitle = 20;
        var title = ev.title.length > maxTitle ? ev.title.substring(0, maxTitle - 2) + "\u2026" : ev.title;
        return dayPrefix + timeStr + " " + title;
    }

    function eventDayPrefix(ev) {
        var datePart = ev.start.split("T")[0];
        var parts = datePart.split("-");
        var d = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
        var now = new Date();
        var tomorrow = new Date(now);
        tomorrow.setDate(tomorrow.getDate() + 1);

        var dDay = d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
        var nDay = now.getFullYear() * 10000 + (now.getMonth() + 1) * 100 + now.getDate();
        var tDay = tomorrow.getFullYear() * 10000 + (tomorrow.getMonth() + 1) * 100 + tomorrow.getDate();

        if (dDay === nDay) return "";
        if (dDay === tDay) return "Tmw ";
        var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        return days[d.getDay()] + " ";
    }

    function formatEventTime(ev) {
        if (ev.allDay) return "All day";
        if (ev.start.indexOf("T") === -1) return "All day";
        var parts = ev.start.split("T");
        if (parts.length < 2) return "";
        return parts[1].substring(0, 5);
    }

    function formatEventEndTime(ev) {
        if (ev.allDay) return "";
        if (ev.end.indexOf("T") === -1) return "";
        var parts = ev.end.split("T");
        if (parts.length < 2) return "";
        return parts[1].substring(0, 5);
    }

    function formatDateHeader(dateStr) {
        // dateStr may be "2026-03-10" or "2026-03-10T15:30:00"
        var datePart = dateStr.split("T")[0];
        var parts = datePart.split("-");
        var d = new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
        var now = new Date();
        var tomorrow = new Date(now);
        tomorrow.setDate(tomorrow.getDate() + 1);

        var dDay = d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
        var nDay = now.getFullYear() * 10000 + (now.getMonth() + 1) * 100 + now.getDate();
        var tDay = tomorrow.getFullYear() * 10000 + (tomorrow.getMonth() + 1) * 100 + tomorrow.getDate();

        var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
        var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

        if (dDay === nDay) return "Today";
        if (dDay === tDay) return "Tomorrow";
        return days[d.getDay()] + ", " + months[d.getMonth()] + " " + d.getDate();
    }

    function eventDateKey(ev) {
        return ev.start.split("T")[0];
    }

    function groupedEvents() {
        var groups = [];
        var currentDate = "";
        var currentGroup = null;
        for (var i = 0; i < events.length; i++) {
            var dk = eventDateKey(events[i]);
            if (dk !== currentDate) {
                currentDate = dk;
                currentGroup = { date: events[i].start, events: [] };
                groups.push(currentGroup);
            }
            currentGroup.events.push(events[i]);
        }
        return groups;
    }

    function pillCountText() {
        if (isLoading) return "...";
        if (hasError) return "\u2013";
        return "" + eventCount;
    }

    function calendarNameForIndex(idx) {
        for (var i = 0; i < calendars.length; i++) {
            if (calendars[i].index === idx) return calendars[i].name;
        }
        return "Calendar " + idx;
    }

    // ── Horizontal bar pill ─────────────────────────────────────────
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter

            StyledText {
                text: root.nextEventSummary()
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }
    }

    // ── Vertical bar pill ───────────────────────────────────────────
    verticalBarPill: Component {
        Column {
            spacing: 1
            anchors.horizontalCenter: parent.horizontalCenter

            StyledText {
                text: root.pillCountText()
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: "cal"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // ── Popout panel ────────────────────────────────────────────────
    popoutContent: Component {
        Column {
            spacing: Theme.spacingL
            Component.onCompleted: { root.showAddForm = false; root.showEditForm = false; }

            // ── Header ──────────────────────────────────────────────
            Row {
                width: parent.width

                Column {
                    spacing: Theme.spacingXS

                    StyledText {
                        text: "Calendar"
                        font.pixelSize: Theme.fontSizeXLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        text: root.lastUpdated ? ("Updated " + root.lastUpdated) : ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        visible: root.lastUpdated !== ""
                    }
                }

                Item { width: Theme.spacingM; height: 1 }

                // Refresh button
                Rectangle {
                    width: 28; height: 28
                    radius: Theme.cornerRadius
                    color: mouseRefresh.containsMouse ? Theme.withAlpha(Theme.primary, 0.2) : "transparent"
                    anchors.verticalCenter: parent.verticalCenter

                    DankIcon { anchors.centerIn: parent; name: "refresh"; size: 16; color: Theme.primary }

                    MouseArea {
                        id: mouseRefresh; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.isLoading = true; root.fetchEvents(); root.fetchCalendars(); }
                    }
                }

                // Add event button
                Rectangle {
                    width: 28; height: 28
                    radius: Theme.cornerRadius
                    color: mouseAdd.containsMouse ? Theme.withAlpha(Theme.primary, 0.2) : "transparent"
                    anchors.verticalCenter: parent.verticalCenter

                    StyledText {
                        text: "+"; font.pixelSize: Theme.fontSizeLarge; font.weight: Font.Bold
                        color: Theme.primary; anchors.centerIn: parent
                    }

                    MouseArea {
                        id: mouseAdd; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.showAddForm = !root.showAddForm; root.showEditForm = false; }
                    }
                }
            }

            // ── Error / loading / empty states ──────────────────────
            StyledText {
                text: root.errorText
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                visible: root.hasError
                width: parent.width
                wrapMode: Text.WordWrap
            }

            StyledText {
                text: "Loading events..."
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
                visible: root.isLoading
            }

            StyledText {
                text: "No upcoming events in the next " + root.lookAheadDays + " days."
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeMedium
                visible: !root.isLoading && !root.hasError && root.events.length === 0 && !root.showAddForm
            }

            // ── Add event form ──────────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.showAddForm

                Row {
                    spacing: Theme.spacingS
                    width: parent.width

                    Rectangle {
                        width: 28; height: 28
                        radius: Theme.cornerRadius
                        color: addBackArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"
                        DankIcon { anchors.centerIn: parent; name: "arrow_back"; size: 14; color: Theme.primary }
                        MouseArea {
                            id: addBackArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: root.showAddForm = false
                        }
                    }

                    StyledText {
                        text: "New Event"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Calendar selector
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS
                    visible: root.calendars.length > 0

                    StyledText {
                        text: "Calendar:"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Flow {
                        width: parent.width
                        spacing: Theme.spacingS

                        Repeater {
                            model: root.calendars

                            Rectangle {
                                property bool isReadOnly: modelData.readOnly === true
                                property bool isSelected: root.addCalendarIdx === modelData.index && !isReadOnly

                                width: calBtnRow.width + Theme.spacingM * 2
                                height: 30
                                radius: Theme.cornerRadius
                                color: isSelected
                                    ? Theme.withAlpha(Theme.primary, 0.25)
                                    : Theme.surfaceContainerHigh
                                border.width: isSelected ? 1 : 0
                                border.color: Theme.primary
                                opacity: isReadOnly ? 0.5 : 1.0

                                Row {
                                    id: calBtnRow
                                    anchors.centerIn: parent
                                    spacing: Theme.spacingXS

                                    DankIcon {
                                        name: "lock"
                                        size: 12
                                        color: Theme.surfaceVariantText
                                        visible: isReadOnly
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    StyledText {
                                        text: modelData.name || ("Calendar " + modelData.index)
                                        font.pixelSize: Theme.fontSizeSmall
                                        font.weight: isSelected ? Font.Medium : Font.Normal
                                        color: isSelected ? Theme.primary : Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: isReadOnly ? Qt.ArrowCursor : Qt.PointingHandCursor
                                    onClicked: {
                                        if (!isReadOnly) {
                                            root.addCalendarIdx = modelData.index;
                                            root.addError = "";
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Title
                TextInput {
                    width: parent.width
                    height: 32
                    text: root.addTitle
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    clip: true
                    onTextChanged: root.addTitle = text

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.surfaceText, 0.3)
                        radius: Theme.cornerRadius
                        z: -1
                    }

                    Text {
                        text: "Event title"
                        color: Theme.withAlpha(Theme.surfaceText, 0.3)
                        font.pixelSize: Theme.fontSizeMedium
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingS
                        visible: root.addTitle === ""
                    }

                    leftPadding: Theme.spacingS
                    verticalAlignment: TextInput.AlignVCenter
                }

                // Location
                TextInput {
                    width: parent.width
                    height: 32
                    text: root.addLocation
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    clip: true
                    onTextChanged: root.addLocation = text

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.surfaceText, 0.3)
                        radius: Theme.cornerRadius
                        z: -1
                    }

                    Text {
                        text: "Location (optional)"
                        color: Theme.withAlpha(Theme.surfaceText, 0.3)
                        font.pixelSize: Theme.fontSizeMedium
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingS
                        visible: root.addLocation === ""
                    }

                    leftPadding: Theme.spacingS
                    verticalAlignment: TextInput.AlignVCenter
                }

                // ── Calendar grid date picker ──────────────────────
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS

                    // Month/year navigation header
                    Row {
                        width: parent.width
                        height: 28

                        Rectangle {
                            width: 28; height: 28
                            radius: Theme.cornerRadius
                            color: prevMonthArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"

                            DankIcon {
                                anchors.centerIn: parent
                                name: "chevron_left"
                                size: 14
                                color: Theme.primary
                            }

                            MouseArea {
                                id: prevMonthArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    var d = new Date(root.addStartDate);
                                    d.setMonth(d.getMonth() - 1);
                                    root.addStartDate = d;
                                }
                            }
                        }

                        StyledText {
                            width: parent.width - 56
                            height: 28
                            text: root.addStartDate.toLocaleDateString(Qt.locale(), "MMMM yyyy")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }

                        Rectangle {
                            width: 28; height: 28
                            radius: Theme.cornerRadius
                            color: nextMonthArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"

                            DankIcon {
                                anchors.centerIn: parent
                                name: "chevron_right"
                                size: 14
                                color: Theme.primary
                            }

                            MouseArea {
                                id: nextMonthArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    var d = new Date(root.addStartDate);
                                    d.setMonth(d.getMonth() + 1);
                                    root.addStartDate = d;
                                }
                            }
                        }
                    }

                    // Day-of-week headers
                    Row {
                        width: parent.width
                        height: 18

                        Repeater {
                            model: {
                                var days = [];
                                var loc = Qt.locale();
                                var qtFirst = loc.firstDayOfWeek;
                                for (var i = 0; i < 7; ++i) {
                                    var qtDay = ((qtFirst - 1 + i) % 7) + 1;
                                    days.push(loc.dayName(qtDay, Locale.ShortFormat));
                                }
                                return days;
                            }

                            Rectangle {
                                width: parent.width / 7
                                height: 18
                                color: "transparent"

                                StyledText {
                                    anchors.centerIn: parent
                                    text: modelData
                                    font.pixelSize: 10
                                    color: Theme.withAlpha(Theme.surfaceText, 0.6)
                                    font.weight: Font.Medium
                                }
                            }
                        }
                    }

                    // 6x7 calendar grid
                    Grid {
                        id: datePickerGrid
                        width: parent.width
                        columns: 7
                        rows: 6

                        property int displayMonth: root.addStartDate.getMonth()
                        property int displayYear: root.addStartDate.getFullYear()

                        property date firstDay: {
                            var firstOfMonth = new Date(displayYear, displayMonth, 1);
                            var loc = Qt.locale();
                            var jsFirst = (loc.firstDayOfWeek) % 7;
                            var dow = firstOfMonth.getDay();
                            var diff = (dow - jsFirst + 7) % 7;
                            var d = new Date(firstOfMonth);
                            d.setDate(d.getDate() - diff);
                            return d;
                        }

                        Repeater {
                            model: 42

                            Rectangle {
                                property date dayDate: {
                                    var d = new Date(datePickerGrid.firstDay);
                                    d.setDate(d.getDate() + index);
                                    return d;
                                }
                                property bool isCurrentMonth: dayDate.getMonth() === datePickerGrid.displayMonth
                                property bool isToday: dayDate.toDateString() === new Date().toDateString()
                                property bool isSelected: dayDate.toDateString() === root.addStartDate.toDateString()

                                width: datePickerGrid.width / 7
                                height: 28
                                color: "transparent"

                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 24; height: 24
                                    radius: 12
                                    color: isSelected ? Theme.primary
                                         : isToday ? Theme.withAlpha(Theme.primary, 0.12)
                                         : dayClickArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.08)
                                         : "transparent"

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: dayDate.getDate()
                                        font.pixelSize: 11
                                        color: isSelected ? "#ffffff"
                                             : isToday ? Theme.primary
                                             : isCurrentMonth ? Theme.surfaceText
                                             : Theme.withAlpha(Theme.surfaceText, 0.35)
                                        font.weight: (isToday || isSelected) ? Font.Medium : Font.Normal
                                    }
                                }

                                MouseArea {
                                    id: dayClickArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        var d = new Date(dayDate);
                                        // Preserve the time from the current start date
                                        d.setHours(root.addStartDate.getHours());
                                        d.setMinutes(root.addStartDate.getMinutes());
                                        root.addStartDate = d;
                                        // Also update end date to same day
                                        var e = new Date(root.addEndDate);
                                        e.setFullYear(d.getFullYear());
                                        e.setMonth(d.getMonth());
                                        e.setDate(d.getDate());
                                        root.addEndDate = e;
                                    }
                                }
                            }
                        }
                    }

                    // All-day toggle
                    Row {
                        spacing: Theme.spacingS
                        anchors.horizontalCenter: parent.horizontalCenter

                        Rectangle {
                            width: alldayLabel.width + Theme.spacingM * 2
                            height: 28
                            radius: Theme.cornerRadius
                            color: root.addAllDay
                                ? Theme.withAlpha(Theme.primary, 0.2)
                                : Theme.surfaceContainerHigh

                            StyledText {
                                id: alldayLabel
                                text: "All day"
                                font.pixelSize: Theme.fontSizeSmall
                                color: root.addAllDay ? Theme.primary : Theme.surfaceVariantText
                                anchors.centerIn: parent
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.addAllDay = !root.addAllDay
                            }
                        }
                    }
                }

                // Start/End time picker with editable fields
                Row {
                    spacing: Theme.spacingXS
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: !root.addAllDay

                    property string startHH: ("0" + root.addStartDate.getHours()).slice(-2)
                    property string startMM: ("0" + root.addStartDate.getMinutes()).slice(-2)
                    property string endHH: ("0" + root.addEndDate.getHours()).slice(-2)
                    property string endMM: ("0" + root.addEndDate.getMinutes()).slice(-2)

                    // Reusable helper: clamp + apply typed value
                    function applyTime(target, field, text) {
                        var val = parseInt(text);
                        if (isNaN(val)) return;
                        var d = new Date(target === "start" ? root.addStartDate : root.addEndDate);
                        if (field === "h") d.setHours(Math.max(0, Math.min(23, val)));
                        else d.setMinutes(Math.max(0, Math.min(59, val)));
                        if (target === "start") root.addStartDate = d;
                        else root.addEndDate = d;
                    }

                    StyledText {
                        text: "Start"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // Start hour
                    Column {
                        spacing: 2
                        DankActionButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            iconName: "keyboard_arrow_up"; iconSize: 12; buttonSize: 20
                            iconColor: Theme.withAlpha(Theme.surfaceText, 0.5)
                            onClicked: root.addStartDate = new Date(root.addStartDate.getTime() + 3600000)
                        }
                        TextInput {
                            id: startHourInput
                            width: 28; height: 20
                            horizontalAlignment: TextInput.AlignHCenter
                            verticalAlignment: TextInput.AlignVCenter
                            text: parent.parent.startHH
                            font.pixelSize: Theme.fontSizeSmall
                            font.family: "monospace"
                            color: Theme.surfaceText
                            maximumLength: 2
                            inputMethodHints: Qt.ImhDigitsOnly
                            selectByMouse: true
                            validator: IntValidator { bottom: 0; top: 23 }
                            onEditingFinished: parent.parent.applyTime("start", "h", text)
                            onActiveFocusChanged: if (activeFocus) selectAll()
                            Keys.onTabPressed: startMinInput.forceActiveFocus()
                            onTextChanged: if (activeFocus && text.length === 2) startMinInput.forceActiveFocus()
                        }
                        DankActionButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            iconName: "keyboard_arrow_down"; iconSize: 12; buttonSize: 20
                            iconColor: Theme.withAlpha(Theme.surfaceText, 0.5)
                            onClicked: root.addStartDate = new Date(root.addStartDate.getTime() - 3600000)
                        }
                    }

                    StyledText {
                        text: ":"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // Start minute
                    Column {
                        spacing: 2
                        DankActionButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            iconName: "keyboard_arrow_up"; iconSize: 12; buttonSize: 20
                            iconColor: Theme.withAlpha(Theme.surfaceText, 0.5)
                            onClicked: root.addStartDate = new Date(root.addStartDate.getTime() + 300000)
                        }
                        TextInput {
                            id: startMinInput
                            width: 28; height: 20
                            horizontalAlignment: TextInput.AlignHCenter
                            verticalAlignment: TextInput.AlignVCenter
                            text: parent.parent.startMM
                            font.pixelSize: Theme.fontSizeSmall
                            font.family: "monospace"
                            color: Theme.surfaceText
                            maximumLength: 2
                            inputMethodHints: Qt.ImhDigitsOnly
                            selectByMouse: true
                            validator: IntValidator { bottom: 0; top: 59 }
                            onEditingFinished: parent.parent.applyTime("start", "m", text)
                            onActiveFocusChanged: if (activeFocus) selectAll()
                            Keys.onTabPressed: endHourInput.forceActiveFocus()
                            onTextChanged: if (activeFocus && text.length === 2) endHourInput.forceActiveFocus()
                        }
                        DankActionButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            iconName: "keyboard_arrow_down"; iconSize: 12; buttonSize: 20
                            iconColor: Theme.withAlpha(Theme.surfaceText, 0.5)
                            onClicked: root.addStartDate = new Date(root.addStartDate.getTime() - 300000)
                        }
                    }

                    Item { width: Theme.spacingS; height: 1 }

                    StyledText {
                        text: "End"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // End hour
                    Column {
                        spacing: 2
                        DankActionButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            iconName: "keyboard_arrow_up"; iconSize: 12; buttonSize: 20
                            iconColor: Theme.withAlpha(Theme.surfaceText, 0.5)
                            onClicked: root.addEndDate = new Date(root.addEndDate.getTime() + 3600000)
                        }
                        TextInput {
                            id: endHourInput
                            width: 28; height: 20
                            horizontalAlignment: TextInput.AlignHCenter
                            verticalAlignment: TextInput.AlignVCenter
                            text: parent.parent.endHH
                            font.pixelSize: Theme.fontSizeSmall
                            font.family: "monospace"
                            color: Theme.surfaceText
                            maximumLength: 2
                            inputMethodHints: Qt.ImhDigitsOnly
                            selectByMouse: true
                            validator: IntValidator { bottom: 0; top: 23 }
                            onEditingFinished: parent.parent.applyTime("end", "h", text)
                            onActiveFocusChanged: if (activeFocus) selectAll()
                            Keys.onTabPressed: endMinInput.forceActiveFocus()
                            onTextChanged: if (activeFocus && text.length === 2) endMinInput.forceActiveFocus()
                        }
                        DankActionButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            iconName: "keyboard_arrow_down"; iconSize: 12; buttonSize: 20
                            iconColor: Theme.withAlpha(Theme.surfaceText, 0.5)
                            onClicked: root.addEndDate = new Date(root.addEndDate.getTime() - 3600000)
                        }
                    }

                    StyledText {
                        text: ":"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // End minute
                    Column {
                        spacing: 2
                        DankActionButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            iconName: "keyboard_arrow_up"; iconSize: 12; buttonSize: 20
                            iconColor: Theme.withAlpha(Theme.surfaceText, 0.5)
                            onClicked: root.addEndDate = new Date(root.addEndDate.getTime() + 300000)
                        }
                        TextInput {
                            id: endMinInput
                            width: 28; height: 20
                            horizontalAlignment: TextInput.AlignHCenter
                            verticalAlignment: TextInput.AlignVCenter
                            text: parent.parent.endMM
                            font.pixelSize: Theme.fontSizeSmall
                            font.family: "monospace"
                            color: Theme.surfaceText
                            maximumLength: 2
                            inputMethodHints: Qt.ImhDigitsOnly
                            selectByMouse: true
                            validator: IntValidator { bottom: 0; top: 59 }
                            onEditingFinished: parent.parent.applyTime("end", "m", text)
                            onActiveFocusChanged: if (activeFocus) selectAll()
                            Keys.onTabPressed: event.accepted = true
                        }
                        DankActionButton {
                            anchors.horizontalCenter: parent.horizontalCenter
                            iconName: "keyboard_arrow_down"; iconSize: 12; buttonSize: 20
                            iconColor: Theme.withAlpha(Theme.surfaceText, 0.5)
                            onClicked: root.addEndDate = new Date(root.addEndDate.getTime() - 300000)
                        }
                    }
                }

                // Add error message
                StyledText {
                    text: root.addError
                    font.pixelSize: Theme.fontSizeSmall
                    color: "#ff6b6b"
                    visible: root.addError !== ""
                    width: parent.width
                    wrapMode: Text.WordWrap
                }

                // Submit button
                Rectangle {
                    width: 80
                    height: 32
                    radius: Theme.cornerRadius
                    color: mouseSubmit.containsMouse ? Theme.withAlpha(Theme.primary, 0.3) : Theme.primary

                    StyledText {
                        text: "Add"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: "#ffffff"
                        anchors.centerIn: parent
                    }

                    MouseArea {
                        id: mouseSubmit
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.addEvent()
                    }
                }
            }

            // ── Edit event form ───────────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingS
                visible: root.showEditForm && root.editEvent !== null

                // Header with back button
                Row {
                    spacing: Theme.spacingS
                    width: parent.width

                    Rectangle {
                        width: 28; height: 28
                        radius: Theme.cornerRadius
                        color: editBackArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"

                        DankIcon {
                            anchors.centerIn: parent
                            name: "arrow_back"
                            size: 14
                            color: Theme.primary
                        }

                        MouseArea {
                            id: editBackArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.showEditForm = false; root.editEvent = null; }
                        }
                    }

                    StyledText {
                        text: "Edit Event"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Calendar name (read-only display)
                StyledText {
                    text: root.editEvent ? root.calendarNameForIndex(root.editEvent.calendarIndex) : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                // Title
                TextInput {
                    width: parent.width
                    height: 32
                    text: root.editTitle
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    clip: true
                    onTextChanged: root.editTitle = text

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.surfaceText, 0.3)
                        radius: Theme.cornerRadius
                        z: -1
                    }

                    leftPadding: Theme.spacingS
                    verticalAlignment: TextInput.AlignVCenter
                }

                // Location
                TextInput {
                    width: parent.width
                    height: 32
                    text: root.editLocation
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeMedium
                    clip: true
                    onTextChanged: root.editLocation = text

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.surfaceText, 0.3)
                        radius: Theme.cornerRadius
                        z: -1
                    }

                    Text {
                        text: "Location (optional)"
                        color: Theme.withAlpha(Theme.surfaceText, 0.3)
                        font.pixelSize: Theme.fontSizeMedium
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingS
                        visible: root.editLocation === ""
                    }

                    leftPadding: Theme.spacingS
                    verticalAlignment: TextInput.AlignVCenter
                }

                // Calendar grid for edit
                Column {
                    width: parent.width
                    spacing: Theme.spacingXS

                    Row {
                        width: parent.width
                        height: 28

                        Rectangle {
                            width: 28; height: 28
                            radius: Theme.cornerRadius
                            color: editPrevMonth.containsMouse ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"
                            DankIcon { anchors.centerIn: parent; name: "chevron_left"; size: 14; color: Theme.primary }
                            MouseArea {
                                id: editPrevMonth; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { var d = new Date(root.editStartDate); d.setMonth(d.getMonth() - 1); root.editStartDate = d; }
                            }
                        }

                        StyledText {
                            width: parent.width - 56; height: 28
                            text: root.editStartDate.toLocaleDateString(Qt.locale(), "MMMM yyyy")
                            font.pixelSize: Theme.fontSizeMedium; font.weight: Font.Medium
                            color: Theme.surfaceText
                            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
                        }

                        Rectangle {
                            width: 28; height: 28
                            radius: Theme.cornerRadius
                            color: editNextMonth.containsMouse ? Theme.withAlpha(Theme.primary, 0.12) : "transparent"
                            DankIcon { anchors.centerIn: parent; name: "chevron_right"; size: 14; color: Theme.primary }
                            MouseArea {
                                id: editNextMonth; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { var d = new Date(root.editStartDate); d.setMonth(d.getMonth() + 1); root.editStartDate = d; }
                            }
                        }
                    }

                    Row {
                        width: parent.width; height: 18
                        Repeater {
                            model: {
                                var days = []; var loc = Qt.locale(); var qtFirst = loc.firstDayOfWeek;
                                for (var i = 0; i < 7; ++i) { var qtDay = ((qtFirst - 1 + i) % 7) + 1; days.push(loc.dayName(qtDay, Locale.ShortFormat)); }
                                return days;
                            }
                            Rectangle {
                                width: parent.width / 7; height: 18; color: "transparent"
                                StyledText { anchors.centerIn: parent; text: modelData; font.pixelSize: 10; color: Theme.withAlpha(Theme.surfaceText, 0.6); font.weight: Font.Medium }
                            }
                        }
                    }

                    Grid {
                        id: editDateGrid
                        width: parent.width; columns: 7; rows: 6

                        property int displayMonth: root.editStartDate.getMonth()
                        property int displayYear: root.editStartDate.getFullYear()
                        property date firstDay: {
                            var firstOfMonth = new Date(displayYear, displayMonth, 1);
                            var jsFirst = (Qt.locale().firstDayOfWeek) % 7;
                            var dow = firstOfMonth.getDay();
                            var diff = (dow - jsFirst + 7) % 7;
                            var d = new Date(firstOfMonth); d.setDate(d.getDate() - diff); return d;
                        }

                        Repeater {
                            model: 42
                            Rectangle {
                                property date dayDate: { var d = new Date(editDateGrid.firstDay); d.setDate(d.getDate() + index); return d; }
                                property bool isCurrentMonth: dayDate.getMonth() === editDateGrid.displayMonth
                                property bool isToday: dayDate.toDateString() === new Date().toDateString()
                                property bool isSelected: dayDate.toDateString() === root.editStartDate.toDateString()

                                width: editDateGrid.width / 7; height: 28; color: "transparent"

                                Rectangle {
                                    anchors.centerIn: parent; width: 24; height: 24; radius: 12
                                    color: isSelected ? Theme.primary : isToday ? Theme.withAlpha(Theme.primary, 0.12) : editDayArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.08) : "transparent"
                                    StyledText {
                                        anchors.centerIn: parent; text: dayDate.getDate(); font.pixelSize: 11
                                        color: isSelected ? "#ffffff" : isToday ? Theme.primary : isCurrentMonth ? Theme.surfaceText : Theme.withAlpha(Theme.surfaceText, 0.35)
                                        font.weight: (isToday || isSelected) ? Font.Medium : Font.Normal
                                    }
                                }
                                MouseArea {
                                    id: editDayArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        var d = new Date(dayDate);
                                        d.setHours(root.editStartDate.getHours()); d.setMinutes(root.editStartDate.getMinutes());
                                        root.editStartDate = d;
                                        var e = new Date(root.editEndDate);
                                        e.setFullYear(d.getFullYear()); e.setMonth(d.getMonth()); e.setDate(d.getDate());
                                        root.editEndDate = e;
                                    }
                                }
                            }
                        }
                    }

                    // All-day toggle
                    Row {
                        spacing: Theme.spacingS
                        anchors.horizontalCenter: parent.horizontalCenter
                        Rectangle {
                            width: editAlldayLabel.width + Theme.spacingM * 2; height: 28
                            radius: Theme.cornerRadius
                            color: root.editAllDay ? Theme.withAlpha(Theme.primary, 0.2) : Theme.surfaceContainerHigh
                            StyledText { id: editAlldayLabel; text: "All day"; font.pixelSize: Theme.fontSizeSmall; color: root.editAllDay ? Theme.primary : Theme.surfaceVariantText; anchors.centerIn: parent }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.editAllDay = !root.editAllDay }
                        }
                    }
                }

                // Edit time pickers
                Row {
                    spacing: Theme.spacingXS
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: !root.editAllDay

                    property string startHH: ("0" + root.editStartDate.getHours()).slice(-2)
                    property string startMM: ("0" + root.editStartDate.getMinutes()).slice(-2)
                    property string endHH: ("0" + root.editEndDate.getHours()).slice(-2)
                    property string endMM: ("0" + root.editEndDate.getMinutes()).slice(-2)

                    function applyTime(target, field, text) {
                        var val = parseInt(text);
                        if (isNaN(val)) return;
                        var d = new Date(target === "start" ? root.editStartDate : root.editEndDate);
                        if (field === "h") d.setHours(Math.max(0, Math.min(23, val)));
                        else d.setMinutes(Math.max(0, Math.min(59, val)));
                        if (target === "start") root.editStartDate = d;
                        else root.editEndDate = d;
                    }

                    StyledText { text: "Start"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText; anchors.verticalCenter: parent.verticalCenter }

                    Column {
                        spacing: 2
                        DankActionButton { anchors.horizontalCenter: parent.horizontalCenter; iconName: "keyboard_arrow_up"; iconSize: 12; buttonSize: 20; iconColor: Theme.withAlpha(Theme.surfaceText, 0.5); onClicked: root.editStartDate = new Date(root.editStartDate.getTime() + 3600000) }
                        TextInput {
                            id: editStartHourInput
                            width: 28; height: 20; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                            text: parent.parent.startHH; font.pixelSize: Theme.fontSizeSmall; font.family: "monospace"; color: Theme.surfaceText
                            maximumLength: 2; inputMethodHints: Qt.ImhDigitsOnly; selectByMouse: true
                            validator: IntValidator { bottom: 0; top: 23 }
                            onEditingFinished: parent.parent.applyTime("start", "h", text)
                            onActiveFocusChanged: if (activeFocus) selectAll()
                            Keys.onTabPressed: editStartMinInput.forceActiveFocus()
                            onTextChanged: if (activeFocus && text.length === 2) editStartMinInput.forceActiveFocus()
                        }
                        DankActionButton { anchors.horizontalCenter: parent.horizontalCenter; iconName: "keyboard_arrow_down"; iconSize: 12; buttonSize: 20; iconColor: Theme.withAlpha(Theme.surfaceText, 0.5); onClicked: root.editStartDate = new Date(root.editStartDate.getTime() - 3600000) }
                    }

                    StyledText { text: ":"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }

                    Column {
                        spacing: 2
                        DankActionButton { anchors.horizontalCenter: parent.horizontalCenter; iconName: "keyboard_arrow_up"; iconSize: 12; buttonSize: 20; iconColor: Theme.withAlpha(Theme.surfaceText, 0.5); onClicked: root.editStartDate = new Date(root.editStartDate.getTime() + 300000) }
                        TextInput {
                            id: editStartMinInput
                            width: 28; height: 20; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                            text: parent.parent.startMM; font.pixelSize: Theme.fontSizeSmall; font.family: "monospace"; color: Theme.surfaceText
                            maximumLength: 2; inputMethodHints: Qt.ImhDigitsOnly; selectByMouse: true
                            validator: IntValidator { bottom: 0; top: 59 }
                            onEditingFinished: parent.parent.applyTime("start", "m", text)
                            onActiveFocusChanged: if (activeFocus) selectAll()
                            Keys.onTabPressed: editEndHourInput.forceActiveFocus()
                            onTextChanged: if (activeFocus && text.length === 2) editEndHourInput.forceActiveFocus()
                        }
                        DankActionButton { anchors.horizontalCenter: parent.horizontalCenter; iconName: "keyboard_arrow_down"; iconSize: 12; buttonSize: 20; iconColor: Theme.withAlpha(Theme.surfaceText, 0.5); onClicked: root.editStartDate = new Date(root.editStartDate.getTime() - 300000) }
                    }

                    Item { width: Theme.spacingS; height: 1 }

                    StyledText { text: "End"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText; anchors.verticalCenter: parent.verticalCenter }

                    Column {
                        spacing: 2
                        DankActionButton { anchors.horizontalCenter: parent.horizontalCenter; iconName: "keyboard_arrow_up"; iconSize: 12; buttonSize: 20; iconColor: Theme.withAlpha(Theme.surfaceText, 0.5); onClicked: root.editEndDate = new Date(root.editEndDate.getTime() + 3600000) }
                        TextInput {
                            id: editEndHourInput
                            width: 28; height: 20; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                            text: parent.parent.endHH; font.pixelSize: Theme.fontSizeSmall; font.family: "monospace"; color: Theme.surfaceText
                            maximumLength: 2; inputMethodHints: Qt.ImhDigitsOnly; selectByMouse: true
                            validator: IntValidator { bottom: 0; top: 23 }
                            onEditingFinished: parent.parent.applyTime("end", "h", text)
                            onActiveFocusChanged: if (activeFocus) selectAll()
                            Keys.onTabPressed: editEndMinInput.forceActiveFocus()
                            onTextChanged: if (activeFocus && text.length === 2) editEndMinInput.forceActiveFocus()
                        }
                        DankActionButton { anchors.horizontalCenter: parent.horizontalCenter; iconName: "keyboard_arrow_down"; iconSize: 12; buttonSize: 20; iconColor: Theme.withAlpha(Theme.surfaceText, 0.5); onClicked: root.editEndDate = new Date(root.editEndDate.getTime() - 3600000) }
                    }

                    StyledText { text: ":"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceText; anchors.verticalCenter: parent.verticalCenter }

                    Column {
                        spacing: 2
                        DankActionButton { anchors.horizontalCenter: parent.horizontalCenter; iconName: "keyboard_arrow_up"; iconSize: 12; buttonSize: 20; iconColor: Theme.withAlpha(Theme.surfaceText, 0.5); onClicked: root.editEndDate = new Date(root.editEndDate.getTime() + 300000) }
                        TextInput {
                            id: editEndMinInput
                            width: 28; height: 20; horizontalAlignment: TextInput.AlignHCenter; verticalAlignment: TextInput.AlignVCenter
                            text: parent.parent.endMM; font.pixelSize: Theme.fontSizeSmall; font.family: "monospace"; color: Theme.surfaceText
                            maximumLength: 2; inputMethodHints: Qt.ImhDigitsOnly; selectByMouse: true
                            validator: IntValidator { bottom: 0; top: 59 }
                            onEditingFinished: parent.parent.applyTime("end", "m", text)
                            onActiveFocusChanged: if (activeFocus) selectAll()
                            Keys.onTabPressed: event.accepted = true
                        }
                        DankActionButton { anchors.horizontalCenter: parent.horizontalCenter; iconName: "keyboard_arrow_down"; iconSize: 12; buttonSize: 20; iconColor: Theme.withAlpha(Theme.surfaceText, 0.5); onClicked: root.editEndDate = new Date(root.editEndDate.getTime() - 300000) }
                    }
                }

                // Edit error message
                StyledText {
                    text: root.editError
                    font.pixelSize: Theme.fontSizeSmall
                    color: "#ff6b6b"
                    visible: root.editError !== ""
                    width: parent.width
                    wrapMode: Text.WordWrap
                }

                // Save and Delete buttons
                Row {
                    spacing: Theme.spacingM

                    Rectangle {
                        width: 80; height: 32
                        radius: Theme.cornerRadius
                        color: mouseSave.containsMouse ? Theme.withAlpha(Theme.primary, 0.3) : Theme.primary
                        StyledText { text: "Save"; font.pixelSize: Theme.fontSizeMedium; font.weight: Font.Medium; color: "#ffffff"; anchors.centerIn: parent }
                        MouseArea { id: mouseSave; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.saveEdit() }
                    }

                    Rectangle {
                        width: 80; height: 32
                        radius: Theme.cornerRadius
                        color: mouseDelete.containsMouse ? Theme.withAlpha("#ff6b6b", 0.3) : Theme.withAlpha("#ff6b6b", 0.15)
                        StyledText { text: "Delete"; font.pixelSize: Theme.fontSizeMedium; font.weight: Font.Medium; color: "#ff6b6b"; anchors.centerIn: parent }
                        MouseArea { id: mouseDelete; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.deleteEvent() }
                    }
                }
            }

            // ── Grouped events ──────────────────────────────────────
            Column {
                width: parent.width
                spacing: Theme.spacingM
                visible: !root.isLoading && !root.hasError && root.events.length > 0 && !root.showEditForm

                Repeater {
                    model: root.groupedEvents()

                    Column {
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            text: root.formatDateHeader(modelData.date)
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.primary
                        }

                        Repeater {
                            model: modelData.events

                            StyledRect {
                                width: parent.width
                                height: eventCol.height + Theme.spacingM * 2
                                radius: Theme.cornerRadius
                                color: eventClickArea.containsMouse
                                    ? Theme.withAlpha(Theme.primary, 0.12)
                                    : Theme.surfaceContainerHigh

                                Column {
                                    id: eventCol
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXS

                                    StyledText {
                                        text: modelData.title
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        width: parent.width
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        text: {
                                            if (modelData.allDay) return "All day";
                                            var start = root.formatEventTime(modelData);
                                            var end = root.formatEventEndTime(modelData);
                                            return end ? (start + " \u2013 " + end) : start;
                                        }
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }

                                    StyledText {
                                        text: modelData.location
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                        visible: root.showLocation && (modelData.location || "") !== ""
                                        width: parent.width
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        text: root.calendarNameForIndex(modelData.calendarIndex)
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                        visible: root.showCalendarName && root.calendarNameForIndex(modelData.calendarIndex) !== ""
                                        width: parent.width
                                        elide: Text.ElideRight
                                    }
                                }

                                MouseArea {
                                    id: eventClickArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: modelData.filename ? Qt.PointingHandCursor : Qt.ArrowCursor
                                    onClicked: {
                                        if (modelData.filename) root.openEditForm(modelData);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    popoutWidth: 380
    popoutHeight: 620
}

import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "qcalCalendar"

    StyledText {
        text: "CalDAV Account"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StringSetting {
        settingKey: "caldavUrl"
        label: "CalDAV URL"
        description: "Base URL of your CalDAV server. All calendars under this account will be discovered automatically."
        placeholder: "https://caldav.icloud.com"
    }

    StringSetting {
        settingKey: "caldavUsername"
        label: "Username"
        placeholder: "user@example.com"
    }

    StringSetting {
        settingKey: "caldavPassword"
        label: "Password"
        description: "App-specific password for your CalDAV account"
        placeholder: "Enter password..."
        password: true
    }

    StyledText {
        width: parent.width
        text: "To use multiple CalDAV providers, edit the config file directly: <a href=\"file://" + Quickshell.env("HOME") + "/.config/qcal/config.json\">" + Quickshell.env("HOME") + "/.config/qcal/config.json</a>"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
        linkColor: Theme.primary
        onLinkActivated: link => Qt.openUrlExternally(link)
    }

    StyledText {
        text: "Display"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    SliderSetting {
        settingKey: "lookAheadDays"
        label: "Look-ahead (days)"
        description: "How many days into the future to show events"
        minimum: 1
        maximum: 30
        defaultValue: 7
    }

    SliderSetting {
        settingKey: "refreshInterval"
        label: "Refresh interval (minutes)"
        description: "How often to fetch events from the CalDAV server"
        minimum: 1
        maximum: 30
        defaultValue: 5
    }

    ToggleSetting {
        settingKey: "showLocation"
        label: "Show event location"
        description: "Display the location for events that have one"
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "showCalendarName"
        label: "Show calendar name"
        description: "Display which calendar each event belongs to"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "notificationsEnabled"
        label: "Desktop notifications"
        description: "Send a notification before upcoming events"
        defaultValue: true
    }

    SliderSetting {
        settingKey: "notifyMinutes"
        label: "Notify before (minutes)"
        description: "How many minutes before an event to send a notification"
        minimum: 1
        maximum: 60
        defaultValue: 15
    }
}

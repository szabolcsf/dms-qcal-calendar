# qCal Calendar — DankMaterialShell Plugin

A DankBar widget that shows upcoming CalDAV calendar events with a full popout panel for viewing, creating, editing, and deleting events.

![type:widget](https://img.shields.io/badge/type-widget-blue)
![capability:dankbar-widget](https://img.shields.io/badge/capability-dankbar--widget-green)

![screenshot](screenshot.png)

## Features

- Works with iCloud, Google, Nextcloud, and any CalDAV server
- **Native Google Calendar support** via REST API with OAuth2 (no CalDAV API setup needed)
- Auto-discovery of all calendars under a CalDAV account
- GNOME Keyring integration (falls back to plaintext config if unavailable)
- Create, edit, and delete events directly from the popout
- Scrollable event list in the popout panel
- Desktop notifications before upcoming events
- Per-calendar name display and event location display
- Configurable look-ahead window and refresh interval

## Bar Display

- **Horizontal pill**: shows the next upcoming event with time and title (e.g. `14:00 Meeting`)
- **Vertical pill**: shows the total event count with a "cal" label

## Popout Panel

- Grouped event list by day with time ranges
- Color-coded all-day and timed events
- Click an event to edit title, time, and location
- Add new events with calendar selection, date/time pickers, and optional location
- Last updated timestamp

## Settings

| Setting | Description | Default |
|---|---|---|
| CalDAV URL | Base URL of your CalDAV server (calendars are auto-discovered) | — |
| Username | CalDAV account username | — |
| Password | App-specific password (stored in GNOME Keyring when available) | — |
| Look-ahead (days) | How many days into the future to show events | 7 |
| Refresh interval (minutes) | How often to fetch events from the server | 5 |
| Show event location | Display location for events that have one | On |
| Show calendar name | Display which calendar each event belongs to | Off |
| Desktop notifications | Send a notification before upcoming events | On |
| Notify before (minutes) | How far in advance to notify | 15 |

Multiple CalDAV providers can be configured by editing `~/.config/qcal/config.json` directly.

## Google Calendar Setup

Google Calendar uses OAuth2 via the REST API instead of CalDAV. You need your own Google Cloud OAuth credentials (one-time setup):

### 1. Create Google Cloud OAuth credentials

1. Go to [Google Cloud Console](https://console.cloud.google.com) and create a project
2. Enable the **Google Calendar API** (APIs & Services > Library)
3. Configure the **OAuth consent screen** (External, add your email as a test user)
4. Create **OAuth client ID** credentials (Desktop app type)
5. Note the **Client ID** and **Client Secret**

### 2. Configure `~/.config/qcal/config.json`

Add your OAuth credentials and calendar entries:

```json
{
    "Timezone": "Europe/Lisbon",
    "DefaultNumDays": 14,
    "GoogleOAuth": {
        "you@gmail.com": {
            "ClientId": "YOUR_CLIENT_ID.apps.googleusercontent.com",
            "ClientSecret": "YOUR_CLIENT_SECRET"
        }
    },
    "Calendars": [],
    "GoogleCalendars": [
        {
            "Account": "you@gmail.com",
            "CalendarId": "you@gmail.com",
            "Name": "Personal",
            "ReadOnly": false
        }
    ]
}
```

### 3. Authorize and discover calendars

```bash
# Authorize (opens browser for Google login)
python3 qcal-wrapper.py discover-google you@gmail.com --authorize

# Or if you already have a refresh token stored in GNOME Keyring:
python3 qcal-wrapper.py discover-google you@gmail.com
```

This discovers all calendars under the account and writes them to `config.json`. You can then edit the file to keep only the calendars you want.

### Multiple Google accounts

Add each account to the `GoogleOAuth` section with its own credentials, and run `discover-google` for each:

```bash
python3 qcal-wrapper.py discover-google work@company.com --authorize
python3 qcal-wrapper.py discover-google personal@gmail.com --authorize
```

Refresh tokens are stored securely in GNOME Keyring and refresh automatically.

## Dependencies

- `python3`
- `go` (build-time only, for compiling qcal)
- `secret-tool` (optional, for GNOME Keyring password storage)

## Installation

```bash
git clone --recurse-submodules https://github.com/szabolcsf/dms-qcal-calendar.git
cd dms-qcal-calendar
./setup.sh  # builds the qcal binary
cp -r . ~/.config/DankMaterialShell/plugins/qcalCalendar
```

Then enable the plugin in DMS Settings → Plugins, and add it to your DankBar. Configure your CalDAV account in the plugin settings.

## Compositors

Tested on Niri. Should work on any compositor supported by DankMaterialShell.

## License

MIT

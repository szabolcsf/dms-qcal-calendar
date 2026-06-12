#!/usr/bin/env python3
"""Wrapper around qcal that parses its text output into JSON.

Usage:
    qcal-wrapper.py list [--days N]        List upcoming events as JSON
    qcal-wrapper.py add <calendar> <args>  Add an event via qcal -n
    qcal-wrapper.py calendars              List configured calendars as JSON
    qcal-wrapper.py discover <url> <user> <pass>  Discover calendars and write config
    qcal-wrapper.py notify [--minutes N]   Check for imminent events and send desktop notification
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:  # pragma: no cover - py<3.9
    ZoneInfo = None

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
QCAL_BIN = os.path.join(SCRIPT_DIR, "qcal", "qcal")
NOTIFY_STATE_FILE = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
    "qcal-dms",
    "notified.json",
)

KEYRING_SERVICE = "qcal-caldav"


def has_secret_tool() -> bool:
    """Check if secret-tool (libsecret CLI) is available."""
    import shutil
    return shutil.which("secret-tool") is not None


def keyring_store(username: str, password: str) -> bool:
    """Store password in GNOME Keyring. Returns True on success."""
    try:
        proc = subprocess.run(
            ["secret-tool", "store", "--label", f"qcal CalDAV ({username})",
             "service", KEYRING_SERVICE, "account", username],
            input=password, capture_output=True, text=True, timeout=10,
        )
        return proc.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def keyring_lookup_cmd(username: str) -> str:
    """Return the shell command to look up a password from GNOME Keyring."""
    return f"secret-tool lookup service {KEYRING_SERVICE} account {username}"


# ANSI escape code stripper
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# qcal output patterns (after stripping ANSI + optional color block)
# Timed event:  |  Mon 01.12.06 15:04 Summary (ends 17:00)
# All-day:      |  Mon 01.12.06        Summary
# All-day multi:|  Mon 01.12.06        Summary (ends 10.12.06)
# The | and • are calendar color indicators

# With -nwd (no weekday):
# Timed:  | 01.12.06 15:04 Summary (ends 17:00)
# Allday: | 01.12.06        Summary

EVENT_LINE_RE = re.compile(
    r"^[|•\s]*"               # color block, dot, spaces
    r"(?:[A-Z][a-z]{2}\s+)?"  # optional weekday (Mon, Tue, ...)
    r"(\d{2}\.\d{2}\.\d{2})"  # date DD.MM.YY
    r"\s+"
    r"(?:(\d{2}:\d{2})\s+)?"  # optional time HH:MM
    r"(.+)$"                   # summary (may contain "(ends ...)")
)

ENDS_TIME_RE = re.compile(r"\(ends\s+(\d{2}:\d{2})\)\s*$")
ENDS_DATE_RE = re.compile(r"\(ends\s+(\d{2}\.\d{2}\.\d{2})\)\s*$")

INFO_RE = re.compile(r"^\s{10,}(Description|Location|Attendee):\s*(.*)$")
FILENAME_RE = re.compile(r"^[0-9a-fA-F-]+\.ics$")

# Calendar list: [0] - | Calendar Name (hostname.example.com)
CAL_LIST_RE = re.compile(
    r"^\[(\d+)\]\s*-\s*[|•\s]*\s*(.+?)\s*\(([^)]+)\)\s*$"
)


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def run_qcal(*args: str) -> str:
    """Run qcal and return its stdout (ANSI stripped). Returns empty string on errors."""
    cmd = [QCAL_BIN] + list(args)
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30
        )
        return strip_ansi(result.stdout)
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        print(json.dumps({"error": str(e)}), file=sys.stderr)
        return ""


def parse_events(output: str) -> list[dict]:
    """Parse qcal text output into structured event dicts."""
    events = []

    for line in output.splitlines():
        line = line.rstrip()
        if not line:
            continue

        # Check for filename lines (from -f flag): UUID.ics
        if FILENAME_RE.match(line.strip()) and events:
            events[-1]["filename"] = line.strip()
            continue

        # Check for info lines (indented Description/Location/Attendee)
        info_match = INFO_RE.match(line)
        if info_match and events:
            key = info_match.group(1).lower()
            val = info_match.group(2).strip()
            if key == "location":
                events[-1]["location"] = val
            elif key == "description":
                events[-1]["description"] = val
            elif key == "attendee":
                events[-1].setdefault("attendees", []).append(val)
            continue

        # Try to match an event line
        m = EVENT_LINE_RE.match(line)
        if not m:
            continue

        date_str = m.group(1)  # DD.MM.YY
        time_str = m.group(2)  # HH:MM or None
        summary = m.group(3).strip()

        # Parse date
        try:
            dt = datetime.strptime(date_str, "%d.%m.%y")
        except ValueError:
            continue

        is_allday = time_str is None
        end_time = None
        end_date = None

        # Extract "(ends ...)" from summary
        ends_time_match = ENDS_TIME_RE.search(summary)
        ends_date_match = ENDS_DATE_RE.search(summary)

        if ends_time_match:
            end_time = ends_time_match.group(1)
            summary = summary[:ends_time_match.start()].strip()
        elif ends_date_match:
            try:
                end_date = datetime.strptime(ends_date_match.group(1), "%d.%m.%y")
            except ValueError:
                pass
            summary = summary[:ends_date_match.start()].strip()

        # Build start/end ISO strings
        if is_allday:
            start_iso = dt.strftime("%Y-%m-%d")
            if end_date:
                end_iso = end_date.strftime("%Y-%m-%d")
            else:
                end_iso = (dt + timedelta(days=1)).strftime("%Y-%m-%d")
        else:
            h, mi = (int(x) for x in time_str.split(":"))
            start_dt = dt.replace(hour=h, minute=mi)
            start_iso = start_dt.isoformat()
            if end_time:
                eh, emi = (int(x) for x in end_time.split(":"))
                end_dt = dt.replace(hour=eh, minute=emi)
                # Handle end time past midnight
                if end_dt <= start_dt:
                    end_dt += timedelta(days=1)
                end_iso = end_dt.isoformat()
            else:
                end_iso = start_iso

        events.append({
            "title": summary,
            "start": start_iso,
            "end": end_iso,
            "allDay": is_allday,
            "location": "",
            "description": "",
        })

    return events


def parse_calendars(output: str) -> list[dict]:
    """Parse qcal -l output into calendar list."""
    cals = []
    for line in output.splitlines():
        m = CAL_LIST_RE.match(line.strip())
        if m:
            cals.append({
                "index": int(m.group(1)),
                "name": m.group(2).strip(),
                "host": m.group(3).strip(),
            })
    return cals


# ────────────────────────────────────────────────────────────────────
# ICS feed support (read-only "secret address in iCal format" URLs)
#
# Google/Outlook/etc. expose a private .ics URL that returns a full
# VCALENDAR. qcal only speaks CalDAV, so these feeds are fetched and
# parsed here, then merged into the event list as read-only calendars.
# ────────────────────────────────────────────────────────────────────

_WEEKDAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}


def load_ics_calendars(config: dict) -> list[dict]:
    """ICS feeds from config: [{"Url": ..., "Name": ...}, ...]."""
    cals = config.get("IcsCalendars", [])
    return cals if isinstance(cals, list) else []


def _config_zone(config: dict):
    """ZoneInfo for the configured display timezone (None if unavailable)."""
    name = config.get("Timezone", "") or "UTC"
    if ZoneInfo is None:
        return None
    try:
        return ZoneInfo(name)
    except Exception:
        return None


def fetch_ics(url: str) -> str:
    """Download an ICS feed. Returns text, or "" on failure."""
    import urllib.request
    import ssl

    ctx = ssl.create_default_context()
    # webcal:// is just http(s) in disguise
    if url.startswith("webcal://"):
        url = "https://" + url[len("webcal://"):]
    req = urllib.request.Request(url, headers={"User-Agent": "qcal-dms/1.0"})
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=20) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        print(json.dumps({"error": f"ICS fetch failed: {e}"}), file=sys.stderr)
        return ""


def _unfold_ics(text: str) -> list[str]:
    """Undo RFC 5545 line folding (continuation lines start with space/tab)."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    out: list[str] = []
    for line in text.split("\n"):
        if line[:1] in (" ", "\t") and out:
            out[-1] += line[1:]
        else:
            out.append(line)
    return out


def _parse_prop(line: str):
    """Split a content line into (NAME, params_dict, value)."""
    idx = line.find(":")
    if idx == -1:
        return None
    head, value = line[:idx], line[idx + 1:]
    parts = head.split(";")
    name = parts[0].upper()
    params = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            params[k.upper()] = v.strip('"')
    return name, params, value


def _unescape_text(v: str) -> str:
    return (v.replace("\\N", "\n").replace("\\n", "\n")
             .replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\"))


def _safe_zone(tzid: str):
    if ZoneInfo is None or not tzid:
        return None
    try:
        return ZoneInfo(tzid)
    except Exception:
        return None


def _parse_ics_dt(value: str, params: dict, config_zone):
    """Parse an ICS date/datetime value.

    Returns (naive datetime in the display timezone, is_all_day).
    Floating times (no Z, no TZID) are treated as already-local.
    """
    value = value.strip()
    is_date = params.get("VALUE") == "DATE" or ("T" not in value and len(value) >= 8)
    if is_date:
        return datetime.strptime(value[:8], "%Y%m%d"), True

    base = value.rstrip("Z")
    try:
        dt = datetime.strptime(base[:15], "%Y%m%dT%H%M%S")
    except ValueError:
        try:
            dt = datetime.strptime(base[:13], "%Y%m%dT%H%M")
        except ValueError:
            return datetime.strptime(value[:8], "%Y%m%d"), True

    src_zone = None
    if value.endswith("Z"):
        src_zone = timezone.utc
    else:
        src_zone = _safe_zone(params.get("TZID", ""))

    if src_zone is not None and config_zone is not None:
        dt = dt.replace(tzinfo=src_zone).astimezone(config_zone).replace(tzinfo=None)
    return dt, False


def _parse_duration(value: str) -> timedelta:
    """Parse an ICS DURATION (e.g. PT1H30M, P1D, P1DT2H). Best-effort."""
    m = re.match(
        r"^[+-]?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$",
        value.strip(),
    )
    if not m:
        return timedelta(0)
    w, d, h, mi, s = (int(x) if x else 0 for x in m.groups())
    td = timedelta(weeks=w, days=d, hours=h, minutes=mi, seconds=s)
    return -td if value.strip().startswith("-") else td


def _parse_rrule(value: str) -> dict:
    out = {}
    for kv in value.split(";"):
        if "=" in kv:
            k, v = kv.split("=", 1)
            out[k.upper()] = v
    return out


def _nth_weekday(year: int, month: int, weekday: int, n: int):
    """Date of the nth (1-based; negative from end) weekday in a month."""
    import calendar
    days = [d for d in range(1, calendar.monthrange(year, month)[1] + 1)
            if datetime(year, month, d).weekday() == weekday]
    if not days:
        return None
    try:
        return days[n - 1] if n > 0 else days[n]
    except IndexError:
        return None


def _add_months(dt: datetime, months: int) -> datetime:
    m = dt.month - 1 + months
    year = dt.year + m // 12
    month = m % 12 + 1
    import calendar
    day = min(dt.day, calendar.monthrange(year, month)[1])
    return dt.replace(year=year, month=month, day=day)


def _expand_rrule(dtstart: datetime, rrule: dict, window_end: datetime,
                  config_zone) -> list[datetime]:
    """Expand a recurrence rule into start datetimes up to window_end.

    Handles the common cases (DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, COUNT,
    UNTIL, weekly BYDAY, monthly BYDAY/BYMONTHDAY). Unknown rules fall back
    to the single DTSTART occurrence.
    """
    freq = rrule.get("FREQ", "").upper()
    interval = max(1, int(rrule.get("INTERVAL", "1") or "1"))
    count = int(rrule["COUNT"]) if rrule.get("COUNT", "").isdigit() else None

    until = None
    if "UNTIL" in rrule:
        u = rrule["UNTIL"]
        try:
            if u.endswith("Z"):
                until = (datetime.strptime(u, "%Y%m%dT%H%M%SZ")
                         .replace(tzinfo=timezone.utc))
                if config_zone is not None:
                    until = until.astimezone(config_zone)
                until = until.replace(tzinfo=None)
            elif "T" in u:
                until = datetime.strptime(u[:15], "%Y%m%dT%H%M%S")
            else:
                until = datetime.strptime(u[:8], "%Y%m%d").replace(
                    hour=23, minute=59, second=59)
        except ValueError:
            until = None

    hard_stop = window_end + timedelta(days=1)
    occurrences: list[datetime] = []

    def emit(dt: datetime) -> bool:
        """Append dt if within bounds. Returns False when the series ends."""
        if until is not None and dt > until:
            return False
        if dt > hard_stop:
            return False
        occurrences.append(dt)
        return not (count is not None and len(occurrences) >= count)

    byday = rrule.get("BYDAY", "")

    if freq == "DAILY":
        cur = dtstart
        guard = 0
        while emit(cur) and guard < 5000:
            cur += timedelta(days=interval)
            guard += 1

    elif freq == "WEEKLY":
        weekdays = []
        for tok in byday.split(","):
            tok = tok.strip()[-2:].upper()
            if tok in _WEEKDAYS:
                weekdays.append(_WEEKDAYS[tok])
        if not weekdays:
            weekdays = [dtstart.weekday()]
        weekdays = sorted(set(weekdays))
        # Monday of dtstart's week
        week0 = dtstart - timedelta(days=dtstart.weekday())
        guard = 0
        running = True
        while running and guard < 1000:
            for wd in weekdays:
                cand = (week0 + timedelta(weeks=interval * guard, days=wd)).replace(
                    hour=dtstart.hour, minute=dtstart.minute,
                    second=dtstart.second)
                if cand < dtstart:
                    continue
                if not emit(cand):
                    running = False
                    break
            guard += 1

    elif freq == "MONTHLY":
        guard = 0
        running = True
        # BYDAY with ordinal, e.g. 2MO or -1FR
        bd_m = re.match(r"^([+-]?\d+)?([A-Z]{2})$", byday.strip()) if byday else None
        bymonthday = rrule.get("BYMONTHDAY", "")
        while running and guard < 600:
            anchor = _add_months(dtstart, interval * guard)
            cand = None
            if bd_m and bd_m.group(1):
                wd = _WEEKDAYS.get(bd_m.group(2))
                n = int(bd_m.group(1))
                if wd is not None:
                    day = _nth_weekday(anchor.year, anchor.month, wd, n)
                    if day:
                        cand = anchor.replace(day=day)
            elif bymonthday.lstrip("-").isdigit():
                import calendar
                md = int(bymonthday)
                dim = calendar.monthrange(anchor.year, anchor.month)[1]
                day = md if md > 0 else dim + md + 1
                if 1 <= day <= dim:
                    cand = anchor.replace(day=day)
            else:
                cand = anchor
            if cand is not None and cand >= dtstart:
                if not emit(cand):
                    running = False
            guard += 1

    elif freq == "YEARLY":
        guard = 0
        while guard < 200:
            try:
                cand = dtstart.replace(year=dtstart.year + interval * guard)
            except ValueError:  # Feb 29
                guard += 1
                continue
            if not emit(cand):
                break
            guard += 1

    else:
        occurrences.append(dtstart)

    return occurrences


def _ics_key(dt: datetime, all_day: bool) -> str:
    """Stable key for matching EXDATE / RECURRENCE-ID occurrences."""
    return dt.strftime("%Y-%m-%d") if all_day else dt.strftime("%Y-%m-%dT%H:%M:%S")


def parse_ics(text: str, window_start: datetime, window_end: datetime,
              config: dict) -> list[dict]:
    """Parse an ICS feed into event dicts within [window_start, window_end].

    Recurring events are expanded; EXDATE exclusions and RECURRENCE-ID
    overrides are honored. Events carry no 'filename' so the UI treats
    them as read-only.
    """
    config_zone = _config_zone(config)
    lines = _unfold_ics(text)

    # First pass: collect raw VEVENT components.
    components: list[dict] = []
    cur = None
    in_event = False
    for line in lines:
        up = line.upper()
        if up == "BEGIN:VEVENT":
            in_event = True
            cur = {"props": [], "exdates": []}
            continue
        if up == "END:VEVENT":
            if cur is not None:
                components.append(cur)
            in_event = False
            cur = None
            continue
        if not in_event or cur is None:
            continue
        parsed = _parse_prop(line)
        if not parsed:
            continue
        name, params, value = parsed
        if name == "EXDATE":
            for v in value.split(","):
                dt, ad = _parse_ics_dt(v, params, config_zone)
                cur["exdates"].append(_ics_key(dt, ad))
        else:
            cur["props"].append((name, params, value))

    def get(props, name):
        for n, p, v in props:
            if n == name:
                return p, v
        return None, None

    # Separate masters from RECURRENCE-ID overrides (by UID).
    overrides: dict[str, set] = {}
    override_events: list[dict] = []
    masters: list[dict] = []
    for comp in components:
        props = comp["props"]
        _, uid = get(props, "UID")
        rid_params, rid_val = get(props, "RECURRENCE-ID")
        if rid_val is not None:
            rdt, rad = _parse_ics_dt(rid_val, rid_params, config_zone)
            if uid:
                overrides.setdefault(uid, set()).add(_ics_key(rdt, rad))
            override_events.append(comp)
        else:
            masters.append(comp)

    events: list[dict] = []

    def build_event(props, start_dt, all_day, dur=None, end_dt=None):
        sp, sval = get(props, "SUMMARY")
        title = _unescape_text(sval).strip() if sval else "(no title)"
        _, locv = get(props, "LOCATION")
        _, descv = get(props, "DESCRIPTION")

        if all_day:
            start_iso = start_dt.strftime("%Y-%m-%d")
            if end_dt is not None:
                end_iso = end_dt.strftime("%Y-%m-%d")
            elif dur is not None and dur > timedelta(0):
                end_iso = (start_dt + dur).strftime("%Y-%m-%d")
            else:
                end_iso = (start_dt + timedelta(days=1)).strftime("%Y-%m-%d")
        else:
            start_iso = start_dt.isoformat()
            if end_dt is not None:
                end_iso = end_dt.isoformat()
            elif dur is not None:
                end_iso = (start_dt + dur).isoformat()
            else:
                end_iso = start_iso
        return {
            "title": title,
            "start": start_iso,
            "end": end_iso,
            "allDay": all_day,
            "location": _unescape_text(locv).strip() if locv else "",
            "description": _unescape_text(descv).strip() if descv else "",
        }

    def within(start_dt, all_day):
        # Compare on the same day granularity the list filter uses.
        return window_start <= start_dt <= window_end or (
            all_day and start_dt.date() >= window_start.date()
            and start_dt.date() <= window_end.date())

    for comp in masters:
        props = comp["props"]
        dt_params, dt_val = get(props, "DTSTART")
        if not dt_val:
            continue
        start_dt, all_day = _parse_ics_dt(dt_val, dt_params, config_zone)

        # Duration from DTEND or DURATION.
        end_params, end_val = get(props, "DTEND")
        dur = None
        base_end = None
        if end_val:
            end_dt, _ = _parse_ics_dt(end_val, end_params, config_zone)
            base_end = end_dt
            dur = end_dt - start_dt
        else:
            _, dval = get(props, "DURATION")
            if dval:
                dur = _parse_duration(dval)

        _, rr_val = get(props, "RRULE")
        _, uid = get(props, "UID")
        skip = overrides.get(uid, set()) if uid else set()
        skip = skip | set(comp["exdates"])

        if rr_val:
            starts = _expand_rrule(start_dt, _parse_rrule(rr_val),
                                   window_end, config_zone)
            for s in starts:
                if _ics_key(s, all_day) in skip:
                    continue
                if not within(s, all_day):
                    continue
                e_end = (s + dur) if (dur is not None and not all_day) else None
                ad_end = (s + dur) if (dur is not None and all_day) else None
                events.append(build_event(props, s, all_day,
                                          end_dt=e_end or ad_end))
        else:
            if _ics_key(start_dt, all_day) in skip:
                continue
            if within(start_dt, all_day):
                events.append(build_event(props, start_dt, all_day,
                                          end_dt=base_end, dur=dur))

    # Add RECURRENCE-ID override instances as standalone events.
    for comp in override_events:
        props = comp["props"]
        dt_params, dt_val = get(props, "DTSTART")
        if not dt_val:
            continue
        start_dt, all_day = _parse_ics_dt(dt_val, dt_params, config_zone)
        if not within(start_dt, all_day):
            continue
        end_params, end_val = get(props, "DTEND")
        base_end = None
        if end_val:
            base_end, _ = _parse_ics_dt(end_val, end_params, config_zone)
        events.append(build_event(props, start_dt, all_day, end_dt=base_end))

    return events


def collect_ics_events(config: dict, window_start: datetime,
                       window_end: datetime, base_index: int) -> list[dict]:
    """Fetch & parse every configured ICS feed, tagging calendar indices."""
    all_events = []
    for offset, cal in enumerate(load_ics_calendars(config)):
        url = cal.get("Url", "")
        if not url:
            continue
        text = fetch_ics(url)
        if not text:
            continue
        try:
            evs = parse_ics(text, window_start, window_end, config)
        except Exception as e:
            print(json.dumps({"error": f"ICS parse failed: {e}"}),
                  file=sys.stderr)
            continue
        for ev in evs:
            ev["calendarIndex"] = base_index + offset
        all_events.extend(evs)
    return all_events


def cmd_list(args):
    """List upcoming events."""
    now = datetime.now()
    # Start from yesterday midnight — qcal has an off-by-one with all-day events
    start = now.replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(days=1)
    end = now + timedelta(days=args.days)
    start_str = start.strftime("%Y%m%dT%H%M%S")
    end_str = end.strftime("%Y%m%dT%H%M%S")

    # Query each calendar individually to get filenames and calendar indices
    config = load_qcal_config()
    num_cals = len(config.get("Calendars", []))
    all_events = []

    for cal_idx in range(num_cals):
        output = run_qcal("-s", start_str, "-e", end_str, "-i", "-f", "-c", str(cal_idx))
        if not output:
            continue
        events = parse_events(output)
        for ev in events:
            ev["calendarIndex"] = cal_idx
        all_events.extend(events)

    # Merge in read-only ICS feeds (indices continue after the CalDAV ones).
    all_events.extend(collect_ics_events(config, start, end, num_cals))

    # Filter out past events: yesterday's all-day events (off-by-one workaround)
    # and timed events whose end time has already passed.
    today_str = now.strftime("%Y-%m-%d")
    now_iso = now.isoformat()

    def is_upcoming(e):
        if e["allDay"]:
            return e["start"] >= today_str
        # For timed events keep if the end time hasn't passed yet.
        # Fall back to start time when end equals start (no explicit duration).
        cutoff = e["end"] if e["end"] != e["start"] else e["start"]
        return cutoff > now_iso

    all_events = [e for e in all_events if is_upcoming(e)]
    # Sort by start time
    all_events.sort(key=lambda e: e["start"])
    json.dump({"events": all_events, "count": len(all_events)}, sys.stdout)


def load_qcal_config() -> dict:
    """Load qcal's config.json to get calendar URLs."""
    config_path = os.path.join(
        os.environ.get("HOME", ""), ".config", "qcal", "config.json"
    )
    try:
        with open(config_path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def propfind_calendar_info(url: str, username: str, password: str) -> dict:
    """PROPFIND a CalDAV URL to get displayname and write privileges."""
    import urllib.request
    import urllib.error
    import ssl
    import base64
    import xml.etree.ElementTree as ET

    body = """<?xml version="1.0"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:displayname/>
        <d:current-user-privilege-set/>
      </d:prop>
    </d:propfind>"""
    headers = {
        "Depth": "0",
        "Content-Type": "application/xml; charset=utf-8",
        "Authorization": "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode(),
    }
    ctx = ssl.create_default_context()
    req = urllib.request.Request(url, data=body.encode(), headers=headers, method="PROPFIND")
    result = {"name": "", "readOnly": True}
    try:
        resp = urllib.request.urlopen(req, context=ctx, timeout=10)
        xml_data = resp.read().decode("utf-8")
        root = ET.fromstring(xml_data)
        for dn in root.iter("{DAV:}displayname"):
            if dn.text:
                result["name"] = dn.text.strip()
                break
        # Check for write privilege
        for priv in root.iter("{DAV:}privilege"):
            for child in priv:
                tag = child.tag.split("}")[-1] if "}" in child.tag else child.tag
                if tag in ("write", "write-content", "bind"):
                    result["readOnly"] = False
                    break
    except Exception:
        pass
    return result


def resolve_password(cal: dict) -> str:
    """Resolve a calendar's password from config (PasswordCmd or Password)."""
    cmd = cal.get("PasswordCmd", "")
    if cmd:
        try:
            result = subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, timeout=5)
            return result.stdout.strip()
        except Exception:
            pass
    return cal.get("Password", "")


# Cache file for calendar display names so we don't PROPFIND every time
CAL_NAMES_CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
    "qcal-dms",
    "calendar-names.json",
)


def get_calendar_names(config: dict) -> list[dict]:
    """Get calendar info with display names and read-only status (cached)."""
    # Load cache - now stores {url: {name: str, readOnly: bool}}
    cached = {}
    os.makedirs(os.path.dirname(CAL_NAMES_CACHE), exist_ok=True)
    if os.path.isfile(CAL_NAMES_CACHE):
        try:
            with open(CAL_NAMES_CACHE) as f:
                cached = json.load(f)
        except (json.JSONDecodeError, OSError):
            pass

    cals = []
    updated = False
    for i, cal in enumerate(config.get("Calendars", [])):
        url = cal.get("Url", "")

        # Check cache first
        if url in cached and isinstance(cached[url], dict):
            name = cached[url].get("name", "")
            read_only = cached[url].get("readOnly", True)
        elif url in cached and isinstance(cached[url], str):
            # Migrate old cache format (string-only)
            name = cached[url]
            read_only = True
            updated = True
        else:
            # PROPFIND to get display name and privileges
            username = cal.get("Username", "")
            password = resolve_password(cal)
            info = propfind_calendar_info(url, username, password)
            name = info["name"]
            read_only = info["readOnly"]
            if name:
                name = re.sub(
                    r'[\U0001F000-\U0001FFFF\u2600-\u27BF\uFE00-\uFE0F\u200D]+',
                    '', name
                ).strip()
            cached[url] = {"name": name, "readOnly": read_only}
            updated = True

        # Fallback name from URL path
        if not name:
            segments = [s for s in url.rstrip("/").split("/") if s]
            slug = segments[-1] if segments else f"calendar-{i}"
            if len(slug) > 20 and "-" in slug:
                name = f"Calendar {i}"
            else:
                name = slug.replace("-", " ").replace("_", " ").title()

        cals.append({"index": i, "name": name, "url": url, "readOnly": read_only})

    if updated:
        with open(CAL_NAMES_CACHE, "w") as f:
            json.dump(cached, f)

    return cals


def _mark_calendar_readonly(cal_index: int):
    """Mark a calendar as read-only in cache after a 403 failure."""
    config = load_qcal_config()
    calendars = config.get("Calendars", [])
    if cal_index >= len(calendars):
        return
    url = calendars[cal_index].get("Url", "")
    if not url:
        return

    os.makedirs(os.path.dirname(CAL_NAMES_CACHE), exist_ok=True)
    cached = {}
    if os.path.isfile(CAL_NAMES_CACHE):
        try:
            with open(CAL_NAMES_CACHE) as f:
                cached = json.load(f)
        except (json.JSONDecodeError, OSError):
            pass

    if url in cached and isinstance(cached[url], dict):
        cached[url]["readOnly"] = True
    else:
        cached[url] = {"name": cached.get(url, {}).get("name", ""), "readOnly": True}

    with open(CAL_NAMES_CACHE, "w") as f:
        json.dump(cached, f)


def cmd_calendars(args):
    """List configured calendars with display names."""
    config = load_qcal_config()
    cals = get_calendar_names(config)
    # Append ICS feeds as read-only calendars, indices continuing after CalDAV.
    base = len(cals)
    for offset, ical in enumerate(load_ics_calendars(config)):
        url = ical.get("Url", "")
        name = ical.get("Name", "")
        if not name:
            segs = [s for s in url.split("?")[0].rstrip("/").split("/") if s]
            name = (segs[-1] if segs else f"ICS {offset}").replace(".ics", "")
        cals.append({"index": base + offset, "name": name, "url": url,
                     "readOnly": True})
    json.dump({"calendars": cals}, sys.stdout)


def cmd_add(args):
    """Add a new event via CalDAV PUT."""
    import urllib.request
    import urllib.error
    import ssl
    import base64
    import uuid

    config = load_qcal_config()
    calendars = config.get("Calendars", [])
    if args.calendar >= len(calendars):
        json.dump({"success": False, "error": "Invalid calendar index"}, sys.stdout)
        return

    cal = calendars[args.calendar]
    username = cal.get("Username", "")
    password = resolve_password(cal)
    tz = config.get("Timezone", "UTC")

    # Parse event_data: "YYYYMMDD HHMM HHMM Title" or "YYYYMMDD Title"
    parts = args.event_data.split(" ", 3)
    date_str = parts[0]
    if len(parts) >= 4 and len(parts[1]) == 4 and parts[1].isdigit():
        # Timed event
        start_time = parts[1]
        end_time = parts[2]
        title = parts[3]
        dtstart = f"DTSTART;TZID={tz}:{date_str}T{start_time}00"
        dtend = f"DTEND;TZID={tz}:{date_str}T{end_time}00"
    else:
        # All-day event
        title = " ".join(parts[1:])
        dtstart = f"DTSTART;VALUE=DATE:{date_str}"
        # All-day end is exclusive (next day)
        end_d = datetime.strptime(date_str, "%Y%m%d") + timedelta(days=1)
        dtend = f"DTEND;VALUE=DATE:{end_d.strftime('%Y%m%d')}"

    uid = str(uuid.uuid4())
    filename = uid + ".ics"
    now_utc = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")

    location_line = f"\nLOCATION:{args.location}" if args.location else ""

    ics = (
        f"BEGIN:VCALENDAR\n"
        f"VERSION:2.0\n"
        f"PRODID:-//qcal-dms\n"
        f"BEGIN:VEVENT\n"
        f"UID:{uid}\n"
        f"{dtstart}\n"
        f"{dtend}\n"
        f"DTSTAMP:{now_utc}\n"
        f"SUMMARY:{title}{location_line}\n"
        f"END:VEVENT\n"
        f"END:VCALENDAR\n"
    )

    url = cal.get("Url", "") + filename
    auth = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()
    ctx = ssl.create_default_context()

    try:
        req = urllib.request.Request(
            url,
            data=ics.encode("utf-8"),
            headers={
                "Authorization": auth,
                "Content-Type": "text/calendar; charset=utf-8",
            },
            method="PUT",
        )
        resp = urllib.request.urlopen(req, context=ctx, timeout=15)
        status = resp.status
    except urllib.error.HTTPError as e:
        status = e.code
    except Exception as e:
        json.dump({"success": False, "error": str(e)}, sys.stdout)
        return

    success = status in (200, 201, 204)
    error = ""
    if status == 403:
        error = "This calendar is read-only"
        _mark_calendar_readonly(args.calendar)
    elif status == 401:
        error = "Authentication failed"
    elif not success:
        error = f"Server returned {status}"
    json.dump({"success": success, "error": error}, sys.stdout)


def cmd_delete(args):
    """Delete an event by filename and calendar index."""
    output = run_qcal("-delete", args.filename, "-c", str(args.calendar))
    stripped = output.strip()
    success = "204" in stripped or "200" in stripped
    error = ""
    if "403" in stripped:
        error = "This calendar is read-only"
    elif "404" in stripped:
        error = "Event not found"
    elif "401" in stripped:
        error = "Authentication failed"
    elif not success and stripped:
        error = stripped
    json.dump({"success": success, "output": stripped, "error": error}, sys.stdout)


def cmd_edit(args):
    """Edit an event: download ICS, modify fields, re-upload."""
    import urllib.request
    import urllib.error
    import ssl
    import base64

    config = load_qcal_config()
    calendars = config.get("Calendars", [])
    if args.calendar >= len(calendars):
        json.dump({"success": False, "error": "Invalid calendar index"}, sys.stdout)
        return

    cal = calendars[args.calendar]
    url = cal.get("Url", "") + args.filename
    username = cal.get("Username", "")
    password = resolve_password(cal)
    auth = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()
    ctx = ssl.create_default_context()

    # GET the current ICS
    try:
        req = urllib.request.Request(url, headers={"Authorization": auth})
        resp = urllib.request.urlopen(req, context=ctx, timeout=15)
        ics_data = resp.read().decode("utf-8")
    except Exception as e:
        json.dump({"success": False, "error": f"Failed to fetch event: {e}"}, sys.stdout)
        return

    # Modify the ICS fields
    if args.title:
        ics_data = re.sub(r"(?m)^SUMMARY:.*$", f"SUMMARY:{args.title}", ics_data)

    if args.start_date and args.start_time:
        # Timed event
        new_dtstart = f"DTSTART;TZID={config.get('Timezone', 'UTC')}:{args.start_date}T{args.start_time}00"
        ics_data = re.sub(r"(?m)^DTSTART[^:]*:.*$", new_dtstart, ics_data)
    elif args.start_date and args.all_day:
        new_dtstart = f"DTSTART;VALUE=DATE:{args.start_date}"
        ics_data = re.sub(r"(?m)^DTSTART[^:]*:.*$", new_dtstart, ics_data)

    if args.end_date and args.end_time:
        new_dtend = f"DTEND;TZID={config.get('Timezone', 'UTC')}:{args.end_date}T{args.end_time}00"
        ics_data = re.sub(r"(?m)^DTEND[^:]*:.*$", new_dtend, ics_data)
    elif args.end_date and args.all_day:
        new_dtend = f"DTEND;VALUE=DATE:{args.end_date}"
        ics_data = re.sub(r"(?m)^DTEND[^:]*:.*$", new_dtend, ics_data)

    if args.location is not None:
        if re.search(r"(?m)^LOCATION:", ics_data):
            ics_data = re.sub(r"(?m)^LOCATION:.*$", f"LOCATION:{args.location}", ics_data)
        elif args.location:
            ics_data = ics_data.replace("END:VEVENT", f"LOCATION:{args.location}\nEND:VEVENT")

    # PUT the modified ICS back
    try:
        req = urllib.request.Request(
            url,
            data=ics_data.encode("utf-8"),
            headers={
                "Authorization": auth,
                "Content-Type": "text/calendar; charset=utf-8",
            },
            method="PUT",
        )
        resp = urllib.request.urlopen(req, context=ctx, timeout=15)
        status = resp.status
    except urllib.error.HTTPError as e:
        status = e.code
    except Exception as e:
        json.dump({"success": False, "error": str(e)}, sys.stdout)
        return

    success = status in (200, 201, 204)
    error = ""
    if status == 403:
        error = "This calendar is read-only"
        _mark_calendar_readonly(args.calendar)
    elif not success:
        error = f"Server returned {status}"
    json.dump({"success": success, "error": error}, sys.stdout)


def cmd_notify(args):
    """Check for events starting within N minutes and send desktop notification."""
    now = datetime.now()
    end = now + timedelta(minutes=args.minutes)
    start_str = now.strftime("%Y%m%dT%H%M%S")
    end_str = end.strftime("%Y%m%dT%H%M%S")

    output = run_qcal("-s", start_str, "-e", end_str, "-i")
    if not output:
        return

    events = parse_events(output)
    if not events:
        return

    # Load previously notified events
    notified = set()
    os.makedirs(os.path.dirname(NOTIFY_STATE_FILE), exist_ok=True)
    if os.path.isfile(NOTIFY_STATE_FILE):
        try:
            with open(NOTIFY_STATE_FILE) as f:
                data = json.load(f)
                # Clean old entries (older than 24h)
                cutoff = (datetime.now() - timedelta(hours=24)).isoformat()
                notified = {k for k, v in data.items() if v > cutoff}
        except (json.JSONDecodeError, KeyError):
            pass

    new_notified = {}
    for ev in events:
        key = f"{ev['title']}|{ev['start']}"
        if key in notified:
            continue

        # Send notification
        title = ev["title"]
        body_parts = []
        if ev["allDay"]:
            body_parts.append("All day")
        else:
            start_str_display = ev["start"].split("T")[1][:5] if "T" in ev["start"] else ""
            end_str_display = ev["end"].split("T")[1][:5] if "T" in ev["end"] else ""
            if start_str_display:
                time_range = start_str_display
                if end_str_display and end_str_display != start_str_display:
                    time_range += f" - {end_str_display}"
                body_parts.append(time_range)
        if ev.get("location"):
            body_parts.append(ev["location"])

        body = "\n".join(body_parts) if body_parts else ""

        try:
            subprocess.run(
                ["notify-send", "-i", "calendar", "-u", "normal",
                 "-a", "qCal Calendar", title, body],
                timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

        new_notified[key] = datetime.now().isoformat()

    # Save notified state (merge with existing)
    if new_notified:
        all_notified = {k: datetime.now().isoformat() for k in notified}
        all_notified.update(new_notified)
        with open(NOTIFY_STATE_FILE, "w") as f:
            json.dump(all_notified, f)


def discover_calendars(base_url: str, username: str, password: str) -> list[dict]:
    """Discover all calendars on a CalDAV server via PROPFIND."""
    import urllib.request
    import urllib.error
    import ssl
    import base64
    import xml.etree.ElementTree as ET
    from urllib.parse import urlparse

    ctx = ssl.create_default_context()
    auth = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()

    def caldav_request(url, body=None, depth="0"):
        headers = {
            "Depth": depth,
            "Content-Type": "application/xml; charset=utf-8",
            "Authorization": auth,
        }
        for _ in range(5):
            req = urllib.request.Request(
                url, data=body.encode() if body else None,
                headers=headers, method="PROPFIND",
            )
            try:
                resp = urllib.request.urlopen(req, context=ctx, timeout=15)
                return resp.read().decode("utf-8"), resp.geturl()
            except urllib.error.HTTPError as e:
                if e.code in (301, 302, 307, 308):
                    url = e.headers.get("Location", url)
                    continue
                raise
        return "", url

    effective_base = base_url.rstrip("/")

    # Try well-known redirect
    try:
        body, effective_url = caldav_request(
            effective_base + "/.well-known/caldav",
            '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
            '<d:current-user-principal/></d:prop></d:propfind>',
        )
        parsed = urlparse(effective_url)
        effective_base = f"{parsed.scheme}://{parsed.netloc}"
    except Exception:
        pass

    # Find current-user-principal
    body, _ = caldav_request(
        effective_base + "/",
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>'
        '<d:current-user-principal/></d:prop></d:propfind>',
    )
    root = ET.fromstring(body)
    principal_href = None
    for href in root.iter("{DAV:}href"):
        val = href.text
        if val and val != "/" and "principal" in val.lower():
            principal_href = val
            break
    if not principal_href:
        for href in root.iter("{DAV:}href"):
            val = href.text
            if val and val != "/":
                principal_href = val
                break
    if not principal_href:
        raise RuntimeError("Could not find user principal")

    principal_url = (
        effective_base + principal_href
        if principal_href.startswith("/") else principal_href
    )

    # Find calendar-home-set
    body, _ = caldav_request(
        principal_url,
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" '
        'xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop>'
        '<c:calendar-home-set/></d:prop></d:propfind>',
    )
    root = ET.fromstring(body)
    homeset_href = None
    for hs in root.iter("{urn:ietf:params:xml:ns:caldav}calendar-home-set"):
        for href in hs.iter("{DAV:}href"):
            if href.text:
                homeset_href = href.text
                break
        if homeset_href:
            break
    if not homeset_href:
        raise RuntimeError("Could not find calendar-home-set")

    homeset_url = (
        effective_base + homeset_href
        if homeset_href.startswith("/") else homeset_href
    )

    # List calendars
    body, _ = caldav_request(
        homeset_url,
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:" '
        'xmlns:c="urn:ietf:params:xml:ns:caldav" '
        'xmlns:ic="http://apple.com/ns/ical/"><d:prop>'
        '<d:displayname/><d:resourcetype/><ic:calendar-color/>'
        '</d:prop></d:propfind>',
        depth="1",
    )
    root = ET.fromstring(body)
    calendars = []
    for resp in root.findall("{DAV:}response"):
        href_el = resp.find("{DAV:}href")
        if href_el is None or not href_el.text:
            continue
        href = href_el.text
        rt = resp.find(".//{DAV:}resourcetype")
        if rt is None:
            continue
        if rt.find("{urn:ietf:params:xml:ns:caldav}calendar") is None:
            continue
        name_el = resp.find(".//{DAV:}displayname")
        name = (
            name_el.text
            if name_el is not None and name_el.text
            else href.rstrip("/").split("/")[-1]
        )
        full_url = effective_base + href if href.startswith("/") else href
        calendars.append({"url": full_url, "name": name})

    return calendars


def cmd_discover(args):
    """Discover CalDAV calendars and write them to qcal config."""
    config_dir = os.path.join(os.environ.get("HOME", ""), ".config", "qcal")
    config_path = os.path.join(config_dir, "config.json")

    try:
        cals = discover_calendars(args.url, args.username, args.password)
    except Exception as e:
        json.dump({"success": False, "error": str(e), "calendars": []}, sys.stdout)
        return

    if not cals:
        json.dump(
            {"success": False, "error": "No calendars found", "calendars": []},
            sys.stdout,
        )
        return

    # Load or create config
    os.makedirs(config_dir, exist_ok=True)
    try:
        with open(config_path) as f:
            cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        cfg = {}

    # Detect timezone
    try:
        import subprocess as _sp
        tz = _sp.run(
            ["timedatectl", "show", "-p", "Timezone", "--value"],
            capture_output=True, text=True,
        ).stdout.strip() or "UTC"
    except Exception:
        tz = "UTC"

    cfg.setdefault("Timezone", tz)
    cfg.setdefault("DefaultNumDays", 14)

    # Build calendar entries, preserving any existing non-matching entries
    # (from other providers manually added to config.json)
    discovered_urls = {c["url"] for c in cals}
    old_cals = cfg.get("Calendars", [])

    # Keep calendars that don't belong to this account (different username)
    kept = [c for c in old_cals if c.get("Username") != args.username
            and c.get("Url") not in discovered_urls]

    # Store password in GNOME Keyring if available, otherwise plaintext
    use_keyring = has_secret_tool() and keyring_store(args.username, args.password)

    if use_keyring:
        pw_cmd = keyring_lookup_cmd(args.username)
        new_cals = kept + [
            {"Url": c["url"], "Username": args.username, "PasswordCmd": pw_cmd}
            for c in cals
        ]
    else:
        new_cals = kept + [
            {"Url": c["url"], "Username": args.username, "Password": args.password}
            for c in cals
        ]
    cfg["Calendars"] = new_cals

    with open(config_path, "w") as f:
        json.dump(cfg, f, indent=4)

    # Clear calendar name cache so new names are fetched
    if os.path.isfile(CAL_NAMES_CACHE):
        os.remove(CAL_NAMES_CACHE)

    json.dump(
        {"success": True, "calendars": [c["name"] for c in cals], "error": "",
         "keyring": use_keyring},
        sys.stdout,
    )


def _write_qcal_config(cfg: dict):
    config_dir = os.path.join(os.environ.get("HOME", ""), ".config", "qcal")
    os.makedirs(config_dir, exist_ok=True)
    with open(os.path.join(config_dir, "config.json"), "w") as f:
        json.dump(cfg, f, indent=4)


def cmd_add_ics(args):
    """Add a read-only ICS feed URL to the config."""
    cfg = load_qcal_config()
    feeds = cfg.get("IcsCalendars", [])
    if not isinstance(feeds, list):
        feeds = []
    if any(f.get("Url") == args.url for f in feeds):
        json.dump({"success": False, "error": "Feed already configured"}, sys.stdout)
        return
    # Validate by fetching once so we fail loudly on a bad URL.
    text = fetch_ics(args.url)
    if "BEGIN:VCALENDAR" not in text:
        json.dump({"success": False,
                   "error": "URL did not return a valid ICS feed"}, sys.stdout)
        return
    name = args.name
    if not name:
        m = re.search(r"(?mi)^X-WR-CALNAME:(.+)$", text)
        name = m.group(1).strip() if m else ""
    feeds.append({"Url": args.url, "Name": name})
    cfg["IcsCalendars"] = feeds
    cfg.setdefault("DefaultNumDays", 14)
    _write_qcal_config(cfg)
    json.dump({"success": True, "name": name, "error": ""}, sys.stdout)


def cmd_remove_ics(args):
    """Remove an ICS feed by index (from list-ics) or by URL."""
    cfg = load_qcal_config()
    feeds = cfg.get("IcsCalendars", [])
    if not isinstance(feeds, list) or not feeds:
        json.dump({"success": False, "error": "No ICS feeds configured"}, sys.stdout)
        return
    target = args.feed
    removed = None
    if target.isdigit() and int(target) < len(feeds):
        removed = feeds.pop(int(target))
    else:
        for i, f in enumerate(feeds):
            if f.get("Url") == target:
                removed = feeds.pop(i)
                break
    if removed is None:
        json.dump({"success": False, "error": "Feed not found"}, sys.stdout)
        return
    cfg["IcsCalendars"] = feeds
    _write_qcal_config(cfg)
    json.dump({"success": True, "removed": removed.get("Url", ""), "error": ""},
              sys.stdout)


def cmd_list_ics(args):
    """List configured ICS feeds."""
    cfg = load_qcal_config()
    feeds = load_ics_calendars(cfg)
    json.dump({"feeds": [{"index": i, "url": f.get("Url", ""),
                          "name": f.get("Name", "")}
                         for i, f in enumerate(feeds)]}, sys.stdout)


def main():
    parser = argparse.ArgumentParser(description="qcal JSON wrapper")
    sub = parser.add_subparsers(dest="command")

    p_list = sub.add_parser("list")
    p_list.add_argument("--days", type=int, default=7)

    p_cals = sub.add_parser("calendars")

    p_add = sub.add_parser("add")
    p_add.add_argument("calendar", type=int, help="Calendar number (from 'calendars' command)")
    p_add.add_argument("event_data", help='Event data, e.g. "20260310 1400 1500 Meeting"')
    p_add.add_argument("-r", "--recurrence", default="", help="Recurrence: d/w/m/y")
    p_add.add_argument("--location", default="", help="Event location")

    p_delete = sub.add_parser("delete")
    p_delete.add_argument("calendar", type=int, help="Calendar number")
    p_delete.add_argument("filename", help="Event ICS filename")

    p_edit = sub.add_parser("edit")
    p_edit.add_argument("calendar", type=int, help="Calendar number")
    p_edit.add_argument("filename", help="Event ICS filename")
    p_edit.add_argument("--title", default=None)
    p_edit.add_argument("--start-date", default=None, help="YYYYMMDD")
    p_edit.add_argument("--start-time", default=None, help="HHMM")
    p_edit.add_argument("--end-date", default=None, help="YYYYMMDD")
    p_edit.add_argument("--end-time", default=None, help="HHMM")
    p_edit.add_argument("--location", default=None)
    p_edit.add_argument("--all-day", action="store_true")

    p_discover = sub.add_parser("discover")
    p_discover.add_argument("url", help="CalDAV base URL")
    p_discover.add_argument("username", help="Account username")
    p_discover.add_argument("password", help="Account password")

    p_notify = sub.add_parser("notify")
    p_notify.add_argument("--minutes", type=int, default=15)

    p_add_ics = sub.add_parser("add-ics")
    p_add_ics.add_argument("url", help="Private/secret ICS feed URL")
    p_add_ics.add_argument("--name", default="", help="Display name (optional)")

    p_rm_ics = sub.add_parser("remove-ics")
    p_rm_ics.add_argument("feed", help="Feed index (from list-ics) or URL")

    sub.add_parser("list-ics")

    args = parser.parse_args()

    if args.command == "discover":
        cmd_discover(args)
    elif args.command == "list":
        cmd_list(args)
    elif args.command == "calendars":
        cmd_calendars(args)
    elif args.command == "add":
        cmd_add(args)
    elif args.command == "delete":
        cmd_delete(args)
    elif args.command == "edit":
        cmd_edit(args)
    elif args.command == "notify":
        cmd_notify(args)
    elif args.command == "add-ics":
        cmd_add_ics(args)
    elif args.command == "remove-ics":
        cmd_remove_ics(args)
    elif args.command == "list-ics":
        cmd_list_ics(args)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()

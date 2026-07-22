# waybar-calendar

> Your next calendar event, right in the bar — countdown and all.

[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](./LICENSE)
[![Shell](https://img.shields.io/badge/Bash-4+-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![waybar](https://img.shields.io/badge/waybar-module-89b4fa?style=flat-square)](https://github.com/Alexays/Waybar)

A [waybar](https://github.com/Alexays/Waybar) module that shows your **next
calendar event** in the bar, Fantastical-style: the event's title with its start
time, switching to a live countdown (`in 15m`) as it approaches, and the full
agenda in the tooltip. Built and tested on Void Linux + sway.

There is **no local Google OAuth** and nothing to authorize on your laptop — the
module runs a small, read-only *fetch command* (by default an existing
`gcalendar.py` CLI over SSH), caches the result, and never touches your calendar
for writes.

---

## Features

- **Up next, at a glance** — shows the next upcoming event, skipping the one
  currently in progress (toggleable)
- **Smart countdown** — displays `Standup in 12m` when the event is near, or
  `Tmrw 08:35 Standup` when it's further out
- **Imminent highlight** — a `soon` CSS class kicks in a few minutes before, so
  you can colour it to catch your eye
- **Agenda tooltip** — the next several events with full dates on hover
- **Cheap + resilient** — re-fetches at most once every few minutes and reuses
  the last cache on network hiccups, so the bar never blanks
- **Backend-agnostic** — point it at any command that prints the expected line
  format (SSH + `gcalendar.py`, `gcalcli`, a cron'd `.ics` dump, …)

---

## How it works

1. **Fetch** — on a stale cache, the module runs `CAL_FETCH_CMD` (default: SSH to
   a host and run `gcalendar.py list N`) to get upcoming events as plain text.
2. **Cache** — output is stored under `~/.cache/waybar-calendar/` with a
   timestamp; real fetches happen at most once per `CAL_REFRESH_SECS`.
3. **Render** — every poll, the script reads the cache, picks the next event,
   formats the text (start time or countdown), and prints JSON for waybar.

If a fetch fails (server down, no network) the previous cache is reused, so a
dropped connection doesn't wipe the bar.

### Expected event format

Your fetch command must print one line per event, sorted by start time:

```
[YYYY-MM-DD HH:MM - HH:MM] Title [CalName] (id: ...)
```

This is exactly what the bundled reference backend (`gcalendar.py list N`)
produces. Anything else that emits the same shape works too.

---

## Install

```sh
./install.sh
```

Then follow the printed steps:

- **`~/.config/waybar/config`** — add the `custom/calendar` module:

  ```json
  "custom/calendar": {
      "exec": "~/.config/waybar/calendar-status.sh",
      "return-type": "json",
      "interval": 60,
      "tooltip": true
  }
  ```

- **`~/.config/waybar/style.css`** — merge in the colours from `style.css.example`.

Reload waybar (`pkill -x waybar; waybar &`) and your next event appears.

---

## Configuration

All options are environment variables — set them inline in the module `exec`, e.g.:

```json
"exec": "CAL_SERVER=me@host CAL_NEAR_MINS=30 ~/.config/waybar/calendar-status.sh"
```

| Variable              | Default                       | Purpose                                                            |
|-----------------------|-------------------------------|--------------------------------------------------------------------|
| `CAL_SERVER`          | `ubuntu@server.jedbillyb.com` | SSH target for the default backend                                 |
| `CAL_LOOKAHEAD_DAYS`  | `14`                          | How far ahead to fetch                                             |
| `CAL_REFRESH_SECS`    | `600`                         | Minimum seconds between real fetches                               |
| `CAL_CACHE_DIR`       | `~/.cache/waybar-calendar`    | Where the event cache lives                                        |
| `CAL_SKIP_INPROGRESS` | `1`                           | `1` = show next upcoming event; `0` = include the one happening now |
| `CAL_NEAR_MINS`       | `60`                          | Within this many minutes, show a countdown instead of the start time |
| `CAL_SOON_MINS`       | `10`                          | Within this many minutes, add the `soon` class for highlighting    |
| `CAL_FETCH_CMD`       | *(ssh + `gcalendar.py`)*      | Custom command that prints the event lines                         |

### Styling

The module emits one of these CSS classes, so you can colour each state:

| Class      | When                                             |
|------------|--------------------------------------------------|
| `today`    | next event is later today                        |
| `upcoming` | next event is on a later day                     |
| `soon`     | next event is within `CAL_SOON_MINS`             |
| `none`     | nothing upcoming (module collapses)              |

See `style.css.example` for a starting palette.

---

## Backends

The default backend SSHes to a host running a read-only Google Calendar CLI. To
use something local instead, set `CAL_FETCH_CMD` to any command that prints the
[expected format](#expected-event-format), for example a wrapper around
[`gcalcli`](https://github.com/insanum/gcalcli) or a script that parses a
downloaded `.ics` file. Private calendar data stays on whatever host you fetch
from — it's never published to a URL.

---

## License

MIT — see [LICENSE](./LICENSE).

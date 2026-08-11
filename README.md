# waybar-calendar

> Your next calendar event, right in the bar - countdown and all.

[![License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](./LICENSE)
[![Shell](https://img.shields.io/badge/Bash-4+-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![waybar](https://img.shields.io/badge/waybar-module-89b4fa?style=flat-square)](https://github.com/Alexays/Waybar)

A [waybar](https://github.com/Alexays/Waybar) module that shows your **next
calendar event** in the bar, Fantastical-style: the event's title with its start
time, switching to a live countdown (`in 15m`) as it approaches, and the full
agenda in the tooltip. Built and tested on Void Linux + sway.

The module runs a small, read-only *fetch command*, caches the result, and never
touches your calendar for writes. It ships with two interchangeable backends and
picks one automatically: a **local** `gcalendar.py` in its own venv if you've set
one up, otherwise it falls back to running that same CLI on a remote host over
**SSH** - so a fresh checkout works with zero local setup.

---

## Features

- **Up next, at a glance** - shows the next upcoming event, skipping the one
  currently in progress (toggleable)
- **Smart countdown** - displays `Standup in 12m` when the event is near, or
  `Tmrw 08:35 Standup` when it's further out, and drops to a second-by-second
  `Standup in 45s` in the last minute. Minutes are rounded up, so the countdown
  always agrees with subtracting the bar's clock from the start time (clock
  `11:57`, class at `12:00` reads `in 3m`, not `2m`)
- **Imminent highlight** - a `soon` CSS class kicks in a few minutes before, so
  you can colour it to catch your eye
- **Agenda tooltip** - the next several events with full dates on hover
- **Cheap + resilient** - re-fetches at most once every few minutes and reuses
  the last cache on network hiccups, so the bar never blanks
- **Backend-agnostic** - point it at any command that prints the expected line
  format (SSH + `gcalendar.py`, `gcalcli`, a cron'd `.ics` dump, …)

---

## How it works

1. **Fetch** - on a stale cache, the module runs the fetch backend to get
   upcoming events as plain text. It uses the **local** backend when a venv is
   present at `CAL_GCAL_DIR` (`$GCAL_DIR/.venv/bin/python $GCAL_DIR/gcalendar.py
   list N`), otherwise falls back to the **remote** backend (SSH to `CAL_SERVER`
   and run `gcalendar.py list N`). Set `CAL_FETCH_CMD` to override both.
2. **Cache** - output is stored under `~/.cache/waybar-calendar/` with a
   timestamp; real fetches happen at most once per `CAL_REFRESH_SECS`.
3. **Render** - on every tick the script picks the next event, formats the text
   (start time or countdown), and prints JSON for waybar.

Run it either way:

- **Streaming** (`--loop`, recommended) - one long-lived process that prints a
  line every `CAL_TICK_SECS` (default 1s), so the sub-minute countdown ticks in
  real time. It re-reads the cache only when the cache file changes, and a tick
  costs no subprocesses at all.
- **One-shot** (no arguments) - prints a single line and exits; let waybar's
  `interval` drive it. Simpler, but the countdown moves only as often as you poll.

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

- **`~/.config/waybar/config`** - add the `custom/calendar` module:

  ```json
  "custom/calendar": {
      "exec": "~/.config/waybar/calendar-status.sh --loop",
      "return-type": "json",
      "restart-interval": 5,
      "tooltip": true
  }
  ```

  That streams a line every second (see [How it works](#how-it-works)). For the
  simpler polled setup, drop `--loop` and use `"interval": 60` instead of
  `"restart-interval"`.

- **`~/.config/waybar/style.css`** - merge in the colours from `style.css.example`.

Reload waybar (`pkill -x waybar; waybar &`) and your next event appears.

---

## Configuration

All options are environment variables - set them inline in the module `exec`, e.g.:

```json
"exec": "CAL_SERVER=me@host CAL_NEAR_MINS=30 ~/.config/waybar/calendar-status.sh"
```

| Variable              | Default                       | Purpose                                                            |
|-----------------------|-------------------------------|--------------------------------------------------------------------|
| `CAL_GCAL_DIR`        | `~/.local/share/waybar-calendar/gcal` | Local backend dir (`.venv` + `gcalendar.py`); used automatically when present |
| `CAL_SERVER`          | `ubuntu@server.jedbillyb.com` | SSH target for the remote fallback backend                         |
| `CAL_LOOKAHEAD_DAYS`  | `14`                          | How far ahead to fetch                                             |
| `CAL_REFRESH_SECS`    | `600`                         | Minimum seconds between real fetches                               |
| `CAL_CACHE_DIR`       | `~/.cache/waybar-calendar`    | Where the event cache lives                                        |
| `CAL_SKIP_INPROGRESS` | `1`                           | `1` = show next upcoming event; `0` = include the one happening now |
| `CAL_NEAR_MINS`       | `60`                          | Within this many minutes, show a countdown instead of the start time |
| `CAL_SOON_MINS`       | `10`                          | Within this many minutes, add the `soon` class for highlighting    |
| `CAL_SHOW_ROOM`       | `1`                           | Append the event's Location (room), e.g. `L2PHY @SCI2`             |
| `CAL_ROOM_SEP`        | `@`                           | Separator shown before the room                                    |
| `CAL_FETCH_CMD`       | *(ssh + `gcalendar.py`)*      | Custom command that prints the event lines                         |
| `CAL_TICK_SECS`       | `1`                           | `--loop` only: seconds between printed lines                       |
| `CAL_CHECK_SECS`      | `15`                          | `--loop` only: how often to re-check the cache file for changes     |
| `CAL_RETRY_SECS`      | `60`                          | After a failed fetch, wait this long before retrying                |
| `CAL_STALE_SECS`      | `5400`                        | Failing fetch + cache older than this = show the `stale` warning    |

### Styling

The module emits one of these CSS classes, so you can colour each state:

| Class      | When                                             |
|------------|--------------------------------------------------|
| `today`    | next event is later today                        |
| `upcoming` | next event is on a later day                     |
| `soon`     | next event is within `CAL_SOON_MINS`             |
| `none`     | nothing upcoming (module collapses)              |
| `auth`     | OAuth token expired or revoked - needs re-auth   |
| `stale`    | fetching is failing and the cache has aged out   |

See `style.css.example` for a starting palette.

### When the backend breaks

`auth` and `stale` exist because the module's failure mode used to be invisible:
a fetch error left the last good cache in place, and once every event in it had
passed, `render` produced an empty string - exactly what "nothing on today"
looks like. A dead OAuth token could sit there for days looking like a quiet
week. Now the bar says `cal auth` (or `cal stale`), and the tooltip carries the
command that fixes it.

---

## Backends

The module auto-selects between two built-in backends and you can always override
with `CAL_FETCH_CMD`.

### Remote (default, zero setup)

SSHes to a host running the bundled read-only `gcalendar.py` and runs
`gcalendar.py list N`. Point it at your host with `CAL_SERVER`. This is the
fallback whenever no local backend is configured.

### Local (no per-poll SSH)

Run the same CLI on this machine so the bar never opens a network connection.
Put a venv and the OAuth files in `CAL_GCAL_DIR` (outside this repo, since it
holds a token) and the module uses it automatically:

```sh
GCAL_DIR=~/.local/share/waybar-calendar/gcal   # or set CAL_GCAL_DIR to taste
mkdir -p "$GCAL_DIR"
# copy the CLI + its OAuth token/secret from wherever it's already authorized:
scp you@host:'~/obsidian-sync/gcalendar.py' \
    you@host:'~/obsidian-sync/calendar_token.json' \
    you@host:'~/obsidian-sync/client_secret_*.json' "$GCAL_DIR"/
chmod 600 "$GCAL_DIR"/calendar_token.json "$GCAL_DIR"/client_secret_*.json
python3 -m venv "$GCAL_DIR/.venv"
"$GCAL_DIR/.venv/bin/pip" install google-api-python-client google-auth google-auth-oauthlib
```

The token auto-refreshes locally; the client's refresh token can be shared with
the original host (Google "Desktop app" clients don't rotate it).

#### Re-authorising an expired token

Google expires refresh tokens after **7 days** while the OAuth client is still in
*Testing* publishing status, so the module will show `cal auth` about once a week
until you publish the client. To mint a fresh token (opens a browser):

```sh
"$GCAL_DIR/.venv/bin/python" "$GCAL_DIR/gcalendar.py" auth
```

To stop it recurring, set the OAuth client's publishing status to **In
production** in the Google Cloud console (APIs & Services → OAuth consent screen
/ Audience → *Publish app*). Refresh tokens then last until explicitly revoked.

### Anything else

Set `CAL_FETCH_CMD` to any command that prints the
[expected format](#expected-event-format) - e.g. a wrapper around
[`gcalcli`](https://github.com/insanum/gcalcli) or a script that parses a
downloaded `.ics` file. Private calendar data stays on whatever host you fetch
from - it's never published to a URL.

---

## License

MIT - see [LICENSE](./LICENSE).

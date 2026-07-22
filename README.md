# waybar-calendar

A [waybar](https://github.com/Alexays/Waybar) module that shows your **next
calendar event** in the bar, with the upcoming agenda in the tooltip. Built and
tested on Void Linux + sway.

The bar shows the next event as `HH:MM Title` (today) or `Ddd HH:MM Title`
(a later day, e.g. `Fri 08:35 L2ENG`). Today's events are highlighted. The
tooltip lists the next several events with full dates. When nothing is coming
up the module collapses to nothing.

## How it works

There is no local Google OAuth. The module runs a **fetch command** that prints
upcoming events as plain text, caches the result, and re-fetches at most once
every `CAL_REFRESH_SECS` (default 600s) so the bar can poll cheaply. If a fetch
fails the last cache is reused, so a dropped network doesn't blank the bar.

The default backend SSHes to a host running a small read-only Google Calendar
CLI (`gcalendar.py list N`). Any command works as long as it prints lines in
this format (one per event, sorted by start time):

```
[YYYY-MM-DD HH:MM - HH:MM] Title [CalName] (id: ...)
```

## Install

```sh
./install.sh
```

Then follow the printed steps: add the `custom/calendar` module to your waybar
`config`, merge `style.css.example` into your `style.css`, and reload waybar.

## Configuration (env vars)

| Variable            | Default                          | Purpose                                            |
|---------------------|----------------------------------|----------------------------------------------------|
| `CAL_SERVER`        | `ubuntu@server.jedbillyb.com`    | SSH target for the default backend                 |
| `CAL_LOOKAHEAD_DAYS`| `14`                             | How far ahead to fetch                             |
| `CAL_REFRESH_SECS`  | `600`                            | Minimum seconds between real fetches               |
| `CAL_CACHE_DIR`     | `~/.cache/waybar-calendar`       | Where the event cache lives                        |
| `CAL_SKIP_INPROGRESS`| `1`                             | `1` = show next upcoming event; `0` = include the one happening now |
| `CAL_FETCH_CMD`     | *(ssh + gcalendar.py)*           | Custom command that prints the event lines         |

Set them inline in the module `exec`, e.g.:

```json
"exec": "CAL_SERVER=me@host CAL_LOOKAHEAD_DAYS=7 ~/.config/waybar/calendar-status.sh"
```

## License

MIT

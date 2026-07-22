#!/bin/bash
# calendar-status.sh — waybar custom module showing the next Google Calendar event.
#
# There is no local Google OAuth: the calendar lives on server.jedbillyb.com
# (~/obsidian-sync/gcalendar.py, token auto-refreshes there). This script calls
# that existing read-only tool over SSH, parses its output, and caches it so the
# bar can poll frequently while we only hit the server every REFRESH seconds.
#
# Emits one line of JSON ({"text","class","tooltip"}) for waybar.
set -uo pipefail

SERVER="${CAL_SERVER:-ubuntu@server.jedbillyb.com}"
LOOKAHEAD_DAYS="${CAL_LOOKAHEAD_DAYS:-14}"
REFRESH="${CAL_REFRESH_SECS:-600}"        # re-fetch from server at most this often
CACHE_DIR="${CAL_CACHE_DIR:-$HOME/.cache/waybar-calendar}"
SKIP_INPROGRESS="${CAL_SKIP_INPROGRESS:-1}"  # 1 = show next upcoming; 0 = include the event happening now
NEAR_MINS="${CAL_NEAR_MINS:-60}"    # within this many minutes, show a countdown ("in 15m") instead of the start time
SOON_MINS="${CAL_SOON_MINS:-10}"    # within this many minutes, highlight the module ("soon" class)

# The fetch backend. Override CAL_FETCH_CMD with any command that prints event
# lines in the format:  [YYYY-MM-DD HH:MM - HH:MM] Title [CalName] (id: ...)
# The default calls the read-only gcalendar.py CLI on a remote host over SSH.
DEFAULT_FETCH="ssh -o BatchMode=yes -o ConnectTimeout=5 $SERVER \"cd obsidian-sync && python3 gcalendar.py list $LOOKAHEAD_DAYS 2>/dev/null\""
FETCH_CMD="${CAL_FETCH_CMD:-$DEFAULT_FETCH}"
RAW="$CACHE_DIR/raw.txt"
STAMP="$CACHE_DIR/fetched_at"

mkdir -p "$CACHE_DIR"
now="$(date +%s)"

# ── Refresh the cache if it is stale ────────────────────────────────────────────
last=0
[ -f "$STAMP" ] && last="$(cat "$STAMP" 2>/dev/null || echo 0)"
if [ $(( now - last )) -ge "$REFRESH" ]; then
    data="$(timeout 8 bash -c "$FETCH_CMD" 2>/dev/null)"
    if [ -n "$data" ] && printf '%s' "$data" | grep -q '^\['; then
        printf '%s\n' "$data" > "$RAW"
        printf '%s\n' "$now" > "$STAMP"
    fi
fi

# No cache at all (never fetched, server unreachable) — collapse the module.
if [ ! -s "$RAW" ]; then
    printf '{"text":"","class":"none","tooltip":false}\n'
    exit 0
fi

# ── Parse cached event lines ────────────────────────────────────────────────────
# Line format from gcalendar.py fmt_event():
#   [YYYY-MM-DD HH:MM - HH:MM] Summary [CalName] (id: ...)
today="$(date +%Y-%m-%d)"
tomorrow="$(date -d 'tomorrow' +%Y-%m-%d)"

first_text=""
first_mins=999999
first_today=0
tooltip=""
count=0
line_re='^\[([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}) - [^]]*\] (.+) \(id: [^)]*\)$'

while IFS= read -r line; do
    [[ "$line" =~ $line_re ]] || continue
    d="${BASH_REMATCH[1]}"
    t="${BASH_REMATCH[2]}"
    title="${BASH_REMATCH[3]}"
    title="${title% \[*\]}"          # strip trailing " [CalName]" tag

    start_epoch="$(date -d "$d $t" +%s 2>/dev/null || echo 0)"

    # Show what's *next*, not what's happening now: skip events already started
    # (unless CAL_SKIP_INPROGRESS=0).
    if [ "$SKIP_INPROGRESS" = "1" ] && [ "$start_epoch" -le "$now" ]; then
        continue
    fi

    # Day prefix relative to today.
    case "$d" in
        "$today")    dpfx="" ;;
        "$tomorrow") dpfx="Tmrw " ;;
        *)           dpfx="$(date -d "$d" +%a) " ;;
    esac

    short="$title"
    [ "${#short}" -gt 22 ] && short="${short:0:21}…"

    if [ -z "$first_text" ]; then
        mins=$(( (start_epoch - now) / 60 ))
        (( mins < 0 )) && mins=0
        if [ "$start_epoch" -gt "$now" ] && [ "$mins" -le "$NEAR_MINS" ]; then
            # Close by — relative countdown, e.g. "MentorTime in 15m".
            if   [ "$mins" -lt 60 ];   then rel="${mins}m"
            elif [ "$mins" -lt 1440 ]; then rel="$(( mins / 60 ))h"
            else                            rel="$(( mins / 1440 ))d"
            fi
            first_text="${short} in ${rel}"
        else
            # Further out — show the start time (with day prefix).
            first_text="${dpfx}${t} ${short}"
        fi
        first_mins=$mins
        [ "$d" = "$today" ] && first_today=1 || first_today=0
    fi

    # Tooltip: up to 6 upcoming events, fuller titles.
    if [ "$count" -lt 6 ]; then
        tt="$(date -d "$d" '+%a %d %b') ${t}  ${title}"
        tooltip="${tooltip}${tt}\n"
        count=$((count+1))
    fi
done < "$RAW"

if [ -z "$first_text" ]; then
    printf '{"text":"","class":"none","tooltip":false}\n'
    exit 0
fi

# Class drives colour: 'soon' when imminent, else 'today' / 'upcoming'.
if [ "$first_mins" -le "$SOON_MINS" ]; then
    class="soon"
elif [ "$first_today" = "1" ]; then
    class="today"
else
    class="upcoming"
fi

tooltip="${tooltip%\\n}"
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$(esc "$first_text")" "$class" "$(esc "$tooltip")"
exit 0

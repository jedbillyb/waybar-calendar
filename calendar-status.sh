#!/bin/bash
# calendar-status.sh — waybar custom module showing the next Google Calendar event.
#
# The calendar data comes from gcalendar.py (a read-only Google Calendar CLI),
# run either from a local venv or over SSH; results are cached so the bar can
# refresh far more often than we hit Google.
#
# Emits one line of JSON ({"text","class","tooltip"}) for waybar.
#
# Usage:
#   calendar-status.sh          one-shot: print one line and exit (use waybar "interval")
#   calendar-status.sh --loop   long-running: print a line every TICK_SECS seconds
#                               (use waybar with no "interval" so it streams).
# The loop mode exists so the sub-minute countdown can tick second by second
# without paying the parse cost (and a process spawn) on every tick.
set -uo pipefail

SERVER="${CAL_SERVER:-ubuntu@server.jedbillyb.com}"
LOOKAHEAD_DAYS="${CAL_LOOKAHEAD_DAYS:-14}"
REFRESH="${CAL_REFRESH_SECS:-600}"        # re-fetch from Google at most this often
CACHE_DIR="${CAL_CACHE_DIR:-$HOME/.cache/waybar-calendar}"
SKIP_INPROGRESS="${CAL_SKIP_INPROGRESS:-1}"  # 1 = show next upcoming; 0 = include the event happening now
NEAR_MINS="${CAL_NEAR_MINS:-60}"    # within this many minutes, show a countdown ("in 15m") instead of the start time
SOON_MINS="${CAL_SOON_MINS:-10}"    # within this many minutes, highlight the module ("soon" class)
SHOW_ROOM="${CAL_SHOW_ROOM:-1}"     # 1 = append the event's Location (room), e.g. "L2PHY @SCI2"
ROOM_SEP="${CAL_ROOM_SEP:-@}"       # separator before the room
TICK_SECS="${CAL_TICK_SECS:-1}"     # --loop only: seconds between printed lines
CHECK_SECS="${CAL_CHECK_SECS:-15}"  # --loop only: how often to stat/re-read the cache file
RETRY_SECS="${CAL_RETRY_SECS:-60}"  # after a failed fetch, wait this long before trying again
STALE_SECS="${CAL_STALE_SECS:-5400}" # cache older than this + a failing fetch = say so in the bar

# The fetch backend. Override CAL_FETCH_CMD with any command that prints event
# lines in the format:  [YYYY-MM-DD HH:MM - HH:MM] Title [CalName] (id: ...)
#
# Two built-in backends, auto-selected:
#   local  - a read-only gcalendar.py CLI in its own venv under GCAL_DIR (kept
#            outside this repo since it holds the OAuth token). Used when present.
#   remote - SSH to a host running the same gcalendar.py. Fallback when there is
#            no local venv, so a fresh checkout works with zero setup.
GCAL_DIR="${CAL_GCAL_DIR:-$HOME/.local/share/waybar-calendar/gcal}"
# NB: these deliberately do NOT swallow stderr - refresh_cache() reads it to tell
# an expired OAuth token apart from a plain network failure.
LOCAL_FETCH="$GCAL_DIR/.venv/bin/python $GCAL_DIR/gcalendar.py list $LOOKAHEAD_DAYS"
REMOTE_FETCH="ssh -o BatchMode=yes -o ConnectTimeout=5 $SERVER \"cd obsidian-sync && python3 gcalendar.py list $LOOKAHEAD_DAYS\""
if [ -x "$GCAL_DIR/.venv/bin/python" ] && [ -f "$GCAL_DIR/gcalendar.py" ]; then
    DEFAULT_FETCH="$LOCAL_FETCH"
else
    DEFAULT_FETCH="$REMOTE_FETCH"
fi
FETCH_CMD="${CAL_FETCH_CMD:-$DEFAULT_FETCH}"
RAW="$CACHE_DIR/raw.txt"
STAMP="$CACHE_DIR/fetched_at"     # last *successful* fetch
ATTEMPT="$CACHE_DIR/attempted_at" # last fetch attempt, successful or not
ERRLOG="$CACHE_DIR/last_error"

mkdir -p "$CACHE_DIR"

# How the last fetch went: ok | auth | fail. Anything other than "ok" gets said
# out loud in the bar (see status_line) - a silently empty module is
# indistinguishable from "nothing on today", which is how a dead OAuth token
# went unnoticed for ten days. Persisted so a waybar restart doesn't silently
# show a blank module again until the next retry comes round.
STATEFILE="$CACHE_DIR/fetch_state"
FETCH_STATE="ok"
[ -f "$STATEFILE" ] && FETCH_STATE="$(cat "$STATEFILE" 2>/dev/null || echo ok)"

set_state() { FETCH_STATE="$1"; printf '%s\n' "$1" > "$STATEFILE"; }

# ── Refresh the cache if it is stale ────────────────────────────────────────────
refresh_cache() {
    local now last=0 attempt=0 data
    now="$(date +%s)"
    [ -f "$STAMP" ] && last="$(cat "$STAMP" 2>/dev/null || echo 0)"
    [ $(( now - last )) -ge "$REFRESH" ] || return 0
    # A failing backend never updates $STAMP, so without this second gate the
    # staleness check above stays true and we re-spawn the fetcher on every
    # CHECK_SECS tick, forever.
    [ -f "$ATTEMPT" ] && attempt="$(cat "$ATTEMPT" 2>/dev/null || echo 0)"
    [ $(( now - attempt )) -ge "$RETRY_SECS" ] || return 0
    printf '%s\n' "$now" > "$ATTEMPT"

    data="$(timeout 20 bash -c "$FETCH_CMD" 2>"$ERRLOG")"
    if [ -n "$data" ] && printf '%s' "$data" | grep -q '^\['; then
        printf '%s\n' "$data" > "$RAW"
        printf '%s\n' "$now" > "$STAMP"
        : > "$ERRLOG"
        set_state ok
        return 0
    fi
    # gcalendar.py keeps the literal "invalid_grant" in its error message for
    # exactly this check; a revoked/expired token never fixes itself, so it
    # needs a different message from "the network is down right now".
    if grep -qE 'invalid_grant|RefreshError|expired or revoked' "$ERRLOG" 2>/dev/null; then
        set_state auth
    else
        set_state fail
    fi
}

# Seconds since the last successful fetch (a very large number if never).
cache_age() {
    local now last=0
    now="$(date +%s)"
    [ -f "$STAMP" ] && last="$(cat "$STAMP" 2>/dev/null || echo 0)"
    printf '%s' "$(( now - last ))"
}

# ── Parse cached event lines ────────────────────────────────────────────────────
# gcalendar.py fmt_event() emits one event per block:
#   [YYYY-MM-DD HH:MM - HH:MM] Summary [CalName] (id: ...)
#     Location: <room>        (optional, indented)
#     Desc: ...               (optional, indented)
line_re='^\[([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}) - [^]]*\] (.+) \(id: [^)]*\)$'
loc_re='^[[:space:]]+Location:[[:space:]]*(.+)$'

dates=(); times=(); titles=(); rooms=(); starts=(); dows=(); prettys=()

parse_events() {
    dates=(); times=(); titles=(); rooms=(); starts=(); dows=(); prettys=()
    local line title stamps
    while IFS= read -r line; do
        if [[ "$line" =~ $line_re ]]; then
            title="${BASH_REMATCH[3]}"
            title="${title% \[*\]}"      # strip trailing " [CalName]" tag
            dates+=("${BASH_REMATCH[1]}")
            times+=("${BASH_REMATCH[2]}")
            titles+=("$title")
            rooms+=("")
        elif [[ "$line" =~ $loc_re ]] && [ "${#rooms[@]}" -gt 0 ]; then
            rooms[$(( ${#rooms[@]} - 1 ))]="${BASH_REMATCH[1]}"
        fi
    done < "$RAW"

    # Convert every start to an epoch in ONE date(1) call — a fork per event was
    # the bulk of this script's runtime (~1s for a fortnight of events).
    starts=()
    if [ "${#dates[@]}" -gt 0 ]; then
        local i
        stamps="$(for i in "${!dates[@]}"; do printf '%s %s\n' "${dates[$i]}" "${times[$i]}"; done \
                  | date -f - +%s 2>/dev/null)"
        mapfile -t starts <<< "$stamps"
        # If date choked, fall back to zeros so indexing stays aligned.
        [ "${#starts[@]}" -eq "${#dates[@]}" ] || starts=("${dates[@]/*/0}")

        # Pre-format the day strings render() needs ("Fri", "Fri 01 Aug") — same
        # reason: one date(1) call each here instead of one per event per tick.
        mapfile -t dows    < <(printf '%s\n' "${dates[@]}" | date -f - +%a 2>/dev/null)
        mapfile -t prettys < <(printf '%s\n' "${dates[@]}" | date -f - '+%a %d %b' 2>/dev/null)
        [ "${#dows[@]}"    -eq "${#dates[@]}" ] || dows=("${dates[@]}")
        [ "${#prettys[@]}" -eq "${#dates[@]}" ] || prettys=("${dates[@]}")
    fi
}

# ── Build the JSON line for "right now" ─────────────────────────────────────────
day_end=0; today=""; tomorrow=""
# Today/tomorrow only change at midnight, so compute them once per day rather
# than once per tick.
refresh_day() {
    local now="$1"
    [ "$now" -lt "$day_end" ] && return 0
    today="$(date -d "@$now" +%Y-%m-%d)"
    tomorrow="$(date -d "@$(( now + 86400 ))" +%Y-%m-%d)"
    day_end="$(date -d "$tomorrow 00:00" +%s)"
}

render() {
    local now first_text first_mins first_today tooltip count
    local i d t title room start_epoch dpfx short mins secs rel tt class
    printf -v now '%(%s)T' -1      # no fork: bash's own strftime
    refresh_day "$now"

    first_text=""; first_mins=999999; first_today=0; tooltip=""; count=0
    for i in "${!dates[@]}"; do
        d="${dates[$i]}"; t="${times[$i]}"; title="${titles[$i]}"
        room="${rooms[$i]}"; start_epoch="${starts[$i]}"

        # Show what's *next*, not what's happening now: skip events already started
        # (unless CAL_SKIP_INPROGRESS=0).
        if [ "$SKIP_INPROGRESS" = "1" ] && [ "$start_epoch" -le "$now" ]; then
            continue
        fi

        # Day prefix relative to today.
        case "$d" in
            "$today")    dpfx="" ;;
            "$tomorrow") dpfx="Tmrw " ;;
            *)           dpfx="${dows[$i]} " ;;
        esac

        short="$title"
        [ "${#short}" -gt 22 ] && short="${short:0:21}…"
        # Append the room, e.g. "L2PHY @SCI2".
        [ "$SHOW_ROOM" = "1" ] && [ -n "$room" ] && short="${short} ${ROOM_SEP}${room}"

        if [ -z "$first_text" ]; then
            secs=$(( start_epoch - now ))
            (( secs < 0 )) && secs=0
            # Round UP, so the countdown matches what you get by subtracting the
            # bar's own clock from the start time. Truncating reads a minute low
            # for all but the first second of each minute: at 11:57:30 a 12:00
            # class is 150s away, which truncates to "2m" while the clock still
            # says 11:57. Ceiling makes it exactly "clock minutes remaining".
            mins=$(( (secs + 59) / 60 ))
            if [ "$start_epoch" -gt "$now" ] && [ "$mins" -le "$NEAR_MINS" ]; then
                # Close by — relative countdown, e.g. "L2PHY @SCI2 in 15m".
                # Under a minute, count down in seconds rather than showing "1m".
                if   [ "$secs" -lt 60 ];   then rel="${secs}s"
                elif [ "$mins" -lt 60 ];   then rel="${mins}m"
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

        # Tooltip: up to 6 upcoming events, fuller titles + room.
        if [ "$count" -lt 6 ]; then
            tt="${prettys[$i]} ${t}  ${title}"
            [ -n "$room" ] && tt="${tt} (${room})"
            tooltip="${tooltip}${tt}\n"
            count=$((count+1))
        fi
    done

    if [ -z "$first_text" ]; then
        printf '{"text":"","class":"none","tooltip":false}\n'
        return
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
    esc "$first_text"; local text_json="$esc_out"
    esc "$tooltip";    local tip_json="$esc_out"
    printf '{"text":"%s","class":"%s","tooltip":"%s"}\n' "$text_json" "$class" "$tip_json"
}

# JSON-escape into $esc_out. Assigns rather than echoes so callers don't need a
# command substitution (a fork) on every tick.
esc_out=""
esc() { esc_out="${1//\\/\\\\}"; esc_out="${esc_out//\"/\\\"}"; }

# No cache at all (never fetched, backend unreachable) — collapse the module.
no_cache_line() { printf '{"text":"","class":"none","tooltip":false}\n'; }

# The token is dead and will not come back on its own - name the fix in the
# tooltip so it doesn't need rediscovering.
auth_line() {
    printf '{"text":"%s","class":"auth","tooltip":"%s"}\n' \
        " cal auth" \
        "Google Calendar token expired or revoked.\nRe-authorise:\n  $GCAL_DIR/.venv/bin/python $GCAL_DIR/gcalendar.py auth"
}

# Fetching is failing for some other reason (no network, SSH down) *and* the
# cache has aged out, so whatever is on screen can no longer be trusted.
stale_line() {
    printf '{"text":"%s","class":"stale","tooltip":"%s"}\n' \
        " cal stale" \
        "Calendar fetch failing; cache is $(( $(cache_age) / 3600 ))h old.\nSee $ERRLOG"
}

# Pick the right line for the current state. $1 is non-empty when parsed events
# are available to render.
status_line() {
    case "$FETCH_STATE" in
        auth) auth_line; return ;;
        fail) if [ "$(cache_age)" -ge "$STALE_SECS" ]; then stale_line; return; fi ;;
    esac
    if [ -n "$1" ]; then render; else no_cache_line; fi
}

if [ "${1:-}" = "--loop" ]; then
    raw_sig=""; last_check=0
    while :; do
        printf -v tick_now '%(%s)T' -1
        # Cache work (fetch check + re-parse) at most every CHECK_SECS; the ticks
        # in between are pure bash so a 1s countdown costs no forks at all.
        if (( tick_now - last_check >= CHECK_SECS )); then
            last_check=$tick_now
            refresh_cache
            if [ -s "$RAW" ]; then
                sig="$(stat -c '%Y %s' "$RAW" 2>/dev/null)"
                if [ "$sig" != "$raw_sig" ]; then
                    parse_events
                    raw_sig="$sig"
                fi
            fi
        fi
        status_line "$raw_sig"
        if [ "$TICK_SECS" = "1" ]; then
            # Align to the next wall-clock second instead of a flat `sleep 1`,
            # so the countdown doesn't drift out of phase with the system
            # clock as loop-body runtime accumulates. $EPOCHREALTIME is a bash
            # builtin (microsecond wall time), so this costs no fork either.
            frac="${EPOCHREALTIME#*.}"
            remaining_us=$(( 1000000 - 10#${frac:0:6} ))
            printf -v sleep_for '%d.%06d' "$(( remaining_us / 1000000 ))" "$(( remaining_us % 1000000 ))"
            sleep "$sleep_for"
        else
            sleep "$TICK_SECS"
        fi
    done
else
    refresh_cache
    if [ -s "$RAW" ]; then
        parse_events
        status_line "yes"
    else
        status_line ""
    fi
fi

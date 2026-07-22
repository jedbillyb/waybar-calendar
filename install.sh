#!/bin/bash
# install.sh — symlink calendar-status.sh into ~/.config/waybar and print the
# config + CSS snippets you need to add.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAYBAR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"

mkdir -p "$WAYBAR_DIR"
chmod +x "$REPO_DIR/calendar-status.sh"
ln -sf "$REPO_DIR/calendar-status.sh" "$WAYBAR_DIR/calendar-status.sh"

echo "Linked:"
echo "  $WAYBAR_DIR/calendar-status.sh -> $REPO_DIR/calendar-status.sh"
cat <<'EOF'

Next steps
----------
1. Add "custom/calendar" to "modules-left" (or wherever you like) in
   ~/.config/waybar/config, and add this module definition:

    "custom/calendar": {
        "exec": "~/.config/waybar/calendar-status.sh",
        "return-type": "json",
        "interval": 60,
        "tooltip": true
    }

2. Point it at your calendar. By default it SSHes to a host running the
   gcalendar.py CLI. Override the backend with env vars in the exec, e.g.:

    "exec": "CAL_SERVER=me@host CAL_LOOKAHEAD_DAYS=14 ~/.config/waybar/calendar-status.sh"

   or supply your own fetch command that prints lines in the format
   `[YYYY-MM-DD HH:MM - HH:MM] Title [CalName] (id: ...)`:

    "exec": "CAL_FETCH_CMD='gcalcli --tsv agenda ...' ~/.config/waybar/calendar-status.sh"

3. Add the CSS in style.css.example to ~/.config/waybar/style.css.

4. Reload waybar:  pkill -x waybar; waybar &   (or restart it)
EOF

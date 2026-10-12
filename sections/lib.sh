# lib.sh - shared helpers for DigestMerlin sections.
#
# Section contract:
#   - print the section text on stdout (plain lines);
#   - raise alerts with add_alert "text";
#   - exit 0 when done, exit 3 when the section does not apply to this router
#     (tool not installed) - it is then skipped silently.
# A section can be run alone for testing:  sh <section>.sh
# (its alerts are then printed on stderr, prefixed with "ALERT:").

DM_DIR="${DM_DIR:-/jffs/addons/digestmerlin.d}"
DM_CONF="${DM_CONF:-$DM_DIR/digestmerlin.conf}"
DM_STATE="${DM_STATE:-$DM_DIR/state}"
SYSLOG_CUR="${SYSLOG_CUR:-/tmp/syslog.log}"
SYSLOG_OLD="${SYSLOG_OLD:-/tmp/syslog.log-1}"

NOW="${NOW:-$(date +%s)}"
WINDOW_H="${WINDOW_H:-24}"
SINCE="${SINCE:-$((NOW - WINDOW_H * 3600))}"

# User settings (all optional, see digestmerlin.conf.sample).
# shellcheck disable=SC1090
[ -f "$DM_CONF" ] && . "$DM_CONF"

# Previous log first, then current: covers as much of the window as possible.
read_logs() {
    cat "$SYSLOG_OLD" "$SYSLOG_CUR" 2>/dev/null
}

# Keep only syslog lines ("Mon dd HH:MM:SS ...") inside the window.
# Call it after a grep: it starts one date per line.
in_window() {
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -f; set -- $line; set +f
        ts=$(date -D "%b %e %H:%M:%S" -d "$1 $2 $3" +%s 2>/dev/null) || continue
        [ "$ts" -ge "$SINCE" ] && [ "$ts" -le "$NOW" ] && printf '%s\n' "$line"
    done
}

# "3h12m", "2d4h", "45m" from a number of seconds.
fmt_age() {
    s="$1"
    case "$s" in ''|*[!0-9]*) echo "?"; return ;; esac
    if [ "$s" -ge 86400 ]; then echo "$((s / 86400))d$(((s % 86400) / 3600))h"
    elif [ "$s" -ge 3600 ]; then echo "$((s / 3600))h$(((s % 3600) / 60))m"
    elif [ "$s" -ge 60 ]; then echo "$((s / 60))m"
    else echo "<1m"; fi
}

fmt_time() {
    date -d "@$1" '+%a %d %b %H:%M' 2>/dev/null || echo "?"
}

is_number() {
    case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

add_alert() {
    if [ -n "$DM_ALERTS" ]; then
        printf -- '- %s\n' "$1" >> "$DM_ALERTS"
    else
        printf 'ALERT: %s\n' "$1" >&2
    fi
}

# Small persistent values kept between runs (one file per key).
state_get() {
    cat "$DM_STATE/$1" 2>/dev/null
}
state_set() {
    [ -n "$DM_PREVIEW" ] && return 0   # a preview never changes the state
    # shellcheck disable=SC2174
    mkdir -p -m 700 "$DM_STATE" && printf '%s\n' "$2" > "$DM_STATE/$1"
}

# nvram reads can hang on some firmware builds: never wait more than 5 s.
# BusyBox before 1.30 wants "timeout -t 5", later versions "timeout 5".
if timeout --help 2>&1 | grep -q -- '-t SEC'; then
    nv() { timeout -t 5 nvram get "$1" 2>/dev/null; }
elif command -v timeout >/dev/null 2>&1; then
    nv() { timeout 5 nvram get "$1" 2>/dev/null; }
else
    nv() { nvram get "$1" 2>/dev/null; }
fi

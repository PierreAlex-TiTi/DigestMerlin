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
# A settings file with a syntax error is ignored (defaults are used); Windows
# line endings are tolerated; a number setting that is not a plain number is
# ignored (its default is used). The main script reports both in the digest.
DM_NUM_SETTINGS="WG_HANDSHAKE_MAX SPEEDTEST_MAX_AGE_H BACKUP_MAX_AGE_H DISK_ALERT_PCT CPU_TEMP_ALERT REBOOT_MAX_DAYS DEVICES_IGNORE_PRIVATE_MAC"
if [ -f "$DM_CONF" ]; then
    _f="$DM_CONF"
    if grep -q "$(printf '\r')" "$DM_CONF" 2>/dev/null; then
        _f="/tmp/digestmerlin-conf.$$"; tr -d '\r' < "$DM_CONF" > "$_f" 2>/dev/null || _f=""
    fi
    # shellcheck disable=SC1090
    [ -n "$_f" ] && sh -n "$_f" 2>/dev/null && ( . "$_f" ) >/dev/null 2>&1 && . "$_f"
    [ "$_f" = "$DM_CONF" ] || rm -f "$_f"
    for _k in $DM_NUM_SETTINGS; do
        eval "_v=\${$_k}"
        [ -n "$_v" ] || continue
        _v=$(echo "$_v" | sed 's/^0*\([0-9]\)/\1/')       # "08" -> "8", never octal
        case "$_v" in *[!0-9]*) unset "$_k"; continue ;; esac
        [ ${#_v} -le 6 ] || { unset "$_k"; continue; }
        # Same limits as the menu (the main script reports values outside them).
        case "$_k" in
            WG_HANDSHAKE_MAX) _r="180 86400" ;; SPEEDTEST_MAX_AGE_H|BACKUP_MAX_AGE_H) _r="1 720" ;;
            DISK_ALERT_PCT) _r="1 100" ;; CPU_TEMP_ALERT) _r="40 125" ;; REBOOT_MAX_DAYS) _r="1 365" ;;
            DEVICES_IGNORE_PRIVATE_MAC) _r="0 1" ;; *) _r="0 999999" ;;
        esac
        if [ "$_v" -lt "${_r% *}" ] || [ "$_v" -gt "${_r#* }" ]; then unset "$_k"; continue; fi
        eval "$_k=\$_v"
    done
fi

# Syslog dates are read with "date -D", which only BusyBox's date has. Entware
# can put GNU date first in PATH (coreutils-date): fall back to BusyBox's own.
# pdate FORMAT TEXT -> seconds since 1970 (fails if the text does not match)
if date -D "%Y" -d "2000" +%Y >/dev/null 2>&1; then
    pdate() { date -D "$1" -d "$2" +%s 2>/dev/null; }
elif busybox date -D "%Y" -d "2000" +%Y >/dev/null 2>&1; then
    pdate() { busybox date -D "$1" -d "$2" +%s 2>/dev/null; }
elif /bin/date -D "%Y" -d "2000" +%Y >/dev/null 2>&1; then
    pdate() { /bin/date -D "$1" -d "$2" +%s 2>/dev/null; }
else
    pdate() { return 1; }
fi

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
        ts=$(pdate "%b %e %H:%M:%S" "$1 $2 $3") || continue
        # Syslog lines carry no year: a "Dec 31" line read on Jan 1 belongs to
        # last year. Re-read it with last year's number (leap years included).
        if [ "$ts" -gt $((NOW + 86400)) ]; then
            ts=$(pdate "%Y %b %e %H:%M:%S" "$(($(date +%Y) - 1)) $1 $2 $3") || continue
        fi
        [ "$ts" -ge "$SINCE" ] && [ "$ts" -le "$NOW" ] && printf '%s\n' "$line"
    done
}

# "3h12m", "2d4h", "45m" from a number of seconds.
fmt_age() {
    s="$1"
    # Slightly negative: the event happened after the digest started (e.g. a
    # WireGuard handshake renewed while the sections were running) = just now.
    case "$s" in -[0-9]*) s=0 ;; esac
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
# BusyBox before 1.30 wants "timeout -t 5", later versions "timeout 5"; Merlin's
# BusyBox has no timeout at all (Entware adds one): then the read runs in the
# background and is stopped after 5 s.
# Each form is tested by running it ("command -v" is not reliable on routers).
# KILL, not TERM: a stuck read may ignore TERM.
if timeout -t 1 -s KILL true >/dev/null 2>&1; then
    nv() { timeout -t 5 -s KILL nvram get "$1" 2>/dev/null; }
elif timeout -s KILL 1 true >/dev/null 2>&1; then
    nv() { timeout -s KILL 5 nvram get "$1" 2>/dev/null; }
else
    nv() {
        _nvo="/tmp/digestmerlin-nv.$$"
        nvram get "$1" > "$_nvo" 2>/dev/null &
        _nvp=$!; _nvi=0
        while kill -0 "$_nvp" 2>/dev/null && [ "$_nvi" -lt 50 ]; do
            usleep 100000 2>/dev/null || sleep 1
            _nvi=$((_nvi + 1))
        done
        kill -9 "$_nvp" 2>/dev/null; wait "$_nvp" 2>/dev/null
        cat "$_nvo" 2>/dev/null; rm -f "$_nvo"
    }
fi

#!/bin/sh
# TITLE: DIVERSION (ad blocking)
. "$(dirname "$0")/lib.sh"

DIV_DIR="${DIV_DIR:-/opt/share/diversion}"            # Diversion lives on the USB drive
DIV_POSTCONF="${DIV_POSTCONF:-/jffs/scripts/dnsmasq.postconf}"
DNSMASQ_CONF="${DNSMASQ_CONF:-/etc/dnsmasq.conf}"
cfg="$DIV_DIR/.conf/diversion.conf"
list="$DIV_DIR/list/blockinglist.conf"

if [ ! -f "$cfg" ]; then
    # Diversion leaves a hook on /jffs: if it is there, Diversion is installed but
    # its files on the USB drive cannot be read - ad blocking is not running.
    if grep -q '# Added by Diversion' "$DIV_POSTCONF" 2>/dev/null; then
        echo "Diversion: installed, but its files on the USB drive are missing"
        add_alert "Diversion: its files on the USB drive are missing ($DIV_DIR) - is the drive mounted? Ads are not blocked"
        exit 0
    fi
    exit 3
fi

# "Oct 15 02:10:02" (no year, like syslog) -> seconds. Read on Jan 1, a
# "Dec 31" date belongs to last year.
ts_of() {
    set -f; set -- $1; set +f
    t=$(pdate "%b %e %H:%M:%S" "$1 $2 $3") || return 1
    if [ "$t" -gt $((NOW + 86400)) ]; then
        t=$(pdate "%Y %b %e %H:%M:%S" "$(($(date +%Y) - 1)) $1 $2 $3") || return 1
    fi
    echo "$t"
}

# diversion.conf: KEY=value or KEY="value", one per line.
cfg_get() { sed -n "s/^$1=//p" "$cfg" 2>/dev/null | head -1 | tr -d '"'; }

ver=$(cfg_get thisVERSION)
status=$(cfg_get DIVERSION_STATUS)
adblock=$(cfg_get adblocking)
echo "Diversion ${ver:-?}: ${status:-status unknown} | ad blocking ${adblock:-?}"
active=1
if [ "$status" != "enabled" ]; then
    case "$status" in disabled) st="" ;; *) st=" (status: ${status:-unknown})" ;; esac
    add_alert "Diversion: disabled$st - ads are not blocked"
    active=0
elif [ "$adblock" != "on" ]; then
    add_alert "Diversion: ad blocking is off"
    active=0
fi

# Blocking list: one domain per line ("local=/example.com/").
type=$(cfg_get bfType)
if [ -s "$list" ]; then
    n=$(grep -c . "$list")
    loaded="loaded by dnsmasq"
    grep -qx "conf-file=$list" "$DNSMASQ_CONF" 2>/dev/null || loaded="NOT loaded by dnsmasq"
    echo "Blocking list: $n domains${type:+ ($type)} - $loaded"
    if [ "$active" = 1 ] && [ "$loaded" != "loaded by dnsmasq" ]; then
        add_alert "Diversion: the blocking list is not loaded by dnsmasq - ads are not blocked"
    fi
    # A sudden drop usually means a failed or interrupted list update.
    prev=$(state_get diversion_domains)
    if is_number "$prev" && [ "$prev" -gt 0 ] && [ "$n" -lt $((prev / 2)) ]; then
        add_alert "Diversion: blocking list dropped from $prev to $n domains since the last digest"
    fi
    state_set diversion_domains "$n"
else
    echo "Blocking list: missing or empty"
    [ "$active" = 1 ] && add_alert "Diversion: the blocking list is missing or empty - ads are not blocked"
fi

# List update: last run and weekly schedule.
day=$(cfg_get bfUpdateDay)
last=$(cfg_get bfUpdateLastRun)
case "$day" in
    Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday) sched="weekly on $day"; max_age=$((8 * 86400)) ;;
    *) sched="schedule: ${day:-unknown}"; max_age="" ;;
esac
ts=""; [ -n "$last" ] && ts=$(ts_of "$last")
if is_number "$ts"; then
    age=$((NOW - ts))
    echo "List update: $(fmt_time "$ts") ($(fmt_age "$age") ago, $sched)"
    if [ "$active" = 1 ] && [ -n "$max_age" ] && [ "$age" -gt "$max_age" ]; then
        add_alert "Diversion: blocking list not updated for $(fmt_age "$age") ($sched)"
    fi
else
    echo "List update: never recorded ($sched)"
fi

# Ads counter, written to syslog by Diversion (daily, reset weekly).
c=$(read_logs | grep 'Diversion: updated.*ads counter: ' | tail -1)
if [ -n "$c" ]; then
    cts=$(ts_of "$c")
    nums=$(printf '%s\n' "$c" | sed -n 's/.*ads counter: \([0-9,]*\) total, \([0-9,]*\) this week, \([0-9,]*\) new since last count.*/\2 \3/p')
    if [ -n "$nums" ]; then
        set -- $nums
        when=""; is_number "$cts" && when=" ($(fmt_time "$cts"))"
        # The weekly reset line carries the total of the week that just ended.
        case "$c" in *"reset weekly"*) wk="last week" ;; *) wk="this week" ;; esac
        echo "Ads blocked: $2 in the last count, $1 $wk$when"
    fi
fi
exit 0

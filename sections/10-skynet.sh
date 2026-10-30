#!/bin/sh
# TITLE: SKYNET FIREWALL
. "$(dirname "$0")/lib.sh"

[ -f /jffs/scripts/firewall ] || exit 3

# Install location, as recorded by Skynet in firewall-start.
skynetloc=$(sed -n 's/.*skynetloc=\([^ ]*\).*/\1/p' /jffs/scripts/firewall-start 2>/dev/null | head -1)
cfg="$skynetloc/skynet.cfg"
cfg_get() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$cfg" 2>/dev/null | head -1; }

set_count() {
    ipset list "$1" -t 2>/dev/null | awk '/^Number of entries/ {print $4}'
}
ips=$(set_count Skynet-Blacklist)
ranges=$(set_count Skynet-BlockedRanges)

if ! is_number "$ips"; then
    echo "Blacklist: not loaded"
    add_alert "Skynet: blacklist not loaded (ipset Skynet-Blacklist missing) - is Skynet running?"
    exit 0
fi
is_number "$ranges" || ranges=0
echo "Blacklist: $ips IPs | $ranges ranges"

# A sudden drop usually means a failed or interrupted list refresh.
prev=$(state_get skynet_ips)
if is_number "$prev" && [ "$prev" -gt 0 ] && [ "$ips" -lt $((prev / 2)) ]; then
    add_alert "Skynet: blacklist dropped from $prev to $ips IPs since the last digest"
fi
state_set skynet_ips "$ips"

# Malware list refresh: schedule and age come from Skynet's own settings.
freq=$(cfg_get banmalwareupdate)
last=$(cfg_get banmalwarelastupdated)
# With banmalwarehour "auto" (Skynet's default, also when missing), Skynet picks
# a new random hour (1-23) each time it re-creates its cron job (start, update):
# two daily refreshes can then be up to 46h apart. A fixed hour (0-23) keeps
# 24h. Any other value is read as "auto", as Skynet itself does.
hour=$(cfg_get banmalwarehour)
case "$freq" in
    daily)  case "$hour" in
                [0-9]|1[0-9]|2[0-3]) max_age=$((26 * 3600)) ;;
                *)                   max_age=$((48 * 3600)) ;;
            esac ;;
    weekly) max_age=$((8 * 86400)) ;;
    *)      max_age="" ;;
esac
if is_number "$last" && [ "$last" -gt 0 ]; then
    age=$((NOW - last))
    echo "List refresh: $(fmt_time "$last") ($(fmt_age "$age") ago, ${freq:-schedule unknown})"
    if [ -n "$max_age" ] && [ "$age" -gt "$max_age" ]; then
        add_alert "Skynet: malware lists not refreshed for $(fmt_age "$age") (schedule: $freq)"
    fi
else
    echo "List refresh: never recorded (${freq:-schedule unknown})"
fi

fails=$(read_logs | grep "Skynet" | grep "Download Failed" | in_window)
if [ -n "$fails" ]; then
    n=$(printf '%s\n' "$fails" | wc -l)
    srcs=$(printf '%s\n' "$fails" | sed -n 's/.*Download Failed (\([^)]*\)).*/\1/p' | sort -u | head -3 | tr '\n' ' ')
    echo "Download failures (${WINDOW_H}h): $n"
    add_alert "Skynet: $n list download failure(s) in ${WINDOW_H}h${srcs:+ - ${srcs% }}"
else
    echo "Download failures (${WINDOW_H}h): 0"
fi

# Blocked traffic, from Skynet's history database (v9 and later).
db="$skynetloc/history.db"
SQLITE=""
for s in /usr/sbin/sqlite3 /usr/bin/sqlite3 /opt/bin/sqlite3; do
    [ -x "$s" ] && { SQLITE="$s"; break; }
done
if [ -n "$skynetloc" ] && [ -f "$db" ] && [ -n "$SQLITE" ]; then
    q() { "$SQLITE" -readonly -noheader -cmd ".timeout 3000" "$db" "$1" 2>/dev/null; }
    # kind: 1 = inbound, 2 = outbound (a LAN device reached a banned address)
    inb=$(q "SELECT COUNT(*) FROM events WHERE kind=1 AND ts>=$SINCE")
    outb=$(q "SELECT COUNT(*) FROM events WHERE kind=2 AND ts>=$SINCE")
    echo "Blocked inbound (${WINDOW_H}h): ${inb:-?} | outbound: ${outb:-?}"
    if is_number "$outb" && [ "$outb" -gt 0 ]; then
        who=$(q "SELECT printf('%d.%d.%d.%d (%dx)', (src>>24)&255, (src>>16)&255, (src>>8)&255, src&255, COUNT(*)) FROM events WHERE kind=2 AND ts>=$SINCE GROUP BY src ORDER BY COUNT(*) DESC LIMIT 3" | tr '\n' ' ')
        wanip=$(nv wan0_ipaddr)
        [ -n "$wanip" ] && who=$(echo "$who" | awk -v w="$wanip" '{for (i = 1; i <= NF; i++) if ($i == w) $i = w " = this router"; print}')
        echo "Outbound blocks from: ${who% }"
    fi
    # Skynet moves log lines into the database every 30 min.
    col=$(q "SELECT value FROM meta WHERE key='collected'")
    if is_number "$col" && [ "$col" -gt 0 ] && [ $((NOW - col)) -gt 10800 ]; then
        add_alert "Skynet: log collection stalled for $(fmt_age $((NOW - col))) - syslog may grow quickly"
    fi
fi
exit 0

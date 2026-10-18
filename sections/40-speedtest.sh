#!/bin/sh
# TITLE: SPEED TESTS (spdMerlin)
. "$(dirname "$0")/lib.sh"

SPEEDTEST_MAX_AGE_H="${SPEEDTEST_MAX_AGE_H:-25}"
[ -f /jffs/scripts/spdmerlin ] || exit 3

# Results live on JFFS or on USB, depending on spdMerlin's storage setting.
found=0; stale=""
for f in /jffs/addons/spdmerlin.d/lastx_*.csv /opt/share/spdmerlin.d/lastx_*.csv; do
    [ -s "$f" ] || continue          # interface never tested
    name=$(basename "$f" .csv); name=${name#lastx_}
    # Newest result first: timestamp,download,upload,latency,jitter,...
    IFS=, read -r ts dl ul lat _rest < "$f"
    is_number "$ts" || continue
    found=1
    age=$((NOW - ts))
    # An interface excluded from automatic tests in spdMerlin ("#excluded#" in
    # its .interfaces_user) keeps its last result: shown, never "stale".
    excl=""
    grep -q "^${name}[ #].*#" "${f%/*}/.interfaces_user" 2>/dev/null && excl=", excluded from automatic tests"
    echo "$name: ${dl%.*} down / ${ul%.*} up Mbps, ${lat%.*} ms ($(fmt_age "$age") ago$excl)"
    if [ -z "$excl" ] && [ "$age" -gt $((SPEEDTEST_MAX_AGE_H * 3600)) ]; then
        stale="$stale $name"
    fi
done
[ "$found" = "1" ] || echo "No results yet"
[ -n "$stale" ] && add_alert "spdMerlin: no new result for more than ${SPEEDTEST_MAX_AGE_H}h on:$stale"

errs=$(read_logs | grep "spdMerlin" | grep "ERROR running speedtest" | in_window)
if [ -n "$errs" ]; then
    n=$(printf '%s\n' "$errs" | wc -l)
    echo "Failed tests (${WINDOW_H}h): $n"
    add_alert "spdMerlin: $n failed speed test(s) in ${WINDOW_H}h"
fi
exit 0

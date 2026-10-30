#!/bin/sh
# TITLE: SPEED TESTS (spdMerlin)
. "$(dirname "$0")/lib.sh"

SPEEDTEST_MAX_AGE_H="${SPEEDTEST_MAX_AGE_H:-25}"
[ -f /jffs/scripts/spdmerlin ] || exit 3

# Trends ("To watch"): each result is compared with the usual best of the same
# interface AT THE SAME TIME OF DAY (evening congestion would otherwise flag
# every evening test). spdMerlin keeps only its last 10 results (lastx_*.csv),
# so the digest keeps its own 30-day history of them (state/speed_<if>.hist).
HIST_DAYS=30        # history kept
SLOT_S=5400         # "same time of day" = within 90 minutes
WATCH_RANK=3        # usual best = 3rd best result of the slot
WATCH_MIN=7         # results needed in the slot before any comparison
WATCH_PCT=30        # flagged when this % or more below the usual best

# VPN server in use for a tunnel interface (spdMerlin name), empty for the WAN.
# A tunnel is only compared with its results on the SAME server: VPNMON-R3 or a
# manual change can move it to a slower or faster server, which says nothing
# about how the tunnel usually runs (the change itself is shown in VPN).
# WGVPNn is wgcN (spdMerlin's own mapping), VPNCn is OpenVPN client n.
vpn_server() {
    case "$1" in
        WGVPN[1-5]) v=$(nv "wgc${1#WGVPN}_ep_addr") ;;
        VPNC[1-5])  v=$(nv "vpn_client${1#VPNC}_addr") ;;
        *)          return 0 ;;
    esac
    printf '%s' "$v" | tr -cd 'A-Za-z0-9.:-' | cut -c1-64
}

# Merge the newest results of $1 (lastx file) into the history of interface $2.
# New results get the VPN server $3 as a 4th field (tunnels only). A result
# already in the history keeps its own server. Prints the merged history
# (ts,down,up[,server]; oldest first); saves it unless preview.
merge_history() {
    m_h="$DM_STATE/speed_$2.hist"
    m_t="/tmp/digestmerlin-spd.$$"
    { cat "$m_h" 2>/dev/null
      awk -F, -v srv="$3" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.]+$/ && $3 ~ /^[0-9.]+$/ {
          print $1 "," $2 "," $3 (srv != "" ? "," srv : "") }' "$1"
    } | awk -F, -v cut=$((NOW - HIST_DAYS * 86400)) '$1 >= cut && $1 <= '"$NOW"' + 3600 && !seen[$1]++' \
      | sort -t, -k1,1n > "$m_t" 2>/dev/null
    cat "$m_t"
    if [ -z "$DM_PREVIEW" ] && [ -s "$m_t" ]; then
        # shellcheck disable=SC2174
        mkdir -p -m 700 "$DM_STATE" 2>/dev/null && cp "$m_t" "$m_h.new" 2>/dev/null && mv "$m_h.new" "$m_h" 2>/dev/null
    fi
    rm -f "$m_t"
}

# Compare the result at time $1 (down $2, up $3) with the history on stdin;
# with a server $4, only the results on that server count.
# Prints "download|upload PCT REF" for each value far below its usual best.
compare_slot() {
    awk -F, -v ts="$1" -v dl="$2" -v ul="$3" -v srv="$4" -v slot="$SLOT_S" -v rank="$WATCH_RANK" \
        -v min="$WATCH_MIN" -v pct="$WATCH_PCT" '
        function best(a, n,    i, j, t) {     # rank-th largest of a[1..n]
            for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] < t; j--) a[j + 1] = a[j]; a[j + 1] = t }
            return a[rank]
        }
        function check(what, v, a, n,    r) {
            r = best(a, n)
            if (r > 0 && v * 100 <= r * (100 - pct)) printf "%s %d %d\n", what, int((r - v) * 100 / r + 0.5), int(r + 0.5)
        }
        $1 != ts && (srv == "" || $4 == srv) {
            d = ($1 - ts) % 86400; if (d < 0) d += 86400; if (d > 43200) d = 86400 - d
            if (d <= slot) { n++; D[n] = $2; U[n] = $3 }
        }
        END { if (n >= min) { check("download", dl, D, n); check("upload", ul, U, n) } }'
}

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
    # Same when automatic tests are turned off in spdMerlin (AUTOMATICMODE=false).
    excl=""
    grep -q "^${name}[ #].*#" "${f%/*}/.interfaces_user" 2>/dev/null && excl=", excluded from automatic tests"
    grep -q '^AUTOMATICMODE=false' "${f%/*}/config" 2>/dev/null && excl=", automatic tests off"
    echo "$name: ${dl%.*} down / ${ul%.*} up Mbps, ${lat%.*} ms ($(fmt_age "$age") ago$excl)"
    srv=$(vpn_server "$name")
    vpn=""; case "$name" in WGVPN*|VPNC*) vpn=1 ;; esac
    hist=$(merge_history "$f" "$name" "$srv")
    # A tunnel whose server cannot be read (nvram not answering) is not compared.
    if [ -z "$excl" ] && [ "$age" -le $((SPEEDTEST_MAX_AGE_H * 3600)) ] && { [ -z "$vpn" ] || [ -n "$srv" ]; }; then
        printf '%s\n' "$hist" | compare_slot "$ts" "$dl" "$ul" "$srv" | while read -r what drop ref; do
            echo "  To watch: $what -$drop% vs its best at this time of day ($ref Mbps)"
            add_watch "$name $what -$drop% vs its best at this time of day"
        done
    fi
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

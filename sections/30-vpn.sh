#!/bin/sh
# TITLE: VPN
. "$(dirname "$0")/lib.sh"

WG_HANDSHAKE_MAX="${WG_HANDSHAKE_MAX:-600}"   # seconds
VR3="/jffs/scripts/vpnmon-r3.sh"
VR3LOG="/jffs/addons/vpnmon-r3.d/vpnmon-r3.log"

shown=0

# --- WireGuard clients enabled in the router (wgc1..wgc5)
for n in 1 2 3 4 5; do
    [ "$(nv "wgc${n}_enable")" = "1" ] || continue
    shown=1
    ifc="wgc$n"
    desc=$(nv "wgc${n}_desc")
    if ! ip link show "$ifc" >/dev/null 2>&1; then
        echo "WGC$n${desc:+ ($desc)}: DOWN (interface missing)"
        add_alert "VPN: WireGuard client WGC$n is enabled but its interface is down"
        continue
    fi
    ep=$(wg show "$ifc" endpoints 2>/dev/null | awk 'NR == 1 {print $2}')
    hs=$(wg show "$ifc" latest-handshakes 2>/dev/null | awk 'NR == 1 {print $2}')
    if is_number "$hs" && [ "$hs" -gt 0 ]; then
        age=$((NOW - hs))
        echo "WGC$n${desc:+ ($desc)}: UP | ${ep:-endpoint ?} | handshake $(fmt_age "$age") ago"
        if [ "$age" -gt "$WG_HANDSHAKE_MAX" ]; then
            add_alert "VPN: WGC$n has had no handshake for $(fmt_age "$age") - tunnel probably not passing traffic"
        fi
    else
        echo "WGC$n${desc:+ ($desc)}: UP | ${ep:-endpoint ?} | no handshake yet"
        add_alert "VPN: WGC$n is up but has never completed a handshake"
    fi
done

# --- OpenVPN clients (1..5). State: 0 stopped, 1 connecting, 2 connected, -1 error.
# A client is reported when it is running, or set to start with the WAN.
eas=",$(nv vpn_clientx_eas),"
for n in 1 2 3 4 5; do
    st=$(nv "vpn_client${n}_state")
    case "$st" in -1|1|2) ;; *) st=0 ;; esac
    auto=0
    case "$eas" in *",$n,"*) auto=1 ;; esac
    [ "$st" = "0" ] && [ "$auto" = "0" ] && continue
    shown=1
    desc=$(nv "vpn_client${n}_desc")
    srv="$(nv "vpn_client${n}_addr"):$(nv "vpn_client${n}_port")"
    case "$st" in
        2)  if ip link show "tun1$n" >/dev/null 2>&1; then
                echo "OpenVPN $n${desc:+ ($desc)}: CONNECTED | $srv"
            else
                echo "OpenVPN $n${desc:+ ($desc)}: DOWN (tun1$n missing) | $srv"
                add_alert "VPN: OpenVPN client $n reports connected but its interface tun1$n is missing"
            fi ;;
        1)  echo "OpenVPN $n${desc:+ ($desc)}: CONNECTING | $srv"
            add_alert "VPN: OpenVPN client $n is still connecting" ;;
        -1) echo "OpenVPN $n${desc:+ ($desc)}: ERROR (code $(nv "vpn_client${n}_errno")) | $srv"
            add_alert "VPN: OpenVPN client $n is in error (code $(nv "vpn_client${n}_errno"))" ;;
        0)  echo "OpenVPN $n${desc:+ ($desc)}: STOPPED (set to start with WAN) | $srv"
            add_alert "VPN: OpenVPN client $n should start with the WAN but is stopped" ;;
    esac
done

# --- VPNMON-R3 (optional): is it running, and what did it change?
if [ -f "$VR3" ]; then
    shown=1
    if ps w 2>/dev/null | grep -q "[v]pnmon-r3.sh"; then
        echo "VPNMON-R3: running"
    else
        echo "VPNMON-R3: NOT running"
        add_alert "VPN: VPNMON-R3 is installed but not running - tunnels are not monitored"
    fi
    # Log lines: "Oct 07 2026 07:34:26 host VPNMON-R3[pid] - INFO: WGC1 Connection Restarted [SEQ] - New Server: ..."
    if [ -f "$VR3LOG" ]; then
        restarts=$(tail -1000 "$VR3LOG" | grep "Connection Restarted" | while IFS= read -r l; do
            set -f; set -- $l; set +f
            t=$(pdate "%b %d %Y %H:%M:%S" "$1 $2 $3 $4") || continue
            [ "$t" -ge "$SINCE" ] && [ "$t" -le "$NOW" ] || continue
            slot=$(printf '%s\n' "$l" | sed -n 's/.*INFO: \([^ ]*\) Connection Restarted.*/\1/p')
            srv=$(printf '%s\n' "$l" | sed -n 's/.* Server: //p')
            printf '  %s %s -> %s\n' "$(printf '%s' "$4" | cut -c1-5)" "$slot" "$srv"
        done)
        if [ -n "$restarts" ]; then
            echo "Tunnel restarts by VPNMON-R3 (${WINDOW_H}h): $(printf '%s\n' "$restarts" | wc -l)"
            printf '%s\n' "$restarts" | tail -5
        else
            echo "Tunnel restarts by VPNMON-R3 (${WINDOW_H}h): 0"
        fi
    fi
fi

[ "$shown" = "1" ] || exit 3
exit 0

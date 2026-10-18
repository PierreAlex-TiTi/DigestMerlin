#!/bin/sh
# TITLE: NEW DEVICES
. "$(dirname "$0")/lib.sh"

LEASES="${LEASES:-/var/lib/misc/dnsmasq.leases}"
DEVICES_IGNORE_PRIVATE_MAC="${DEVICES_IGNORE_PRIVATE_MAC:-0}"
[ -f "$LEASES" ] || exit 3

known="$DM_STATE/known_macs"
# IPv4 leases only (IPv6 lines and the "duid" line carry no MAC), one line per MAC.
current=$(awk 'tolower($2) ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])$/ {
                   m = tolower($2); if (!(m in seen)) {seen[m] = 1; print m, $3, $4}}' "$LEASES" | sort)
n_now=$(printf '%s\n' "$current" | grep -c .)

if [ ! -f "$known" ]; then
    # First run: everything present today is the baseline, nothing is "new".
    if [ -z "$DM_PREVIEW" ]; then
        # shellcheck disable=SC2174
        mkdir -p -m 700 "$DM_STATE" && printf '%s\n' "$current" | awk 'NF {print $1}' > "$known"
        echo "Baseline created: $n_now device(s) recorded as known"
    else
        echo "No baseline yet (created on the first real run): $n_now device(s) leased now"
    fi
    exit 0
fi

new=""; names=""
while read -r mac ip name; do
    [ -n "$mac" ] || continue
    grep -qx "$mac" "$known" && continue
    # Phones and computers often use a random "private" MAC address
    # (second hex digit 2, 6, A or E): flagged, optionally ignored.
    priv=""
    case "$mac" in ?[26ae]:*) priv=" (private MAC)" ;; esac
    [ -n "$priv" ] && [ "$DEVICES_IGNORE_PRIVATE_MAC" = "1" ] && continue
    [ "$name" = "*" ] && name="no name"
    new="${new}  $mac  $ip  ${name:-no name}$priv
"
    names="${names}${names:+, }$mac (${name:-no name})"
done <<EOF
$current
EOF

if [ -n "$new" ]; then
    n_new=$(printf '%s' "$new" | grep -c .)
    echo "New device(s) since the last digest: $n_new"
    printf '%s' "$new"
    # The alert names the devices: if this digest cannot be sent, the alert is
    # repeated in the next one, while this section will no longer list them.
    add_alert "Network: $n_new new device(s) on the LAN: $names"
    if [ -z "$DM_PREVIEW" ]; then
        printf '%s' "$new" | awk '{print $1}' >> "$known"
    fi
else
    echo "No new device ($n_now leased now)"
fi
exit 0

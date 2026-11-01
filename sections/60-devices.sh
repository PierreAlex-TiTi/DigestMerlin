#!/bin/sh
# TITLE: NEW DEVICES
. "$(dirname "$0")/lib.sh"

LEASES="${LEASES:-/var/lib/misc/dnsmasq.leases}"
DEVICES_IGNORE_PRIVATE_MAC="${DEVICES_IGNORE_PRIVATE_MAC:-0}"
[ -f "$LEASES" ] || exit 3

known="$DM_STATE/known_macs"
# Devices already announced by the instant e-mail (setting NEW_DEVICE_ALERT, run
# by "digestmerlin.sh watch"): "epoch|mac|ip|name", listed again here once.
alerted="$DM_STATE/devices_alerted"
# IPv4 leases only (IPv6 lines and the "duid" line carry no MAC), one line per MAC.
current=$(awk 'tolower($2) ~ /^[0-9a-f][0-9a-f](:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])(:[0-9a-f][0-9a-f])$/ {
                   m = tolower($2); if (!(m in seen)) {seen[m] = 1; print m, $3, $4}}' "$LEASES" | sort)
n_now=$(printf '%s\n' "$current" | grep -c .)

if [ ! -s "$known" ]; then       # missing or empty: no baseline yet
    # The instant e-mail waits for the baseline, created by a digest.
    [ -n "$DM_DEVICE_WATCH" ] && exit 0
    # First run: everything present today is the baseline, nothing is "new".
    # With no lease at all (e.g. just after a reboot) the baseline waits for the
    # next run: otherwise every device would then be reported as new.
    if [ "$n_now" -eq 0 ]; then
        echo "No device leased yet: the list of known devices is created on the next run"
    elif [ -z "$DM_PREVIEW" ]; then
        # shellcheck disable=SC2174
        # Written aside, then renamed: a full /jffs never leaves an empty list
        # (every device would then be reported as new).
        if mkdir -p -m 700 "$DM_STATE" && printf '%s\n' "$current" | awk 'NF {print $1}' > "$known.new" \
            && [ -s "$known.new" ] && mv "$known.new" "$known"; then
            echo "Baseline created: $n_now device(s) recorded as known"
        else
            rm -f "$known.new"
            echo "Could not record the known devices (is /jffs full?) - tried again on the next run"
        fi
    else
        echo "No baseline yet (created on the first real run): $n_now device(s) leased now"
    fi
    exit 0
fi

# The instant e-mail and the digest never handle the list at the same time.
if [ -z "$DM_DEVICE_WATCH" ]; then
    lk=/tmp/digestmerlin-devices.lock; i=0
    while ! mkdir "$lk" 2>/dev/null; do
        p=$(cat "$lk/pid" 2>/dev/null)
        # A lock left by a run that died (no such process) is taken over.
        if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$lk"; continue; fi
        i=$((i + 1)); [ "$i" -ge 60 ] && { lk=""; break; }   # 60 s: go on without it
        sleep 1
    done
    [ -n "$lk" ] && { echo $$ > "$lk/pid"; trap 'rm -rf "$lk"' EXIT; }
fi

new=""; names=""; wnew=""
while read -r mac ip name; do
    [ -n "$mac" ] || continue
    grep -qx "$mac" "$known" && continue
    # Phones and computers often use a random "private" MAC address
    # (second hex digit 2, 6, A or E): flagged, optionally ignored.
    priv=""
    case "$mac" in ?[26ae]:*) priv=" (private MAC)" ;; esac
    [ -n "$priv" ] && [ "$DEVICES_IGNORE_PRIVATE_MAC" = "1" ] && continue
    [ "$name" = "*" ] && name="no name"
    wnew="${wnew}${mac}|${ip}|${name:-no name}|${priv}
"
    new="${new}  $mac  $ip  ${name:-no name}$priv
"
    names="${names}${names:+, }$mac (${name:-no name})"
done <<EOF
$current
EOF

# Watch mode: only the new devices, one per line, for the instant e-mail
# (the caller records them once the e-mail is sent).
if [ -n "$DM_DEVICE_WATCH" ]; then
    printf '%s' "$wnew"
    exit 0
fi

# Devices already announced by the instant e-mail since the last digest.
seen=""
if [ -s "$alerted" ]; then
    seen=$(awk -F'|' '$1 ~ /^[0-9]+$/ && NF >= 4' "$alerted" | while IFS='|' read -r ts mac ip name priv; do
        echo "  $mac  $ip  $name$priv (alerted at $(date -d "@$ts" '+%a %H:%M' 2>/dev/null))"
    done)
fi
n_seen=0; [ -n "$seen" ] && n_seen=$(printf '%s\n' "$seen" | grep -c .)
n_new=0; [ -n "$new" ] && n_new=$(printf '%s' "$new" | grep -c .)
if [ $((n_new + n_seen)) -gt 0 ]; then
    echo "New device(s) since the last digest: $((n_new + n_seen))"
    [ -n "$seen" ] && printf '%s\n' "$seen"
    printf '%s' "$new"
    # The alert names the devices: if this digest cannot be sent, the alert is
    # repeated in the next one, while this section will no longer list them.
    # Devices already announced by e-mail are listed, not alerted again.
    [ "$n_new" -gt 0 ] && add_alert "Network: $n_new new device(s) on the LAN: $names"
    if [ -z "$DM_PREVIEW" ]; then
        [ "$n_new" -gt 0 ] && printf '%s' "$new" | awk '{print $1}' >> "$known"
        rm -f "$alerted"
    fi
else
    echo "No new device ($n_now leased now)"
fi
exit 0

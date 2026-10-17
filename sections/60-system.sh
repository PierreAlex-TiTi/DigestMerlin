#!/bin/sh
# TITLE: SYSTEM
. "$(dirname "$0")/lib.sh"

DISK_ALERT_PCT="${DISK_ALERT_PCT:-90}"
REBOOT_MAX_DAYS="${REBOOT_MAX_DAYS:-}"   # empty = no reboot check
CPU_TEMP_ALERT="${CPU_TEMP_ALERT:-}"     # empty = no temperature alert

# --- Firmware, and whether it changed since the last digest
fw="$(nv firmver | tr -d '.').$(nv buildno)_$(nv extendno)"
echo "Firmware: $fw ($(nv productid))"
prev=$(state_get firmware)
case "$fw" in
    [0-9]*.[0-9]*_?*)   # a real version, e.g. 3006.102.9_0 (not "3006.102.9_")
        if [ -n "$prev" ] && [ "$prev" != "$fw" ]; then
            add_alert "System: firmware changed from $prev to $fw"
        fi
        state_set firmware "$fw" ;;
    *)  ;;              # nvram did not answer: no comparison, nothing saved
esac

# MerlinAU (optional): a new firmware waiting for its postponement period.
mau="/jffs/addons/MerlinAU.d/custom_settings.txt"
if [ -f "$mau" ]; then
    v=$(sed -n 's/^FW_New_Update_Notification_Vers //p' "$mau" | head -1)
    # MerlinAU writes versions as 3006.102.9.0, the firmware as 3006.102.9_0.
    if [ -n "$v" ] && [ "$v" != "TBD" ] && [ "$v" != "$(echo "$fw" | tr '_' '.')" ]; then
        echo "MerlinAU: update $v pending (found $(sed -n 's/^FW_New_Update_Notification_Date //p' "$mau" | head -1 | tr '_' ' '))"
    else
        echo "MerlinAU: no pending update"
    fi
fi

# --- Uptime and last boot
up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
if is_number "$up"; then
    echo "Last boot: $(fmt_time $((NOW - up))) (up $(fmt_age "$up"))"
    if is_number "$REBOOT_MAX_DAYS" && [ "$up" -gt $((REBOOT_MAX_DAYS * 86400)) ]; then
        add_alert "System: no reboot for $(fmt_age "$up") (expected at least every $REBOOT_MAX_DAYS days)"
    fi
fi

# --- Load, memory, temperature
load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
mt=$(awk '/^MemTotal/ {print $2}' /proc/meminfo)
ma=$(awk '/^MemAvailable/ {print $2}' /proc/meminfo)
st=$(awk '/^SwapTotal/ {print $2}' /proc/meminfo)
sf=$(awk '/^SwapFree/ {print $2}' /proc/meminfo)
mem="?"
is_number "$mt" && is_number "$ma" && [ "$mt" -gt 0 ] && mem="$(((mt - ma) * 100 / mt))%"
swap=""
is_number "$st" && [ "$st" -gt 0 ] && swap=" | swap $(((st - sf) / 1024)) MB used"
temp=""
raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
is_number "$raw" && [ "$raw" -gt 1000 ] && temp=" | CPU $((raw / 1000))C"
echo "Load: ${load:-?} | memory ${mem} used${swap}${temp}"
if [ -n "$temp" ] && is_number "$CPU_TEMP_ALERT" && [ $((raw / 1000)) -ge "$CPU_TEMP_ALERT" ]; then
    add_alert "System: CPU at $((raw / 1000))C (alert set at ${CPU_TEMP_ALERT}C)"
fi

# --- Storage
for mp in /jffs /opt; do
    [ -d "$mp" ] || continue
    pct=$(df -P "$mp" 2>/dev/null | awk 'NR == 2 {sub(/%/, "", $5); print $5}')
    is_number "$pct" || continue
    label=$mp; [ "$mp" = "/opt" ] && label="Entware (USB)"
    echo "Storage $label: ${pct}% used"
    [ "$pct" -ge "$DISK_ALERT_PCT" ] && add_alert "System: $label is ${pct}% full"
done

# --- Files writable by anyone. A writable SCRIPT is dangerous (it runs as root):
# alert. Writable DATA files (results, lists) are common - some add-ons create
# them that way - so they are only reported, grouped by add-on.
FIND=""
[ -x /opt/bin/find ] && FIND=/opt/bin/find   # BusyBox find may lack -perm
if [ -n "$FIND" ]; then
    tmp="/tmp/digestmerlin-ww.$$"
    {
        "$FIND" /jffs/scripts -perm -o+w ! -type l 2>/dev/null
        "$FIND" /jffs/addons /jffs/configs -perm -o+w -type f \( -perm -u+x -o -name '*.sh' \) 2>/dev/null
        # amtm loads (runs) its own files as root: modules (.mod), settings, email.conf...
        "$FIND" /jffs/addons/amtm -perm -o+w -type f 2>/dev/null
    } | sort -u > "$tmp.scripts"
    "$FIND" /jffs/addons /jffs/configs -perm -o+w ! -type l 2>/dev/null \
        | awk -v f="$tmp.scripts" 'BEGIN {while ((getline l < f) > 0) s[l]} !($0 in s)' > "$tmp.data"
    n_s=$(grep -c . "$tmp.scripts")
    n_d=$(grep -c . "$tmp.data")
    if [ "$n_s" -gt 0 ]; then
        echo "Scripts writable by anyone: $n_s"
        add_alert "System: $n_s script(s) writable by anyone - they run as root (e.g. $(head -1 "$tmp.scripts")) - fix with chmod o-w"
    else
        echo "Scripts writable by anyone: 0"
    fi
    if [ "$n_d" -gt 0 ]; then
        # Group by add-on: /jffs/addons/spdmerlin.d/... -> spdmerlin
        who=$(awk '{p = $0; sub(/^\/jffs\/(addons|configs)\/?/, "", p); split(p, a, "/");
                    o = a[1]; sub(/\.d$/, "", o); if (o == "") o = "configs"; c[o]++}
                   END {for (o in c) printf "%s%s %d", (n++ ? ", " : ""), o, c[o]}' "$tmp.data")
        echo "Data files writable by anyone: $n_d ($who)"
    fi
    rm -f "$tmp.scripts" "$tmp.data"
fi
exit 0

#!/bin/sh
# TITLE: SYSTEM
. "$(dirname "$0")/lib.sh"

DISK_ALERT_PCT="${DISK_ALERT_PCT:-90}"
REBOOT_MAX_DAYS="${REBOOT_MAX_DAYS:-}"   # empty = no reboot check
CPU_TEMP_ALERT="${CPU_TEMP_ALERT:-}"     # empty = no temperature alert
WAN_PLANNED="${WAN_PLANNED:-}"           # e.g. "Sun 03:00-03:10": planned WAN drops, no alert

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
up=$(cut -d. -f1 "${PROC_UPTIME:-/proc/uptime}" 2>/dev/null)   # PROC_UPTIME: tests only
if is_number "$up"; then
    echo "Last boot: $(fmt_time $((NOW - up))) (up $(fmt_age "$up"))"
    if is_number "$REBOOT_MAX_DAYS" && [ "$up" -gt $((REBOOT_MAX_DAYS * 86400)) ]; then
        add_alert "System: no reboot for $(fmt_age "$up") (expected at least every $REBOOT_MAX_DAYS days)"
    fi
fi

# --- WAN link drops: the firmware logs "WAN_Connection: WAN(0) link down." and
# "... link up." when the link to the modem/ONT goes down and comes back.
# After a reboot, lines written before the clock is set are dated 1 Jan 1970
# ("Jan  1" east of UTC, "Dec 31" west of it): they belong to the boot itself,
# which is shown above, and are skipped.
boot=""; is_number "$up" && boot=$((NOW - up))
# Planned window (e.g. a weekly modem reboot): drops that START in it are shown
# apart and raise no alert; they are not counted in the 7-day total either.
# "Sun 03:00-03:10" or "daily 04:00-04:15", router local time; a window may
# cross midnight. An invalid value is ignored (the main script reports it).
pw_day=""; pw_s=""; pw_e=""
if echo "$WAN_PLANNED" | grep -E -i -q '^(mon|tue|wed|thu|fri|sat|sun|daily) ([01][0-9]|2[0-3]):[0-5][0-9]-([01][0-9]|2[0-3]):[0-5][0-9]$'; then
    case $(echo "${WAN_PLANNED%% *}" | tr 'A-Z' 'a-z') in
        daily) pw_day=0 ;; mon) pw_day=1 ;; tue) pw_day=2 ;; wed) pw_day=3 ;;
        thu) pw_day=4 ;; fri) pw_day=5 ;; sat) pw_day=6 ;; sun) pw_day=7 ;;
    esac
    r=${WAN_PLANNED#* }; a=${r%-*}; b=${r#*-}
    pw_s=$(( ${a%:*} * 60 + ${a#*:} )); pw_e=$(( ${b%:*} * 60 + ${b#*:} ))
fi
# 0 if the epoch $1 falls in the planned window.
in_planned() {
    [ -n "$pw_s" ] || return 1
    set -- $(date -d "@$1" '+%u %H %M' 2>/dev/null)
    [ $# -eq 3 ] || return 1
    _m=$(( ${2#0} * 60 + ${3#0} )); _d=$1; _p=$(( _d == 1 ? 7 : _d - 1 ))   # _p: the day before
    if [ "$pw_s" -le "$pw_e" ]; then
        [ "$_m" -ge "$pw_s" ] && [ "$_m" -le "$pw_e" ] && { [ "$pw_day" = 0 ] || [ "$pw_day" = "$_d" ]; }
    else    # crosses midnight: the part after midnight belongs to the day before
        { [ "$_m" -ge "$pw_s" ] && { [ "$pw_day" = 0 ] || [ "$pw_day" = "$_d" ]; }; } \
            || { [ "$_m" -le "$pw_e" ] && { [ "$pw_day" = 0 ] || [ "$pw_day" = "$_p" ]; }; }
    fi
}
drops=0; last=""; longest=""; open_n=""
planned=0; plast=""; plongest=""; popen_n=""
for n in 0 1; do eval "down_$n= plan_$n="; done
wtmp="/tmp/digestmerlin-wan.$$"
read_logs | grep -E 'WAN_Connection: WAN\([01]\) link (down|up)\.' > "$wtmp"
while IFS= read -r line; do
    set -f; set -- $line; set +f
    ts=$(pdate "%b %e %H:%M:%S" "$1 $2 $3") || continue
    if [ "$ts" -gt $((NOW + 86400)) ]; then
        ts=$(pdate "%Y %b %e %H:%M:%S" "$(($(date +%Y) - 1)) $1 $2 $3") || continue
    fi
    # Pre-clock line: dated before the boot, and read as 1970 it falls within
    # the first hour after the clock started (a real event of that day keeps
    # its place unless it happened in that same hour before a same-day reboot).
    # Known limit: after a reboot in the first hour of Jan 1, a pre-clock line
    # cannot be told from a real one (one false drop, once a year at most).
    case "$1 $2" in
        "Jan 1"|"Dec 31")
            y=1970; [ "$1" = "Dec" ] && y=1969
            e=$(pdate "%Y %b %e %H:%M:%S" "$y $1 $2 $3")
            if [ -n "$boot" ] && [ "$ts" -lt "$boot" ] && [ -n "$e" ] && [ "$e" -ge 0 ] 2>/dev/null && [ "$e" -le 3600 ]; then
                continue
            fi ;;
    esac
    # Every drop of the last 7 days is remembered (the logs may not go back that far next time).
    case "$line" in *"link down."*) [ "$ts" -gt $((NOW - 7 * 86400)) ] && [ "$ts" -le "$NOW" ] && echo "$ts" >> "$wtmp.week" ;; esac
    [ "$ts" -ge "$SINCE" ] && [ "$ts" -le "$NOW" ] || continue
    case "$line" in *"WAN(1)"*) n=1 ;; *) n=0 ;; esac
    case "$line" in
        *"link down."*)
            if in_planned "$ts"; then
                planned=$((planned + 1)); plast=$ts; eval "plan_$n=1"
            else
                drops=$((drops + 1)); last=$ts; eval "plan_$n="
            fi
            eval "down_$n=\$ts" ;;
        *"link up."*)
            eval "d=\$down_$n; pl=\$plan_$n"
            if [ -n "$d" ]; then
                dur=$((ts - d))
                if [ -n "$pl" ]; then
                    { [ -z "$plongest" ] || [ "$dur" -gt "$plongest" ]; } && plongest=$dur
                else
                    { [ -z "$longest" ] || [ "$dur" -gt "$longest" ]; } && longest=$dur
                fi
                eval "down_$n= plan_$n="
            fi ;;
    esac
done < "$wtmp"
rm -f "$wtmp"
# Drops of the last 7 days: those of earlier digests (state) + those in the logs now.
whist="$DM_STATE/wan_drops.hist"
{ cat "$whist" 2>/dev/null; cat "$wtmp.week" 2>/dev/null; } \
    | awk -v cut=$((NOW - 7 * 86400)) -v now="$NOW" '/^[0-9]+$/ && $1 > cut && $1 <= now && !s[$1]++' | sort -n > "$wtmp.all"
# Drops in the planned window are kept in the history but never counted, also
# those recorded before the window was set (or when it changes).
n7=$(while read -r t; do in_planned "$t" || echo "$t"; done < "$wtmp.all" | grep -c .)
if [ -z "$DM_PREVIEW" ]; then
    # shellcheck disable=SC2174
    mkdir -p -m 700 "$DM_STATE" 2>/dev/null && cp "$wtmp.all" "$whist.new" 2>/dev/null && mv "$whist.new" "$whist" 2>/dev/null
fi
rm -f "$wtmp.week" "$wtmp.all"
# The 7-day count is only shown when drops keep coming back.
week=""; [ "$n7" -ge 2 ] && week=" | 7 days: $n7"
# A drop with no "link up" after it (yet) - an alert even in the planned window.
for n in 0 1; do
    eval "d=\$down_$n; pl=\$plan_$n"
    [ -n "$d" ] || continue
    if [ -n "$pl" ]; then popen_n="${popen_n:+$popen_n, }WAN($n)"; else open_n="${open_n:+$open_n, }WAN($n)"; fi
done
fmt_dur() { if [ "$1" -lt 60 ]; then echo "${1}s"; else fmt_age "$1"; fi; }
pinfo=""
if [ "$planned" -gt 0 ]; then
    pinfo="last $(fmt_time "$plast")"
    [ -n "$plongest" ] && pinfo="$pinfo, longest $(fmt_dur "$plongest")"
    [ -n "$popen_n" ] && pinfo="$pinfo, $popen_n not back up in the log"
    pinfo=" | planned ($WAN_PLANNED): $planned ($pinfo)"
fi
if [ "$drops" -eq 0 ]; then
    echo "WAN link drops (24h): 0$pinfo$week"
else
    info="last $(fmt_time "$last")"
    [ -n "$longest" ] && info="$info, longest $(fmt_dur "$longest")"
    [ -n "$open_n" ] && info="$info, $open_n not back up in the log"
    echo "WAN link drops (24h): $drops ($info)$pinfo$week"
    t="times"; [ "$drops" -eq 1 ] && t="time"
    add_alert "System: WAN link dropped $drops $t in 24h ($info)"
fi
[ -n "$popen_n" ] && add_alert "System: $popen_n not back up after a drop in the planned window ($WAN_PLANNED)"

# --- An nvram command stuck right now. On some firmware builds an nvram read
# sometimes never returns; the add-on that called it then hangs too (spdMerlin,
# Skynet...). Only reported, never stopped: DigestMerlin changes nothing.
# Process name "nvram", running for more than 2 minutes (a normal read takes
# well under a second). NVRAM_COMM / NVRAM_STUCK_S: tests only.
if is_number "$up"; then
    awk -v comm="(${NVRAM_COMM:-nvram})" -v up="$up" -v min="${NVRAM_STUCK_S:-120}" '
        $2 == comm { s = $0; sub(/.*\) /, "", s); split(s, a, " ")
                     age = up - int(a[20] / 100); if (age >= min) print $1, age, a[2] }' \
        /proc/[0-9]*/stat 2>/dev/null | sort -k2,2nr | head -3 | while read -r pid age ppid; do
        cmd=$( { tr '\0' ' ' < "/proc/$pid/cmdline"; } 2>/dev/null | cut -c1-60); cmd=${cmd% }
        by=$( { tr '\0' ' ' < "/proc/$ppid/cmdline"; } 2>/dev/null | cut -c1-80); by=${by% }
        echo "nvram: '${cmd:-nvram}' stuck for $(fmt_age "$age") (called by: ${by:-unknown})"
        add_alert "System: '${cmd:-nvram}' has been stuck for $(fmt_age "$age") (called by: ${by:-unknown}) - add-ons using nvram may hang too"
    done
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

# --- HTTPS certificate of the web interface (the one in use is /etc/cert.pem,
# whether the router made it, Let's Encrypt renewed it or you imported yours).
# Shown when the web interface uses HTTPS; alert 30 days before it expires.
CERT="${CERT_FILE:-/etc/cert.pem}"     # CERT_FILE: tests only
if [ "$(nv http_enable)" != "0" ] && [ -s "$CERT" ] && command -v openssl >/dev/null 2>&1; then
    end=$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')
    if [ -n "$end" ]; then
        # "Oct 24 13:17:35 2028 GMT" -> seconds (read in UTC)
        set -f; set -- $end; set +f
        e=$( TZ=UTC; export TZ; pdate "%b %d %H:%M:%S %Y" "$1 $2 $3 $4" )
        if is_number "$e"; then
            d=$(( (e - NOW) / 86400 ))
            if [ "$e" -le "$NOW" ]; then
                echo "HTTPS certificate: EXPIRED on $(date -d "@$e" '+%d %b %Y')"
                add_alert "System: the router's HTTPS certificate expired on $(date -d "@$e" '+%d %b %Y') - browsers will refuse or warn"
            else
                echo "HTTPS certificate: valid until $(date -d "@$e" '+%d %b %Y') ($d days)"
                [ "$d" -lt 30 ] && add_alert "System: the router's HTTPS certificate expires in $d day(s) ($(date -d "@$e" '+%d %b %Y'))"
            fi
        else
            echo "HTTPS certificate: valid until $end"
            openssl x509 -in "$CERT" -noout -checkend 2592000 >/dev/null 2>&1 \
                || add_alert "System: the router's HTTPS certificate expires within 30 days ($end)"
        fi
    fi
fi

# --- Files writable by anyone. A writable SCRIPT is dangerous (it runs as root):
# alert. Writable DATA files (results, lists) are common - some add-ons create
# them that way - so they are only reported, grouped by add-on. amtm's own files
# are only reported too: amtm re-creates them with the shell's umask on each
# update, and its author considers it harmless on a single-user router.
FIND=""
[ -x /opt/bin/find ] && FIND=/opt/bin/find   # BusyBox find may lack -perm
if [ -n "$FIND" ]; then
    tmp="/tmp/digestmerlin-ww.$$"
    # In /jffs/scripts, a script is what can run: a folder (anyone could drop a
    # script in it), an executable, a .sh file or a file starting with "#!".
    # Anything else there (a log, a list, a state file) is data.
    : > "$tmp.sdata"
    "$FIND" /jffs/scripts -perm -o+w ! -type l 2>/dev/null | while IFS= read -r f; do
        first=""; [ -f "$f" ] && IFS= read -r first < "$f" 2>/dev/null
        case "$f" in *.sh) first="#!" ;; esac
        if [ -d "$f" ] || [ -x "$f" ] || case "$first" in '#!'*) true ;; *) false ;; esac; then
            echo "$f"
        else
            echo "$f" >> "$tmp.sdata"
        fi
    done > "$tmp.s1"
    {
        cat "$tmp.s1"
        "$FIND" /jffs/addons /jffs/configs -perm -o+w -type f \( -perm -u+x -o -name '*.sh' \) 2>/dev/null
    } | grep -v '^/jffs/addons/amtm\(/\|$\)' | sort -u > "$tmp.scripts"
    "$FIND" /jffs/addons/amtm -perm -o+w -type f 2>/dev/null > "$tmp.amtm"
    "$FIND" /jffs/addons /jffs/configs -perm -o+w ! -type l 2>/dev/null | grep -v '^/jffs/addons/amtm\(/\|$\)' \
        | awk -v f="$tmp.scripts" 'BEGIN {while ((getline l < f) > 0) s[l]} !($0 in s)' > "$tmp.data"
    cat "$tmp.sdata" >> "$tmp.data"
    n_s=$(grep -c . "$tmp.scripts")
    n_a=$(grep -c . "$tmp.amtm")
    n_d=$(grep -c . "$tmp.data")
    echo "Scripts writable by anyone: $n_s"
    if [ "$n_s" -gt 0 ]; then
        add_alert "System: $n_s script(s) writable by anyone - they run as root (e.g. $(head -1 "$tmp.scripts")) - fix with chmod o-w"
    fi
    if [ "$n_d" -gt 0 ]; then
        # Group by add-on: /jffs/addons/spdmerlin.d/... -> spdmerlin
        who=$(awk '{p = $0; if (p ~ /^\/jffs\/scripts\//) {c["/jffs/scripts"]++; next}
                    sub(/^\/jffs\/(addons|configs)\/?/, "", p); split(p, a, "/");
                    o = a[1]; sub(/\.d$/, "", o); if (o == "") o = "configs"; c[o]++}
                   END {for (o in c) printf "%s%s %d", (n++ ? ", " : ""), o, c[o]}' "$tmp.data")
        echo "Data files writable by anyone: $n_d ($who)"
    fi
    [ "$n_a" -gt 0 ] && echo "amtm files writable by anyone: $n_a (amtm re-creates them on update)"
    rm -f "$tmp.scripts" "$tmp.amtm" "$tmp.data" "$tmp.sdata" "$tmp.s1"
else
    echo "Scripts writable by anyone: not checked (needs Entware's find: opkg install findutils)"
fi
exit 0

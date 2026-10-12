#!/bin/sh
# TITLE: BACKUPS (BACKUPMON)
. "$(dirname "$0")/lib.sh"

BACKUP_MAX_AGE_H="${BACKUP_MAX_AGE_H:-26}"
LOG="/jffs/addons/backupmon.d/backupmon.log"
[ -f /jffs/scripts/backupmon.sh ] || exit 3

if [ ! -f "$LOG" ]; then
    echo "No BACKUPMON log yet"
    add_alert "BACKUPMON: installed but no log found - has a backup ever run?"
    exit 0
fi

# "Oct 12 2026 04:00:15 host BACKUPMON[pid] - INFO: Finished backing up NVRAM to ..."
log_ts() {
    set -f; set -- $1; set +f
    date -D "%b %d %Y %H:%M:%S" -d "$1 $2 $3 $4" +%s 2>/dev/null
}

for what in NVRAM JFFS "EXT Drive"; do
    l=$(grep "INFO: Finished backing up $what" "$LOG" | tail -1)
    [ -n "$l" ] || continue
    t=$(log_ts "$l")
    is_number "$t" || continue
    age=$((NOW - t))
    echo "Last $what backup: $(fmt_time "$t") ($(fmt_age "$age") ago)"
    if [ "$what" = "NVRAM" ] && [ "$age" -gt $((BACKUP_MAX_AGE_H * 3600)) ]; then
        add_alert "BACKUPMON: last NVRAM backup is $(fmt_age "$age") old"
    fi
done
grep -q "INFO: Finished backing up NVRAM" "$LOG" || add_alert "BACKUPMON: no completed NVRAM backup in its log"

errs=$(tail -500 "$LOG" | grep " - ERROR: " | while IFS= read -r l; do
    t=$(log_ts "$l")
    is_number "$t" && [ "$t" -ge "$SINCE" ] && [ "$t" -le "$NOW" ] && printf '%s\n' "$l"
done)
if [ -n "$errs" ]; then
    n=$(printf '%s\n' "$errs" | wc -l)
    echo "Errors (${WINDOW_H}h): $n"
    add_alert "BACKUPMON: $n error(s) in ${WINDOW_H}h - last: $(printf '%s\n' "$errs" | tail -1 | sed 's/.* - ERROR: //')"
else
    echo "Errors (${WINDOW_H}h): 0"
fi
exit 0

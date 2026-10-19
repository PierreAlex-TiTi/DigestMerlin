#!/bin/sh
# shellcheck disable=SC2034
version=0.3.0
VERSION="0.3.0"
# Both lines above carry the same release number (a test build adds "-testN"
# to the second only): amtm reads the first, menus of v0.2.0 read the second. Keep them on top, before any other mention.
#
# DigestMerlin - one daily e-mail summarising the health of an Asuswrt-Merlin
# router and its add-ons (Skynet, WireGuard/VPNMON-R3, spdMerlin, BACKUPMON...).
# Read-only: it reports, it never changes the router's configuration.
#
#   digestmerlin.sh                  open the menu
#   digestmerlin.sh preview          build the digest and print it (no e-mail)
#   digestmerlin.sh run              build the digest and e-mail it
#   digestmerlin.sh section NAME     run one section (e.g. "vpn") for testing
#   digestmerlin.sh install [HH:MM]  schedule the daily e-mail (default 18:30)
#   digestmerlin.sh unschedule       stop the daily e-mail (files are kept)
#   digestmerlin.sh setup            download and install all files (first install)
#   digestmerlin.sh update           update to the latest version (settings are kept)
#   digestmerlin.sh uninstall        remove DigestMerlin completely
#
# Each section is a small script in sections/ (NN-name.sh). Sections whose
# tool is not installed are skipped. A failing or hanging section never stops
# the e-mail: it is reported as unavailable.

REPO="${DM_REPO:-https://raw.githubusercontent.com/PierreAlex-TiTi/DigestMerlin/main}"
SECTION_FILES="lib.sh 10-skynet.sh 20-vpn.sh 30-speedtest.sh 40-backupmon.sh 50-devices.sh 60-system.sh"
SCRIPT_PATH="/jffs/scripts/digestmerlin.sh"
DM_DIR="${DM_DIR:-/jffs/addons/digestmerlin.d}"
SECTIONS_DIR="${SECTIONS_DIR:-$DM_DIR/sections}"
DM_CONF="${DM_CONF:-$DM_DIR/digestmerlin.conf}"
DM_STATE="${DM_STATE:-$DM_DIR/state}"
# E-mail: through Martinski's SendEmail add-on (amtm option "se"), which keeps
# the Custom Email Library up to date. If SendEmail is missing but the library
# is already there (installed by another add-on), it is used directly.
SENDEMAIL="${SENDEMAIL:-/jffs/scripts/SendEmail}"
SENDEMAIL_SCRIPT="${SENDEMAIL_SCRIPT:-/jffs/addons/SendEmail.d/SendEmail.sh}"
CEM_LIB="${CEM_LIB:-/jffs/addons/shared-libs/CustomEMailFunctions.lib.sh}"
AMTM_MAIL_DIR="${AMTM_MAIL_DIR:-/jffs/addons/amtm/mail}"
CRU_ID="DigestMerlin"
LOGTAG="DigestMerlin"
SECTION_TIMEOUT="${SECTION_TIMEOUT:-120}"
RETRY_WAIT="${RETRY_WAIT:-60}"

DISABLED_SECTIONS=""
SUBJECT_PREFIX=""
# A settings file with a syntax error (e.g. a missing quote after a hand edit)
# must never stop the e-mail, the update or the uninstall: defaults are used
# and the digest says so.
CONF_BROKEN=""
load_conf() {
    [ -f "$DM_CONF" ] || return 0
    # Syntax checked first, then loaded once in a subshell: an error that only
    # shows when the file runs (e.g. ${X:?}) cannot stop this script either.
    # shellcheck disable=SC1090
    if sh -n "$DM_CONF" 2>/dev/null && ( . "$DM_CONF" ) >/dev/null 2>&1; then
        # shellcheck disable=SC1090
        . "$DM_CONF"
        CONF_BROKEN=""
    else
        CONF_BROKEN=1
    fi
}
load_conf
export DM_DIR DM_CONF DM_STATE

umask 022   # Merlin shells may run with umask 000: never create world-writable files

say() { printf '%s\n' "$*"; }
log() { logger -t "$LOGTAG" "$*"; }

# Child processes of $1, read from /proc (no pgrep/pkill needed).
child_pids() {
    parent=$1
    for st in /proc/[0-9]*/stat; do
        read -r line < "$st" 2>/dev/null || continue
        rest=${line##*) }                       # fields after "pid (name) "
        # shellcheck disable=SC2086
        set -- $rest                            # $1 = state, $2 = parent pid
        [ "$2" = "$parent" ] && { d=${st#/proc/}; echo "${d%/stat}"; }
    done
}

# Signal $1 and all its descendants: a hung nvram, wg or sqlite3 started by a
# section must not outlive it.
kill_tree() {
    for c in $(child_pids "$1"); do kill_tree "$c" "$2"; done
    kill -"$2" "$1" 2>/dev/null
}

section_name() {   # 20-vpn.sh -> vpn
    n=$(basename "$1" .sh)
    echo "${n#[0-9][0-9]-}"
}

build_digest() {
    NOW=$(date +%s)
    WINDOW_H=24
    SINCE=$((NOW - WINDOW_H * 3600))
    WORK="/tmp/digestmerlin.$$"
    rm -rf "$WORK"; mkdir -m 700 "$WORK" || return 1
    DM_ALERTS="$WORK/alerts"
    : > "$DM_ALERTS"
    export NOW WINDOW_H SINCE DM_ALERTS
    trap 'rm -rf "$WORK"' EXIT
    trap 'rm -rf "$WORK"; exit 1' INT TERM

    out="$WORK/sections"; : > "$out"
    n_ok=0; n_bad=0; skipped=""
    for mod in "$SECTIONS_DIR"/[0-9][0-9]-*.sh; do
        [ -f "$mod" ] || continue
        name=$(section_name "$mod")
        case " $DISABLED_SECTIONS " in *" $name "*) continue ;; esac
        title=$(sed -n '2s/^# TITLE: *//p' "$mod")
        title=${title:-$name}

        sh "$mod" > "$WORK/out" 2> "$WORK/err" &
        pid=$!
        w=0
        while kill -0 "$pid" 2>/dev/null && [ "$w" -lt "$SECTION_TIMEOUT" ]; do
            sleep 1; w=$((w + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill_tree "$pid" TERM; sleep 1; kill_tree "$pid" KILL
            wait "$pid" 2>/dev/null
            body="Section unavailable (no answer after ${SECTION_TIMEOUT}s)"
            printf -- '- %s: section stopped after %ss\n' "$title" "$SECTION_TIMEOUT" >> "$DM_ALERTS"
            n_bad=$((n_bad + 1))
        else
            wait "$pid"; rc=$?
            if [ "$rc" -eq 3 ]; then
                skipped="$skipped $name"
                continue
            fi
            body=$(cat "$WORK/out")
            if [ "$rc" -ne 0 ] || [ -z "$body" ]; then
                err=$(tail -1 "$WORK/err")
                body="Section unavailable (error $rc)"
                printf -- '- %s: section failed (code %s)%s\n' "$title" "$rc" "${err:+ - $err}" >> "$DM_ALERTS"
                n_bad=$((n_bad + 1))
            else
                n_ok=$((n_ok + 1))
            fi
        fi
        printf '=== %s ===\n%s\n\n' "$title" "$body" >> "$out"
    done

    host=$(nvram get productid 2>/dev/null)
    if [ "$n_ok" -eq 0 ] && [ "$n_bad" -eq 0 ]; then
        if [ -n "$(ls "$SECTIONS_DIR"/[0-9][0-9]-*.sh 2>/dev/null)" ]; then
            printf -- '- No section ran: all sections are disabled or not applicable (menu option 4)\n' >> "$DM_ALERTS"
        else
            printf -- '- No section found in %s - reinstall with: sh %s update\n' "$SECTIONS_DIR" "$SCRIPT_PATH" >> "$DM_ALERTS"
        fi
    fi
    if ! date -D "%Y" -d "2000" +%Y >/dev/null 2>&1 && ! busybox date -D "%Y" -d "2000" +%Y >/dev/null 2>&1 \
        && ! /bin/date -D "%Y" -d "2000" +%Y >/dev/null 2>&1; then
        printf -- '- Cannot read syslog dates on this router (no BusyBox date) - 24h counters are not reliable\n' >> "$DM_ALERTS"
    fi
    if [ -n "$CONF_BROKEN" ]; then
        printf -- '- Settings file %s has a syntax error - default settings were used\n' "$DM_CONF" >> "$DM_ALERTS"
    fi
    if [ -f "$DM_STATE/unsent" ]; then
        printf -- '- The previous digest could not be e-mailed - check the e-mail settings in amtm (em, se)\n' >> "$DM_ALERTS"
        # Its alerts were never seen: repeat them (the state has already moved on).
        # Each keeps the date of the digest it first appeared in; alerts already
        # reported today are not repeated, and none is listed twice.
        when=$(head -1 "$DM_STATE/unsent" | sed -n 's/.* - \([0-9-]*\)$/\1/p')
        awk -v when="${when:-?}" -v cur="$DM_ALERTS" '
            BEGIN { while ((getline l < cur) > 0) { sub(/^- /, "", l); seen[l] = 1 } }
            /^=== ALERTS ===$/ {a = 1; next}
            a && /^$/ {exit}
            a && /^- / {
                t = substr($0, 3); d = when
                if (t ~ /^\(not sent on [0-9-]+\) /) { d = substr(t, 14); sub(/\).*/, "", d); sub(/^\(not sent on [0-9-]+\) /, "", t) }
                if (t ~ /previous digest could not be e-mailed/ || (t in seen)) next
                seen[t] = 1; print "- (not sent on " d ") " t
            }' "$DM_STATE/unsent" > "$DM_ALERTS.carry"
        cat "$DM_ALERTS.carry" >> "$DM_ALERTS"; rm -f "$DM_ALERTS.carry"
    fi
    if [ -s "$DM_ALERTS" ]; then
        tag="ATTENTION"; summary="$(grep -c . "$DM_ALERTS") point(s) need attention - see ALERTS."
    else
        tag="OK"; summary="All green."
    fi
    SUBJECT="${SUBJECT_PREFIX:+${SUBJECT_PREFIX% } }[$tag] Daily digest ${host:-router} - $(date '+%Y-%m-%d')"
    BODY="=== SUMMARY ===
$summary

$(cat "$out")

=== ALERTS ===
$( [ -s "$DM_ALERTS" ] && cat "$DM_ALERTS" || echo "None")

Generated $(date '+%Y-%m-%d %H:%M') - covers the last ${WINDOW_H}h
Sections: $n_ok OK$( [ "$n_bad" -gt 0 ] && echo ", $n_bad unavailable")${skipped:+ | not installed:$skipped}
DigestMerlin v$VERSION"
    return 0
}

# How the digest will be e-mailed: SendEmail, library, or none (also "none"
# when amtm's e-mail settings, option "em", were never saved).
mail_method() {
    if [ ! -s "$AMTM_MAIL_DIR/email.conf" ] || [ ! -s "$AMTM_MAIL_DIR/emailpw.enc" ]; then echo none
    elif [ -s "$SENDEMAIL_SCRIPT" ] && [ -x "$SENDEMAIL" ]; then echo SendEmail
    elif [ -f "$CEM_LIB" ]; then echo library
    else echo none
    fi
}

# One sending attempt of $subject / $mailbody. Returns the sender's code.
send_once() {
    case "$method" in
        SendEmail)
            bodyf="/tmp/digestmerlin-mail.$$"
            printf '%s\n' "$mailbody" > "$bodyf" && chmod 600 "$bodyf"
            # SendEmail puts each argument inside '...' and evaluates the list again:
            # an apostrophe would break it. A leading "-" or "Word=" would be taken as an option.
            # </dev/null: SendEmail never waits for a key, even from a terminal.
            sesubj=$(printf '%s' "$subject" | sed "s/'/’/g; s/^-*//; s/^\([A-Za-z]*\)=/\1 =/")
            "$SENDEMAIL" -html -quiet -From="DigestMerlin" "$sesubj" -Body="$bodyf" </dev/null >/dev/null 2>&1; r=$?
            rm -f "$bodyf"
            return "$r" ;;
        library)
            _SendEMailNotification_CEM_ "$subject" "$mailbody" ;;
        *)  return 1 ;;
    esac
}

send_digest() {
    method=$(mail_method)
    case "$method" in
        none)
            # Not returned straight away: the digest is kept as unsent below, so
            # its alerts reach the next e-mail once e-mail is set up again.
            log "ERROR: no way to send e-mail - set up e-mail in amtm (em) and install SendEmail (amtm, se)"
            say "ERROR: e-mail is not set up - in amtm: 'em' (e-mail settings), then 'se' (SendEmail)." >&2 ;;
        library)
            # shellcheck disable=SC1090
            . "$CEM_LIB"
            # shellcheck disable=SC2034
            cemScriptFNameTag="$LOGTAG" ;;
    esac
    # The digest is sent as HTML, with the text inside <pre> as is. Escape &,
    # < and >: an unescaped "<1m ago" can hide the rest of the digest in strict
    # mail clients (Outlook renders HTML with Word).
    subject="$SUBJECT"
    [ -n "$DM_TEST" ] && subject="[TEST] $SUBJECT"    # tell a test from the daily e-mail
    mailbody=$(printf '%s\n' "$BODY" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    try=1; rc=0; tries="${SEND_TRIES:-3}"
    [ "$method" = none ] && { tries=0; rc=1; }
    while [ "$try" -le "$tries" ]; do
        send_once; rc=$?
        if [ "$rc" -eq 0 ]; then
            if [ -n "$DM_TEST" ]; then
                log "Test digest sent ($tag)"
                save_last_run "$tag" sent
            else
                log "Daily digest sent ($tag, via $method)"
                rm -f "$DM_STATE/unsent"
                save_last_run "$tag" sent
            fi
            return 0
        fi
        log "Sending failed (attempt $try/$tries, code $rc)"
        [ "$try" -lt "$tries" ] && sleep "$RETRY_WAIT"
        try=$((try + 1))
    done
    if [ -n "$DM_TEST" ]; then
        save_last_run "$tag" "NOT sent"
        log "ERROR: test digest not sent (code $rc)"
        return 1
    fi
    # shellcheck disable=SC2174
    mkdir -p -m 700 "$DM_STATE"
    printf '%s\n\n%s\n' "$SUBJECT" "$BODY" > "$DM_STATE/unsent"
    chmod 600 "$DM_STATE/unsent"
    save_last_run "$tag" "NOT sent"
    if [ "$method" = none ]; then
        log "ERROR: digest not sent (e-mail not set up) - kept in $DM_STATE/unsent"
    else
        log "ERROR: digest not sent after $tries attempt(s) (code $rc) - kept in $DM_STATE/unsent"
    fi
    return 1
}

# Shown in the menu header: "epoch|OK|sent"
save_last_run() {
    f=last_run; [ -n "$DM_TEST" ] && f=last_test     # a test never hides the last real digest
    # shellcheck disable=SC2174
    mkdir -p -m 700 "$DM_STATE" && printf '%s|%s|%s\n' "$(date +%s)" "$1" "$2" > "$DM_STATE/$f"
}

do_install() {
    t="${1:-18:30}"
    case "$t" in *:*) ;; *) say "Please give the time as HH:MM, e.g. 07:30"; return 1 ;; esac
    h=${t%%:*}; m=${t#*:}
    case "$h" in ''|*[!0-9]*) say "Invalid time: $t (use HH:MM)"; return 1 ;; esac
    case "$m" in ''|*[!0-9]*) say "Invalid time: $t (use HH:MM)"; return 1 ;; esac
    [ "$h" -le 23 ] && [ "$m" -le 59 ] || { say "Invalid time: $t"; return 1; }
    h=$(echo "$h" | sed 's/^0*\([0-9]\)/\1/')   # "008" -> "8", never octal
    m=$(echo "$m" | sed 's/^0*\([0-9]\)/\1/')
    job="$m $h * * * sh $SCRIPT_PATH run"
    cru d "$CRU_ID" 2>/dev/null
    cru a "$CRU_ID" "$job"
    # Re-create the schedule after each reboot.
    ss=/jffs/scripts/services-start
    [ -f "$ss" ] || printf '#!/bin/sh\n' > "$ss"
    sed -i "/# $CRU_ID\$/d" "$ss"
    [ -n "$(tail -c 1 "$ss")" ] && echo >> "$ss"    # file not ending with a newline
    printf 'cru a %s "%s" # %s\n' "$CRU_ID" "$job" "$CRU_ID" >> "$ss"
    chmod 755 "$ss"
    say "Daily digest scheduled at $(printf '%02d:%02d' "$h" "$m")."
}

do_unschedule() {
    cru d "$CRU_ID" 2>/dev/null
    ss=/jffs/scripts/services-start
    if [ -f "$ss" ] && grep -q "# $CRU_ID\$" "$ss"; then
        sed -i "/# $CRU_ID\$/d" "$ss"
        # Nothing left but the shebang (the file was created for DigestMerlin): remove it.
        [ -z "$(grep -v '^#!/bin/sh$' "$ss" | grep -v '^[[:space:]]*$')" ] && rm -f "$ss"
    fi
    say "Daily e-mail stopped. Files kept in $DM_DIR."
}

# Remove every trace: schedule, services-start line, settings, history, files.
do_remove_all() {
    do_unschedule >/dev/null
    rm -rf "$DM_DIR" /tmp/digestmerlin.* /tmp/digestmerlin-*
    rm -f "$SCRIPT_PATH"
    log "DigestMerlin removed"
    say "DigestMerlin has been removed. Thanks for trying it!"
}

# ---------------------------------------------------------------- install / update
# Used by "setup" (first install, e.g. from amtm), "update", amtm's
# "amtmupdate" and the menu. Everything is downloaded and checked first, so a
# failed download never leaves a half-updated copy. Settings and history are
# never touched.

# 0 if every file of this version is present (list kept at install time).
files_complete() {
    [ -f "$SCRIPT_PATH" ] && [ -f "$SECTIONS_DIR/lib.sh" ] || return 1
    [ -n "$(ls "$SECTIONS_DIR"/[0-9][0-9]-*.sh 2>/dev/null)" ] || return 1
    [ -f "$DM_DIR/.files" ] || return 0
    for f in $(cat "$DM_DIR/.files"); do
        [ -f "$SECTIONS_DIR/$f" ] || return 1
    done
}

# Latest version number published on GitHub (empty if unreachable).
remote_version() {
    curl -fsSL --max-time 20 "$REPO/digestmerlin.sh" 2>/dev/null \
        | sed -n 's/^version=\([0-9][0-9.]*\)$/\1/p; s/^VERSION="\([0-9][0-9.]*\)"$/\1/p' | head -1
}

# Download all files into $1. Returns 1 on any failure. The list of sections
# is read from the NEW main script, so sections added by a later version are
# downloaded too (this running copy may be older).
fetch_release() {
    rm -rf "$1"; mkdir -p "$1/sections" || return 1
    curl -fsSL --max-time 30 "$REPO/digestmerlin.sh" -o "$1/digestmerlin.sh" || return 1
    sh -n "$1/digestmerlin.sh" 2>/dev/null || return 1
    grep -q '^version=[0-9]' "$1/digestmerlin.sh" || return 1
    files=$(sed -n 's/^SECTION_FILES="\(.*\)"$/\1/p' "$1/digestmerlin.sh" | head -1)
    [ -n "$files" ] || return 1
    printf '%s\n' "$files" > "$1/.files"
    curl -fsSL --max-time 30 "$REPO/digestmerlin.conf.sample" -o "$1/digestmerlin.conf.sample" || return 1
    for f in $files; do
        case "$f" in */*|'') return 1 ;; esac      # plain file names only
        curl -fsSL --max-time 30 "$REPO/sections/$f" -o "$1/sections/$f" || return 1
        sh -n "$1/sections/$f" 2>/dev/null || return 1
    done
}

# Install the files downloaded in $1, all or nothing: every file is first
# copied next to its target (.new); only when all copies succeeded are they
# renamed over the old ones. A running copy of the script is never overwritten
# in place, and a full /jffs leaves the old version intact.
install_release() {
    files=$(cat "$1/.files") || return 1
    mkdir -p "$DM_DIR/sections" "${SCRIPT_PATH%/*}" || return 1
    staged="$SCRIPT_PATH|$1/digestmerlin.sh
$DM_DIR/digestmerlin.conf.sample|$1/digestmerlin.conf.sample"
    for f in $files; do
        staged="$staged
$DM_DIR/sections/$f|$1/sections/$f"
    done
    ok=1
    printf '%s\n' "$staged" > "$1/.staged"
    while IFS='|' read -r dst src; do
        cp "$src" "$dst.new" 2>/dev/null || { ok=0; break; }
    done < "$1/.staged"
    if [ "$ok" = "0" ]; then
        while IFS='|' read -r dst src; do rm -rf "$dst.new"; done < "$1/.staged"
        return 1
    fi
    while IFS='|' read -r dst src; do
        mv "$dst.new" "$dst" || ok=2
    done < "$1/.staged"
    if [ "$ok" = "2" ]; then
        while IFS='|' read -r dst src; do rm -f "$dst.new"; done < "$1/.staged"
        return 2
    fi
    # Sections shipped by the previous version but not by this one are removed.
    # Only names from our own list: a section you wrote yourself is never touched.
    if [ "$ok" = "1" ] && [ -f "$DM_DIR/.files" ]; then
        for f in $(cat "$DM_DIR/.files"); do
            case " $files " in *" $f "*) ;; *) case "$f" in */*|'') ;; *) rm -f "$DM_DIR/sections/$f" ;; esac ;; esac
        done
    fi
    [ "$ok" = "1" ] && printf '%s\n' "$files" > "$DM_DIR/.files"
    chmod 700 "$DM_DIR"
    chmod 755 "$DM_DIR/sections" "$SCRIPT_PATH" "$DM_DIR"/sections/*.sh
    chmod 644 "$DM_DIR/digestmerlin.conf.sample"
    [ "$ok" = "1" ]
}

# Non-interactive update (also what amtm runs). 0 = updated, 1 = failed.
do_update() {
    tmp="/tmp/digestmerlin-update.$$"
    say "Downloading DigestMerlin..."
    if ! fetch_release "$tmp"; then
        rm -rf "$tmp"
        log "ERROR: update failed (download) - nothing was changed"
        say "ERROR: download failed - nothing was changed. Try again later." >&2
        return 1
    fi
    install_release "$tmp"; irc=$?
    if [ "$irc" -ne 0 ]; then
        rm -rf "$tmp"
        if [ "$irc" -eq 2 ]; then
            log "ERROR: update only partly installed - run the update again"
            say "ERROR: the update was only partly installed (is /jffs full?) - free some space and run it again." >&2
        else
            log "ERROR: update failed (could not write the files) - nothing was changed"
            say "ERROR: could not write the files (is /jffs full?) - nothing was changed." >&2
        fi
        return 1
    fi
    new=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT_PATH" | head -1)
    rm -rf "$tmp"
    log "Installed v$new (was v$VERSION)"
    say "DigestMerlin v$new installed."
    return 0
}

# First install (install.sh and amtm call it): files, then the schedule question.
do_setup() {
    curl --version >/dev/null 2>&1 || { say "ERROR: curl not found" >&2; return 1; }
    do_update || return 1
    case "$(mail_method)" in
        none)    say "NOTE: e-mail is not set up yet - in amtm: 'em' (e-mail settings), then 'se' (SendEmail)." ;;
        library) say "NOTE: SendEmail is recommended to send the digest - in amtm, choose 'se'." ;;
    esac
    if cru l 2>/dev/null | grep -q "#$CRU_ID#"; then
        say "The daily e-mail is already scheduled: $(schedule_time)"
    elif [ -t 0 ]; then
        printf "Schedule the daily e-mail at 18:30? [y/N] "
        read -r ans
        case "$ans" in
            y|Y) sh "$SCRIPT_PATH" install 18:30 ;;
            *)   say "Not scheduled. You can do it from the menu (option 3)." ;;
        esac
    fi
    say ""
    say "Open the menu (preview, send time, sections, settings...):"
    say "    sh $SCRIPT_PATH"
}

# ---------------------------------------------------------------- menu
# The menu only calls the commands above and edits digestmerlin.conf.

# Settings offered in the menu:
# KEY|default|label|kind (num, opt = number or off, bool, text)|explanation|example
SETTINGS="WG_HANDSHAKE_MAX|600|VPN: seconds without a WireGuard handshake|num|Alert when a WireGuard tunnel has had no handshake for this long (seconds).|600 = 10 minutes
SPEEDTEST_MAX_AGE_H|25|spdMerlin: hours without a new result|num|Alert when spdMerlin has not produced a new result for this many hours.|25 for a daily test
BACKUP_MAX_AGE_H|26|BACKUPMON: hours since the last NVRAM backup|num|Alert when the last BACKUPMON NVRAM backup is older than this (hours).|26 for a daily backup
DISK_ALERT_PCT|90|Storage: % used|num|Alert when /jffs or the USB drive is fuller than this (%).|90
CPU_TEMP_ALERT||CPU temperature in C|opt|Alert when the CPU reaches this temperature (C). Normal values depend on the model.|about 10 above your usual value, e.g. 75
REBOOT_MAX_DAYS||Days without a reboot|opt|Alert when the router has been running longer than this (days).|8 for a weekly reboot
DEVICES_IGNORE_PRIVATE_MAC|0|New devices: ignore private MACs (0 or 1)|bool|1 = do not report devices using a random private MAC address (phones, laptops).|0 to report them, 1 to ignore them
SUBJECT_PREFIX||Text in front of the e-mail subject|text|Added in front of the subject, e.g. to tell several routers apart.|[Home]"

pause() { printf '\n Press Enter to continue... '; read -r _ || exit 0; }

# Current value of a setting in digestmerlin.conf (last definition wins), quotes removed.
conf_get() {
    [ -f "$DM_CONF" ] || return 0
    sed -n "s/^$1=//p" "$DM_CONF" | tail -1 | sed 's/^"\(.*\)"$/\1/'
}

# Write KEY="value" in digestmerlin.conf, replacing an existing line or adding one.
conf_set() {
    if [ ! -f "$DM_CONF" ]; then
        if [ -f "$DM_DIR/digestmerlin.conf.sample" ]; then
            cp "$DM_DIR/digestmerlin.conf.sample" "$DM_CONF"
        else
            printf '# DigestMerlin settings\n' > "$DM_CONF"
        fi
    fi
    DM_LINE="$1=\"$2\"" DM_KEY="$1" awk '
        BEGIN {k = ENVIRON["DM_KEY"]; line = ENVIRON["DM_LINE"]}
        index($0, k "=") == 1 {if (!done) print line; done = 1; next}
        {print}
        END {if (!done) print line}' "$DM_CONF" > "$DM_CONF.new"
    # BusyBox awk returns 0 even when the write failed (full /jffs): check the
    # result before it replaces the settings.
    # shellcheck disable=SC1090
    if [ -s "$DM_CONF.new" ] && grep -q "^$1=" "$DM_CONF.new" && sh -n "$DM_CONF.new" 2>/dev/null \
        && ( . "$DM_CONF.new" ) >/dev/null 2>&1 && mv "$DM_CONF.new" "$DM_CONF"; then
        chmod 644 "$DM_CONF"
        return 0
    fi
    rm -f "$DM_CONF.new"
    if [ -n "$CONF_BROKEN" ]; then
        say " Could not save: $DM_CONF has an error. Fix it by hand (nano or vi), or delete it to go back to the defaults."
    else
        say " Could not save the setting (is /jffs full?) - nothing was changed."
    fi
    pause
    return 1
}

schedule_time() {
    cru l 2>/dev/null | grep "#$CRU_ID#" | head -1 | awk '{printf "%02d:%02d", $2, $1}'
}

menu_header() {
    printf '\033[2J\033[H'
    t=$(schedule_time)
    last="none yet"
    if [ -f "$DM_STATE/last_run" ]; then
        IFS='|' read -r lts ltag lstat < "$DM_STATE/last_run"
        last="$(date -d "@$lts" '+%a %d %b %H:%M' 2>/dev/null) [$ltag] $lstat"
    fi
    lasttest=""
    if [ -f "$DM_STATE/last_test" ]; then
        IFS='|' read -r tts ttag tstat < "$DM_STATE/last_test"
        lasttest="$(date -d "@$tts" '+%a %d %b %H:%M' 2>/dev/null) [$ttag] $tstat"
    fi
    case "$(mail_method)" in
        SendEmail) mail="SendEmail" ;;
        library)   mail="library only - install SendEmail (see below)" ;;
        *)         mail="NOT set up - see below" ;;
    esac
    n_all=0; n_off=0
    for mod in "$SECTIONS_DIR"/[0-9][0-9]-*.sh; do
        [ -f "$mod" ] || continue
        n_all=$((n_all + 1))
        case " $(conf_get DISABLED_SECTIONS) " in *" $(section_name "$mod") "*) n_off=$((n_off + 1)) ;; esac
    done
    say " ==============================================="
    say "   DigestMerlin v$VERSION  -  $(nvram get productid 2>/dev/null)"
    say " ==============================================="
    say "   Daily e-mail : ${t:-not scheduled}"
    say "   Last digest  : $last"
    [ -n "$lasttest" ] && say "   Last test    : $lasttest"
    say "   E-mail       : $mail"
    say "   Sections     : $((n_all - n_off)) of $n_all enabled"
    [ -n "$CONF_BROKEN" ] && say "   WARNING      : settings file has a syntax error - defaults in use"
    [ "$n_all" -eq 0 ] && say "   WARNING      : no section installed - use option 6 to reinstall"
    case "$(mail_method)" in
        none)
            say " -----------------------------------------------"
            say "   E-mail is not set up yet. Do it once in amtm:"
            say "   1. exit this menu (e) and type: amtm"
            say "   2. choose 'em' and enter your e-mail settings"
            say "   3. choose 'se' to install SendEmail"
            say "   4. come back here and send a test (option 2)" ;;
        library)
            say " -----------------------------------------------"
            say "   Recommended: install SendEmail, which keeps the"
            say "   e-mail library up to date: in amtm, choose 'se'." ;;
    esac
    say " -----------------------------------------------"
}

menu_time() {
    t=$(schedule_time)
    say ""
    say " Daily e-mail: ${t:-not scheduled}"
    printf ' New time HH:MM (e.g. 07:30), "off" to stop it, Enter to keep it: '
    read -r ans || exit 0
    case "$ans" in
        '') return ;;
        off|OFF) do_unschedule >/dev/null; say " Daily e-mail stopped." ;;
        *) do_install "$ans" ;;
    esac
    pause
}

menu_sections() {
    while :; do
        printf '\033[2J\033[H'
        say " Sections - choose a number to switch it on or off"
        say ""
        off=" $(conf_get DISABLED_SECTIONS) "
        i=0
        for mod in "$SECTIONS_DIR"/[0-9][0-9]-*.sh; do
            [ -f "$mod" ] || continue
            i=$((i + 1))
            name=$(section_name "$mod")
            title=$(sed -n '2s/^# TITLE: *//p' "$mod")
            case "$off" in *" $name "*) mark=" " ;; *) mark="x" ;; esac
            printf '   %d. [%s] %s\n' "$i" "$mark" "${title:-$name}"
        done
        say ""
        say "   b. Back"
        printf '\n Choose: '
        read -r ans || exit 0
        case "$ans" in
            b|B|'') return ;;
            *[!0-9]*) continue ;;
        esac
        i=0; pick=""
        for mod in "$SECTIONS_DIR"/[0-9][0-9]-*.sh; do
            [ -f "$mod" ] || continue
            i=$((i + 1))
            [ "$i" -eq "$ans" ] && pick=$(section_name "$mod")
        done
        [ -n "$pick" ] || continue
        new=""
        found=0
        for s in $(conf_get DISABLED_SECTIONS); do
            if [ "$s" = "$pick" ]; then found=1; else new="$new $s"; fi
        done
        [ "$found" = "0" ] && new="$new $pick"
        conf_set DISABLED_SECTIONS "${new# }"
    done
}

menu_settings() {
    while :; do
        printf '\033[2J\033[H'
        say " Settings - alerts are raised when a value goes past these limits"
        say ""
        i=0
        printf '%s\n' "$SETTINGS" | while IFS='|' read -r key def desc kind _help _ex; do
            i=$((i + 1))
            v=$(conf_get "$key"); [ -f "$DM_CONF" ] && grep -q "^$key=" "$DM_CONF" || v=$def
            [ "$kind" = "text" ] && none="none" || none="off"
            printf '   %d. %-44s [%s]\n' "$i" "$desc" "${v:-$none}"
        done
        say ""
        say "   b. Back"
        printf '\n Choose: '
        read -r ans || exit 0
        case "$ans" in
            b|B|'') return ;;
            *[!0-9]*) continue ;;
        esac
        line=$(printf '%s\n' "$SETTINGS" | sed -n "${ans}p" 2>/dev/null)
        [ -n "$line" ] || continue
        IFS='|' read -r key def desc kind help ex <<EOF_LINE
$line
EOF_LINE
        [ "$kind" = "text" ] && none="none" || none="off"
        cur=$(conf_get "$key"); [ -f "$DM_CONF" ] && grep -q "^$key=" "$DM_CONF" || cur=$def
        printf '\033[2J\033[H'
        say " ${desc%% (*}"
        say ""
        say " $help"
        say " Example: $ex"
        say ""
        say " Current: ${cur:-$none}    Default: ${def:-$none}"
        case "$kind" in
            num)  printf ' New value (a number), Enter to keep the current value: ' ;;
            opt)  printf ' New value (a number), "off" to disable, Enter to keep the current value: ' ;;
            bool) printf ' New value (0 or 1), Enter to keep the current value: ' ;;
            text) printf ' New text, "none" to remove it, Enter to keep the current value: ' ;;
        esac
        read -r val || exit 0
        [ -n "$val" ] || continue
        case "$kind" in
            num)  is_num "$val" || { say " Please enter a number."; pause; continue; } ;;
            opt)  [ "$val" = "off" ] && val=""
                  [ -z "$val" ] || is_num "$val" || { say " Please enter a number or off."; pause; continue; } ;;
        esac
        case "$kind" in
            num|opt)
                if [ -n "$val" ]; then
                    val=$(echo "$val" | sed 's/^0*\([0-9]\)/\1/')   # "075" -> "75", never octal
                    [ ${#val} -le 6 ] || { say " Please enter a smaller number."; pause; continue; }
                    r=$(setting_range "$key"); lo=${r% *}; hi=${r#* }
                    if [ "$val" -lt "$lo" ] || [ "$val" -gt "$hi" ]; then
                        say " Please enter a value between $lo and $hi."; pause; continue
                    fi
                fi ;;
            bool) case "$val" in 0|1) ;; *) say " Please enter 0 or 1."; pause; continue ;; esac ;;
            text) [ "$val" = "none" ] && val=""
                  case "$val" in *[\"\\\$\`\'=]*|-*) say ' Not allowed: " \ $ ` = and apostrophes, or a leading -'; pause; continue ;; esac ;;
        esac
        conf_set "$key" "$val"
    done
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# Accepted range for each numeric setting: protects against typos (e.g. 6C).
setting_range() {
    case "$1" in
        WG_HANDSHAKE_MAX)    echo "60 86400" ;;
        SPEEDTEST_MAX_AGE_H) echo "1 720" ;;
        BACKUP_MAX_AGE_H)    echo "1 720" ;;
        DISK_ALERT_PCT)      echo "1 100" ;;
        CPU_TEMP_ALERT)      echo "40 125" ;;
        REBOOT_MAX_DAYS)     echo "1 365" ;;
        *)                   echo "0 999999" ;;
    esac
}

# 1 if version $1 is newer than $2 (numbers separated by dots)
# True if version $1 is newer than $2. A test build ("0.3.0-test9") is older
# than the release with the same number ("0.3.0").
is_newer() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        sa = (a ~ /-/); sb = (b ~ /-/); sub(/-.*/, "", a); sub(/-.*/, "", b)
        na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
        exit !(sb && !sa) }'
}

menu_update() {
    say ""
    say " Checking GitHub..."
    remote=$(remote_version)
    if [ -z "$remote" ]; then
        say " Could not reach GitHub - try again later."
    elif is_newer "$remote" "$VERSION"; then
        printf ' Version %s is available (you have %s). Update now? [y/N] ' "$remote" "$VERSION"
        read -r ans || exit 0
        case "$ans" in
            y|Y)
                if do_update; then
                    say ""
                    say " Open the menu again to use the new version."
                    exit 0
                fi ;;
        esac
    elif ! files_complete; then
        printf ' You have the latest version, but some files are missing. Reinstall them now? [y/N] '
        read -r ans || exit 0
        case "$ans" in y|Y) do_update ;; esac
    else
        say " You have the latest version ($VERSION)."
    fi
    pause
}

menu_uninstall() {
    say ""
    say " This removes the schedule, the settings, the history and all DigestMerlin files."
    printf ' Remove DigestMerlin completely? [y/N] '
    read -r ans || exit 0
    case "$ans" in
        y|Y) do_remove_all; exit 0 ;;
    esac
}

menu() {
    while :; do
        menu_header
        say "   1. Preview the digest (nothing is sent)"
        say "   2. Send the digest by e-mail now (test)"
        say "   3. Change the send time"
        say "   4. Enable / disable sections"
        say "   5. Alert thresholds and settings"
        say "   6. Check for updates"
        say "   7. Uninstall"
        say " -----------------------------------------------"
        say "   e. Exit"
        printf '\n Choose an option: '
        read -r ans || exit 0
        case "$ans" in
            1) say ""; say " Building the digest..."; say ""
               ( DM_PREVIEW=1; export DM_PREVIEW; build_digest && { say "Subject: $SUBJECT"; say ""; say "$BODY"; } )
               pause ;;
            2) say ""; say " Building and sending the digest..."
               # A test never moves the history on (known devices, firmware...):
               # the next scheduled digest still reports what it should.
               if ( SEND_TRIES=2; RETRY_WAIT=10; DM_PREVIEW=1; DM_TEST=1; export DM_PREVIEW DM_TEST
                    log "Building the daily digest (test from the menu)"; build_digest && send_digest ); then
                   say " Sent: check your inbox."
               else
                   say " NOT sent - check the e-mail settings in amtm ('em', and 'se' for SendEmail)."
               fi
               pause ;;
            3) menu_time ;;
            4) menu_sections ;;
            5) menu_settings ;;
            6) menu_update ;;
            7) menu_uninstall ;;
            e|E) say ""; exit 0 ;;
        esac
        # Settings may have changed: reload them.
        DISABLED_SECTIONS=""; SUBJECT_PREFIX=""
        load_conf
    done
}

usage() {
    sed -n 's/^#   \(digestmerlin\.sh .*\)/  \1/p' "$0"
}

case "$1" in
    ''|menu)
        if [ -t 0 ]; then menu; else usage; exit 1; fi
        ;;
    preview)
        DM_PREVIEW=1; export DM_PREVIEW
        build_digest || exit 1
        say "Subject: $SUBJECT"; say ""; say "$BODY"
        ;;
    run)
        log "Building the daily digest"
        build_digest || exit 1
        send_digest
        ;;
    section)
        f=$(ls "$SECTIONS_DIR"/[0-9][0-9]-"$2".sh 2>/dev/null | head -1)
        [ -n "$f" ] || { say "No section named '$2' in $SECTIONS_DIR"; exit 1; }
        DM_PREVIEW=1; export DM_PREVIEW
        sh "$f"; rc=$?
        [ "$rc" -eq 3 ] && { say "(section not applicable: tool not installed)"; exit 0; }
        exit "$rc"
        ;;
    install)    do_install "$2" ;;
    unschedule) do_unschedule ;;
    setup|-setup) do_setup ;;
    update)     do_update ;;
    amtmupdate)
        # amtm: "amtmupdate check" = is automatic update supported (0 = yes);
        # "amtmupdate" = update now, without any question.
        [ "$2" = "check" ] && exit 0
        do_update ;;
    uninstall|-uninstall)
        if [ "$2" = "-y" ]; then
            do_remove_all
        elif [ -t 0 ]; then
            menu_uninstall
            say " Nothing was removed."
        else
            say "To remove DigestMerlin completely: $0 uninstall -y"
            exit 1
        fi ;;
    version)    say "DigestMerlin v$VERSION" ;;
    *)
        usage
        exit 1
        ;;
esac

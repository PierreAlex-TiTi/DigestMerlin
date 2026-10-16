#!/bin/sh
# DigestMerlin - one daily e-mail summarising the health of an Asuswrt-Merlin
# router and its add-ons (Skynet, WireGuard/VPNMON-R3, spdMerlin, BACKUPMON...).
# Read-only: it reports, it never changes the router's configuration.
#
#   digestmerlin.sh                  open the menu
#   digestmerlin.sh preview          build the digest and print it (no e-mail)
#   digestmerlin.sh run              build the digest and e-mail it
#   digestmerlin.sh section NAME     run one section (e.g. "vpn") for testing
#   digestmerlin.sh install [HH:MM]  schedule the daily e-mail (default 18:30)
#   digestmerlin.sh uninstall        remove the schedule
#
# Each section is a small script in sections/ (NN-name.sh). Sections whose
# tool is not installed are skipped. A failing or hanging section never stops
# the e-mail: it is reported as unavailable.

VERSION="0.2.0"
REPO="https://raw.githubusercontent.com/PierreAlex-TiTi/DigestMerlin/main"
SCRIPT_PATH="/jffs/scripts/digestmerlin.sh"
DM_DIR="${DM_DIR:-/jffs/addons/digestmerlin.d}"
SECTIONS_DIR="${SECTIONS_DIR:-$DM_DIR/sections}"
DM_CONF="${DM_CONF:-$DM_DIR/digestmerlin.conf}"
DM_STATE="${DM_STATE:-$DM_DIR/state}"
CEM_LIB="${CEM_LIB:-/jffs/addons/shared-libs/CustomEMailFunctions.lib.sh}"
CRU_ID="DigestMerlin"
LOGTAG="DigestMerlin"
SECTION_TIMEOUT="${SECTION_TIMEOUT:-120}"
RETRY_WAIT="${RETRY_WAIT:-60}"

DISABLED_SECTIONS=""
SUBJECT_PREFIX=""
# shellcheck disable=SC1090
[ -f "$DM_CONF" ] && . "$DM_CONF"
export DM_DIR DM_CONF DM_STATE

umask 022   # Merlin shells may run with umask 000: never create world-writable files

say() { printf '%s\n' "$*"; }
log() { logger -t "$LOGTAG" "$*"; }

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
    trap 'rm -rf "$WORK"' EXIT INT TERM

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
            kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
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
    if [ -f "$DM_STATE/unsent" ]; then
        printf -- '- The previous digest could not be e-mailed - check the e-mail settings in amtm (em)\n' >> "$DM_ALERTS"
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

send_digest() {
    if [ ! -f "$CEM_LIB" ]; then
        log "ERROR: amtm e-mail library not found ($CEM_LIB) - set up e-mail in amtm (em)"
        say "ERROR: amtm e-mail library not found - set up e-mail in amtm (em) first." >&2
        return 1
    fi
    # shellcheck disable=SC1090
    . "$CEM_LIB"
    # shellcheck disable=SC2034
    cemScriptFNameTag="$LOGTAG"
    try=1; rc=0
    while [ "$try" -le 3 ]; do
        _SendEMailNotification_CEM_ "$SUBJECT" "$BODY"; rc=$?
        if [ "$rc" -eq 0 ]; then
            log "Daily digest sent ($tag)"
            rm -f "$DM_STATE/unsent"
            save_last_run "$tag" sent
            return 0
        fi
        log "Sending failed (attempt $try/3, code $rc)"
        [ "$try" -lt 3 ] && sleep "$RETRY_WAIT"
        try=$((try + 1))
    done
    # shellcheck disable=SC2174
    mkdir -p -m 700 "$DM_STATE"
    printf '%s\n\n%s\n' "$SUBJECT" "$BODY" > "$DM_STATE/unsent"
    chmod 600 "$DM_STATE/unsent"
    save_last_run "$tag" "NOT sent"
    log "ERROR: digest not sent after 3 attempts (code $rc) - kept in $DM_STATE/unsent"
    return 1
}

# Shown in the menu header: "epoch|OK|sent"
save_last_run() {
    # shellcheck disable=SC2174
    mkdir -p -m 700 "$DM_STATE" && printf '%s|%s|%s\n' "$(date +%s)" "$1" "$2" > "$DM_STATE/last_run"
}

do_install() {
    t="${1:-18:30}"
    h=${t%%:*}; m=${t#*:}
    case "$h$m" in ''|*[!0-9]*) say "Usage: $0 install HH:MM"; return 1 ;; esac
    [ "$h" -le 23 ] && [ "$m" -le 59 ] || { say "Invalid time: $t"; return 1; }
    h=$(echo "$h" | sed 's/^0\(.\)/\1/')
    m=$(echo "$m" | sed 's/^0\(.\)/\1/')
    job="$m $h * * * sh $SCRIPT_PATH run"
    cru d "$CRU_ID" 2>/dev/null
    cru a "$CRU_ID" "$job"
    # Re-create the schedule after each reboot.
    ss=/jffs/scripts/services-start
    [ -f "$ss" ] || printf '#!/bin/sh\n' > "$ss"
    sed -i "/# $CRU_ID\$/d" "$ss"
    printf 'cru a %s "%s" # %s\n' "$CRU_ID" "$job" "$CRU_ID" >> "$ss"
    chmod 755 "$ss"
    say "Daily digest scheduled at $(printf '%02d:%02d' "$h" "$m")."
}

do_uninstall() {
    cru d "$CRU_ID" 2>/dev/null
    [ -f /jffs/scripts/services-start ] && sed -i "/# $CRU_ID\$/d" /jffs/scripts/services-start
    say "Schedule removed. Files kept in $DM_DIR (delete them to remove everything)."
}

# ---------------------------------------------------------------- menu
# The menu only calls the commands above and edits digestmerlin.conf.

# Settings offered in the menu: KEY|default|description|kind (num, opt = number or empty, bool, text)
SETTINGS="WG_HANDSHAKE_MAX|600|VPN: seconds without a WireGuard handshake|num
SPEEDTEST_MAX_AGE_H|25|spdMerlin: hours without a new result|num
BACKUP_MAX_AGE_H|26|BACKUPMON: hours since the last NVRAM backup|num
DISK_ALERT_PCT|90|Storage: % used|num
CPU_TEMP_ALERT||CPU temperature in C|opt
REBOOT_MAX_DAYS||Days without a reboot|opt
DEVICES_IGNORE_PRIVATE_MAC|0|New devices: ignore private MACs (0 or 1)|bool
SUBJECT_PREFIX||Text in front of the e-mail subject|text"

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
        END {if (!done) print line}' "$DM_CONF" > "$DM_CONF.new" \
        && mv "$DM_CONF.new" "$DM_CONF" && chmod 644 "$DM_CONF"
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
    if [ -f "$CEM_LIB" ]; then mail="found"; else mail="NOT set up - run amtm, option em"; fi
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
    say "   amtm e-mail  : $mail"
    say "   Sections     : $((n_all - n_off)) of $n_all enabled"
    say " -----------------------------------------------"
}

menu_time() {
    t=$(schedule_time)
    say ""
    say " Daily e-mail: ${t:-not scheduled}"
    printf ' New time HH:MM, "off" to stop it, Enter to cancel: '
    read -r ans || exit 0
    case "$ans" in
        '') return ;;
        off|OFF) do_uninstall >/dev/null; say " Daily e-mail stopped." ;;
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
        printf '%s\n' "$SETTINGS" | while IFS='|' read -r key def desc kind; do
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
        key=${line%%|*}; rest=${line#*|}; def=${rest%%|*}; rest=${rest#*|}; desc=${rest%%|*}; kind=${rest#*|}
        say ""
        [ "$kind" = "text" ] && none="none" || none="off"
        say " $desc (default: ${def:-$none})"
        case "$kind" in
            opt)  printf ' New value, "off" to disable, Enter to cancel: ' ;;
            text) printf ' New text, "none" to remove it, Enter to cancel: ' ;;
            *)    printf ' New value, Enter to cancel: ' ;;
        esac
        read -r val || exit 0
        [ -n "$val" ] || continue
        case "$kind" in
            num)  is_num "$val" || { say " Please enter a number."; pause; continue; } ;;
            opt)  [ "$val" = "off" ] && val=""
                  [ -z "$val" ] || is_num "$val" || { say " Please enter a number or off."; pause; continue; } ;;
            bool) case "$val" in 0|1) ;; *) say " Please enter 0 or 1."; pause; continue ;; esac ;;
            text) [ "$val" = "none" ] && val=""
                  case "$val" in *[\"\\\$\`]*) say ' These characters are not allowed: " \ $ `'; pause; continue ;; esac ;;
        esac
        conf_set "$key" "$val"
    done
}

is_num() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# 1 if version $1 is newer than $2 (numbers separated by dots)
is_newer() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb) ? na : nb
        for (i = 1; i <= n; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
        exit 1 }'
}

menu_update() {
    say ""
    say " Checking GitHub..."
    remote=$(curl -fsSL --max-time 20 "$REPO/digestmerlin.sh" 2>/dev/null | sed -n 's/^VERSION="\([0-9.]*\)"$/\1/p' | head -1)
    if [ -z "$remote" ]; then
        say " Could not reach GitHub - try again later."
    elif is_newer "$remote" "$VERSION"; then
        printf ' Version %s is available (you have %s). Update now? [y/N] ' "$remote" "$VERSION"
        read -r ans || exit 0
        case "$ans" in
            y|Y)
                if curl -fsSL --max-time 30 "$REPO/install.sh" -o /tmp/dm-install.sh; then
                    sh /tmp/dm-install.sh
                    rm -f /tmp/dm-install.sh
                    say ""
                    say " Open the menu again to use the new version."
                    exit 0
                fi
                say " Download failed - nothing was changed." ;;
        esac
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
        y|Y)
            do_uninstall >/dev/null
            rm -rf "$DM_DIR" /tmp/digestmerlin.* /tmp/digestmerlin-ww.*
            rm -f "$SCRIPT_PATH"
            say " DigestMerlin has been removed. Thanks for trying it!"
            exit 0 ;;
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
               if ( log "Building the daily digest (test from the menu)"; build_digest && send_digest ); then
                   say " Sent: check your inbox."
               else
                   say " NOT sent - check the e-mail settings in amtm (em)."
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
        # shellcheck disable=SC1090
        [ -f "$DM_CONF" ] && . "$DM_CONF"
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
        [ "$rc" -eq 3 ] && say "(section not applicable: tool not installed)"
        exit 0
        ;;
    install)   do_install "$2" ;;
    uninstall) do_uninstall ;;
    version)   say "DigestMerlin v$VERSION" ;;
    *)
        usage
        exit 1
        ;;
esac

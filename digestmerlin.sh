#!/bin/sh
# DigestMerlin - one daily e-mail summarising the health of an Asuswrt-Merlin
# router and its add-ons (Skynet, WireGuard/VPNMON-R3, spdMerlin, BACKUPMON...).
# Read-only: it reports, it never changes the router's configuration.
#
#   digestmerlin.sh preview          build the digest and print it (no e-mail)
#   digestmerlin.sh run              build the digest and e-mail it
#   digestmerlin.sh section NAME     run one section (e.g. "vpn") for testing
#   digestmerlin.sh install [HH:MM]  schedule the daily e-mail (default 18:30)
#   digestmerlin.sh uninstall        remove the schedule
#
# Each section is a small script in sections/ (NN-name.sh). Sections whose
# tool is not installed are skipped. A failing or hanging section never stops
# the e-mail: it is reported as unavailable.

VERSION="0.1.4"
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
    SUBJECT="${SUBJECT_PREFIX}[$tag] Daily digest ${host:-router} - $(date '+%Y-%m-%d')"
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
    log "ERROR: digest not sent after 3 attempts (code $rc) - kept in $DM_STATE/unsent"
    return 1
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

case "$1" in
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
        sed -n '5,9s/^# //p' "$0"
        exit 1
        ;;
esac

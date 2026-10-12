#!/bin/sh
# DigestMerlin installer / updater for Asuswrt-Merlin.
#
#   curl -fsSL https://raw.githubusercontent.com/PierreAlex-TiTi/DigestMerlin/main/install.sh -o /tmp/dm-install.sh && sh /tmp/dm-install.sh
#
# Run it again to update: your settings (digestmerlin.conf) and state are kept.
# Nothing is scheduled unless you answer yes at the end (or run "install HH:MM").

REPO="https://raw.githubusercontent.com/PierreAlex-TiTi/DigestMerlin/main"
DM_DIR="/jffs/addons/digestmerlin.d"
SCRIPT="/jffs/scripts/digestmerlin.sh"
SECTIONS="lib.sh 10-skynet.sh 20-vpn.sh 30-speedtest.sh 40-backupmon.sh 50-devices.sh 60-system.sh"

umask 022
fail() { echo "ERROR: $*" >&2; rm -rf "$TMP"; exit 1; }

[ -d /jffs/scripts ] || fail "/jffs/scripts not found - is this an Asuswrt-Merlin router with JFFS enabled?"
# Test by running it: "command -v" is not reliable in every router shell.
curl --version >/dev/null 2>&1 || fail "curl not found"

# Download everything first: a failed download never leaves a half-installed copy.
TMP="/tmp/digestmerlin-install.$$"
rm -rf "$TMP"; mkdir -p "$TMP/sections" || fail "cannot create $TMP"
echo "Downloading DigestMerlin..."
curl -fsSL "$REPO/digestmerlin.sh" -o "$TMP/digestmerlin.sh" || fail "download failed: digestmerlin.sh"
curl -fsSL "$REPO/digestmerlin.conf.sample" -o "$TMP/digestmerlin.conf.sample" || fail "download failed: digestmerlin.conf.sample"
for f in $SECTIONS; do
    curl -fsSL "$REPO/sections/$f" -o "$TMP/sections/$f" || fail "download failed: sections/$f"
done
for f in "$TMP/digestmerlin.sh" "$TMP"/sections/*.sh; do
    sh -n "$f" 2>/dev/null || fail "downloaded file is not a valid script: $(basename "$f")"
done

mkdir -p "$DM_DIR/sections" || fail "cannot create $DM_DIR"
cp "$TMP/digestmerlin.sh" "$SCRIPT"
cp "$TMP/digestmerlin.conf.sample" "$DM_DIR/"
for f in $SECTIONS; do cp "$TMP/sections/$f" "$DM_DIR/sections/$f"; done
chmod 700 "$DM_DIR"
chmod 755 "$DM_DIR/sections" "$SCRIPT" "$DM_DIR"/sections/*.sh
chmod 644 "$DM_DIR/digestmerlin.conf.sample"
rm -rf "$TMP"

echo "Installed $(sh "$SCRIPT" version)."
[ -f /jffs/addons/shared-libs/CustomEMailFunctions.lib.sh ] \
    || echo "NOTE: amtm e-mail is not set up yet - run amtm, option 'em', before using 'run'."
echo
echo "Preview the digest now (nothing is sent):"
echo "    sh $SCRIPT preview"

if cru l 2>/dev/null | grep -q "#DigestMerlin#"; then
    echo "The daily e-mail is already scheduled: $(cru l | grep '#DigestMerlin#' | awk '{printf "%02d:%02d", $2, $1}')"
else
    printf "Schedule the daily e-mail at 18:30? [y/N] "
    read -r ans
    case "$ans" in
        y|Y) sh "$SCRIPT" install 18:30 ;;
        *)   echo "Not scheduled. Later: sh $SCRIPT install HH:MM" ;;
    esac
fi

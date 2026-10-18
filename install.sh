#!/bin/sh
# DigestMerlin installer / updater for Asuswrt-Merlin.
#
#   curl -fsSL https://raw.githubusercontent.com/PierreAlex-TiTi/DigestMerlin/main/install.sh -o /tmp/dm-install.sh && sh /tmp/dm-install.sh
#
# Run it again to update: your settings (digestmerlin.conf), history and schedule are kept.
# It only downloads the main script and runs its "setup" command, which does the work
# (the same command amtm uses).

REPO="${DM_REPO:-https://raw.githubusercontent.com/PierreAlex-TiTi/DigestMerlin/main}"
TMP="/tmp/digestmerlin-install.$$.sh"

umask 022
fail() { echo "ERROR: $*" >&2; rm -f "$TMP"; exit 1; }

[ -d /jffs/scripts ] || fail "/jffs/scripts not found - is this an Asuswrt-Merlin router with JFFS enabled?"
# Test by running it: "command -v" is not reliable in every router shell.
curl --version >/dev/null 2>&1 || fail "curl not found"

curl -fsSL "$REPO/digestmerlin.sh" -o "$TMP" || fail "download failed: digestmerlin.sh"
sh -n "$TMP" 2>/dev/null || fail "downloaded file is not a valid script"
DM_REPO="$REPO" sh "$TMP" setup; rc=$?
rm -f "$TMP"
exit $rc

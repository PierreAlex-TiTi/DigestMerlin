# Changelog

## v0.2.0 - 2026-10-16
- Menu: run `sh /jffs/scripts/digestmerlin.sh` with no argument. Preview, send a test e-mail,
  change the send time, enable/disable sections, alert thresholds and settings, check for
  updates, full uninstall, `e` to exit. The commands (preview, run, install...) still work.
- System: optional CPU temperature alert (`CPU_TEMP_ALERT`, off by default).
- `SUBJECT_PREFIX`: a space is always added between the prefix and the subject.

## v0.1.4 - 2026-10-13
- System: only scripts and executable files writable by anyone raise an alert (they run as root).
  Data files left writable by some add-ons (e.g. spdMerlin results) are reported on an
  information line, grouped by add-on, without an alert.

## v0.1.3 - 2026-10-12
- Installer: "curl not found" on some routers although curl is installed (the shell's
  "command -v" is unreliable there). Commands are now tested by running them.
- nvram reads: same fix for detecting "timeout", so a hanging nvram read is always cut after 5 s.

## v0.1.2 - 2026-10-12
- VPN: OpenVPN clients (connected, connecting, error, stopped while set to start with WAN).
- Ages under one minute shown as "<1m".

## v0.1.1 - 2026-10-12
- Files and folders are never created world-writable (Merlin shells may run with umask 000).
- MerlinAU: an already installed version is no longer reported as pending.
- spdMerlin: interfaces never tested are not listed.
- Skynet: outbound blocks coming from the router itself are labelled "this router".

## v0.1.0 - 2026-10-12
- First version: Skynet, VPN (WireGuard, VPNMON-R3), spdMerlin, BACKUPMON, new devices, system.

# Changelog

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

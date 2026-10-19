# Changelog

## v0.4.0 - (in test)
- New section: **Diversion** (ad blocking). Shows its version and status, the size of the blocking
  list and whether dnsmasq loads it, the last list update and the ads blocked this week (Diversion's
  daily count). Alerts when Diversion or ad blocking is off, when the list is missing, empty, not loaded or
  halved since the last digest, when the list misses its weekly update, and when Diversion's files on
  the USB drive cannot be found.
- SYSTEM: **WAN link drops** in the last 24h (when the link to the modem went down and came back,
  as logged by the firmware), with the time of the last one and the longest; alert when there was one.
  Log lines written at boot before the clock is set are not counted (the reboot is already shown).
- Sections renumbered to make room for it: 10 Skynet, 20 Diversion, 30 VPN, 40 speed tests,
  50 BACKUPMON, 60 new devices, 70 system. Settings (disabled sections...) are kept: they use the
  names, not the numbers. The old files are removed on update, also when updating from v0.2.0;
  a section you wrote yourself is never removed.
- Robustness (three independent reviews):
  - spdMerlin: an interface excluded from automatic tests keeps its last result - it is shown, no longer
    alerted as stale every day;
  - VPNMON-R3 is found also when Entware's procps "ps" is installed;
  - number settings edited by hand: "08" is read as 8, an invalid value ("90%") is ignored and reported;
  - a settings file saved with Windows line endings is read correctly;
  - nvram reads (router name...) are stopped after 5 s, also without Entware's `timeout` (nvram can
    hang on some firmware builds);
  - two runs at the same time (cron and a manual run) can no longer send the same alerts twice;
  - an update interrupted half-way (old and new section files side by side) is reported in the
    digest, without duplicate sections;
  - never "All green" when sections could not run; a damaged e-mail library no longer loses the digest;
  - a section that hangs is stopped together with every program it started;
  - the first run waits for at least one DHCP lease before recording the known devices;
  - the WireGuard handshake limit starts at 180 s (a healthy tunnel renews it every 2 minutes);
  - settings edited by hand must stay within the menu's limits: a value outside them (e.g. a
    WireGuard limit of 60 saved by v0.3.0) is ignored, its default is used and the digest says so;
  - spdMerlin with automatic tests turned off: results shown, no daily "no new result" alert;
  - without Entware's `find`, the digest says the permission check was not done (it was silent);
  - menu option 6 also offers to reinstall when files of this version are missing or old ones remain;
  - the menu reads a settings file with Windows line endings or '...' quotes correctly;
  - a stuck nvram read is killed even if it ignores the stop signal; a lock left by another
    program's pid (after a reboot) no longer blocks the daily e-mail;
  - a full /jffs or /tmp is reported instead of silently losing the digest or the device list;
  - the e-mail library runs apart from DigestMerlin, so it can never stop it.
- E-mail look: section titles in bold (no more "==="), OK in green, ATTENTION and the alerts in red,
  the last lines in grey. The text itself is unchanged, and a mail client that ignores colours shows
  it as before. The menu preview stays plain text.
- An age measured a few seconds after the digest started (e.g. a WireGuard handshake renewed during
  the run) shows "<1m" instead of "?".
- SYSTEM: amtm's own files that anyone can modify are now only reported on their own line, not
  alerted: amtm re-creates them on each update, and its author considers this harmless on a
  single-user router.

## v0.3.0 - 2026-10-18
- amtm-ready: `version=` line, `setup` installs everything from the main script alone,
  `amtmupdate` / `amtmupdate check` for amtm's automatic updates.
- New commands: `update` (latest version, settings kept), `unschedule` (stop the daily e-mail).
- `uninstall` now removes DigestMerlin completely (asks first; `uninstall -y` without question).
  To only stop the daily e-mail, use `unschedule`.
- Menu: clearer settings screens (explanation, example, current and default value).
  Values are checked against sensible ranges (e.g. CPU 40-125C) to catch typos.
- Updates replace files safely (written next to the old one, then renamed) and never touch
  your settings or history. A failed download changes nothing.
- Robustness (found by an independent review):
  - a settings file with an error no longer stops the e-mail, update or uninstall: defaults
    are used and the digest says so;
  - saving a setting on a full /jffs can no longer empty the settings file;
  - the schedule line is never glued to another add-on's line in services-start;
  - no more "[OK] All green" when no section ran (missing files, all disabled, interrupted run);
  - an nvram read that times out no longer raises a false "firmware changed" alert;
  - new devices: IPv6 lease lines and duplicate MACs are ignored;
  - syslog lines of Dec 31 are counted correctly on Jan 1;
  - sections dropped by a future version are removed on update (your own sections are kept).
  - syslog dates are read correctly even when Entware's GNU date (coreutils-date) is installed;
  - a test e-mail from the menu no longer changes the history (known devices...), so the
    next scheduled digest still reports everything;
  - alerts of a digest that could not be sent are repeated in the next one;
  - a section that hangs is stopped together with the programs it started;
  - an update interrupted half-way is reported as such (run it again).
- E-mail is sent through Martinski's SendEmail add-on (install it from amtm: `se`), as he
  suggested. If SendEmail is missing but the Custom Email Library is already on the router, it is
  used directly and the menu recommends SendEmail. (Earlier versions wrongly called the library
  "amtm's shared e-mail library": it is not part of amtm.)
  With SendEmail, the sender name is "DigestMerlin", and the subject prefix is made safe for it
  (apostrophes, a leading "-" or a "Word=" start are adjusted; the menu refuses them).
  E-mail counts as set up only when amtm's e-mail settings exist.
- A digest that cannot be sent, for any reason (e-mail not set up, server error...), is kept and
  its alerts are repeated in the next e-mail, each with the date it was first raised.
- The new-device alert names the devices (MAC and name).
- Menu: a test e-mail is shown on its own line ("Last test") and never hides the last real digest.
- SYSTEM: a file in amtm's folder that anyone can modify raises an alert. amtm runs these files as
  root (its modules, settings, email.conf); amtm re-creates them on its updates, so the alert gives
  the command to run again.
- "install" reads times like 008:09 correctly.
- E-mail: "<", ">" and "&" are escaped, so the digest displays fully in every mail client
  (Outlook could hide everything after "handshake <1m ago").

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

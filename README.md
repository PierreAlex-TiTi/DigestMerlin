# DigestMerlin

**One daily e-mail with the health of your Asuswrt-Merlin router and its add-ons.**

Each add-on (Skynet, VPNMON-R3, spdMerlin, BACKUPMON, MerlinAU...) watches its own corner and
sends its own alerts, or none at all. DigestMerlin reads them all once a day and sends a single,
short summary: what is fine, and what needs a look.

- **Read-only**: it reports, it never changes your router's configuration.
- **Adapts to your router**: a section whose add-on is not installed is skipped.
- **Never silent**: a section that fails or hangs is shown as unavailable (it never blocks the
  e-mail), sending is retried 3 times, and an e-mail that could not be sent is reported in the next one.
- **Uses the e-mail set up in amtm**: no extra password to store.
- **Modular**: one small script per section. Adding a section = dropping a file.

## Example

```
Subject: [OK] Daily digest RT-AX86U_PRO - 2026-10-12

=== SUMMARY ===
All green.

=== SKYNET FIREWALL ===
Blacklist: 42470 IPs | 2779 ranges
List refresh: Mon 12 Oct 11:25 (11h11m ago, daily)
Download failures (24h): 0
Blocked inbound (24h): 0 | outbound: 0

=== VPN ===
WGC1 (FR server): UP | 203.0.113.10:51820 | handshake <1m ago
WGC2 (FR server): UP | 203.0.113.20:51820 | handshake 1m ago
VPNMON-R3: running
Tunnel restarts by VPNMON-R3 (24h): 0

=== SPEED TESTS (spdMerlin) ===
WAN: 878 down / 685 up Mbps, 2 ms (4h21m ago)
WGVPN1: 600 down / 407 up Mbps, 4 ms (4h20m ago)

=== BACKUPS (BACKUPMON) ===
Last NVRAM backup: Mon 12 Oct 04:00 (18h36m ago)
Last JFFS backup: Mon 12 Oct 04:00 (18h36m ago)
Errors (24h): 0

=== NEW DEVICES ===
No new device (12 leased now)

=== SYSTEM ===
Firmware: 3006.102.9_0 (RT-AX86U_PRO)
MerlinAU: no pending update
Last boot: Sun 11 Oct 03:03 (up 1d19h)
Load: 1.18 1.16 1.15 | memory 61% used | swap 0 MB used | CPU 64C
Storage /jffs: 22% used
Storage Entware (USB): 5% used
Scripts writable by anyone: 0

=== ALERTS ===
None

Generated 2026-10-12 22:36 - covers the last 24h
Sections: 6 OK
```

When something is wrong, the subject becomes `[ATTENTION]` and the ALERTS section says what, e.g.
`- VPN: WGC2 has had no handshake for 2h10m - tunnel probably not passing traffic`.

## Sections

| Section | Needs | Reports | Alerts when |
|---|---|---|---|
| Skynet | Skynet (v9 for traffic counts) | blacklist size, last list refresh, download failures, blocked inbound/outbound traffic | blacklist not loaded or halved since yesterday, lists not refreshed on schedule, download failures, log collection stalled |
| VPN | WireGuard and/or OpenVPN clients; VPNMON-R3 optional | each enabled WireGuard client (endpoint, last handshake), each active OpenVPN client, VPNMON-R3 restarts | interface down, no handshake for 10 min, OpenVPN error or stopped while set to start with WAN, VPNMON-R3 not running |
| Speed tests | spdMerlin | latest result per interface | no new result for 25 h, failed tests |
| Backups | BACKUPMON | last NVRAM / JFFS / USB backup | last NVRAM backup older than 26 h, BACKUPMON errors |
| New devices | DHCP (dnsmasq) | MAC addresses never seen before | a new device joined the LAN |
| System | — | firmware (and pending MerlinAU update), uptime, load, memory, temperature, storage, files writable by anyone in /jffs | firmware changed, disk almost full, a script writable by anyone, CPU temperature (optional) |

## Requirements

- Asuswrt-Merlin with JFFS custom scripts enabled (tested on 3006; 3004 should work but is untested).
- E-mail configured in **amtm** (`amtm` → `em`). DigestMerlin uses amtm's shared e-mail library.
- Entware is recommended (its `find` is used for the world-writable check) but not required.

Tested on an RT-AX86U Pro with Merlin 3006.102.9, Skynet 9.0.5, VPNMON-R3, spdMerlin, BACKUPMON and
MerlinAU 1.7.1, with WireGuard clients. The OpenVPN checks have only been tested on a simulated router so
far: reports from OpenVPN users and other models are welcome.

## Install / update

```sh
curl -fsSL https://raw.githubusercontent.com/PierreAlex-TiTi/DigestMerlin/main/install.sh -o /tmp/dm-install.sh && sh /tmp/dm-install.sh
```

Then open the menu (option 1 previews the digest without sending anything):

```sh
sh /jffs/scripts/digestmerlin.sh
```

Running the installer again updates DigestMerlin and keeps your settings.

## Usage

Open the menu:

```sh
sh /jffs/scripts/digestmerlin.sh
```

![DigestMerlin menu](menu.png)

Everything in the menu can also be done with a command:

```sh
sh /jffs/scripts/digestmerlin.sh preview          # build and print the digest (no e-mail)
sh /jffs/scripts/digestmerlin.sh run              # build and e-mail it
sh /jffs/scripts/digestmerlin.sh section vpn      # run a single section
sh /jffs/scripts/digestmerlin.sh install 18:30    # e-mail it every day at 18:30
sh /jffs/scripts/digestmerlin.sh uninstall        # remove the schedule
```

`install` adds a cron job and one line, marked `# DigestMerlin`, to `/jffs/scripts/services-start`
so the schedule survives reboots. `uninstall` removes both.

The first `run` records the devices currently on your LAN. Devices that were offline at
that moment (a TV, a printer, a console...) are reported once when they reconnect during
the following days: a good way to review everything connected to your network.
After that, only devices never seen before are reported.

## Settings

Nothing needs to be configured: the defaults below are used until you change them.
The easiest way to change them is the menu: option 4 for the sections, option 5 for the rest.

| Setting | Menu | Default | What it does |
|---|---|---|---|
| `DISABLED_SECTIONS` | 4 | (none) | Sections left out of the digest, e.g. `"devices speedtest"`. |
| `WG_HANDSHAKE_MAX` | 5.1 | 600 | Seconds without a WireGuard handshake before a tunnel is reported as not passing traffic. |
| `SPEEDTEST_MAX_AGE_H` | 5.2 | 25 | Hours without a new spdMerlin result before alerting (a daily test plus one hour of margin). |
| `BACKUP_MAX_AGE_H` | 5.3 | 26 | Hours since the last BACKUPMON NVRAM backup before alerting. |
| `DISK_ALERT_PCT` | 5.4 | 90 | Storage use (%) of `/jffs` or the USB drive that raises an alert. |
| `CPU_TEMP_ALERT` | 5.5 | off | CPU temperature (C) that raises an alert. See below. |
| `REBOOT_MAX_DAYS` | 5.6 | off | Alert when the router has not rebooted for this many days. See below. |
| `DEVICES_IGNORE_PRIVATE_MAC` | 5.7 | 0 | `1` = do not report devices using a random "private" MAC address (phones, laptops). |
| `SUBJECT_PREFIX` | 5.8 | (none) | Text added in front of the e-mail subject. See below. |

**Why two alerts are off by default.** The temperature is always shown in the SYSTEM section,
but what is normal depends on the model: around 65C on some routers, 80C or more on others. A fixed
limit would send useless alerts to many users, so you choose it: about 10C above your usual value
is a good start. Same for reboots: many routers are never rebooted on purpose. If yours reboots on a
schedule, set the limit just above it (e.g. `8` for a weekly reboot) and the digest tells you when
a scheduled reboot did not happen.

**Subject prefix.** With `[Home]`, the subject becomes `[Home] [OK] Daily digest RT-AX86U_PRO - ...`.
Useful when you receive digests from several routers, or to sort them with an e-mail rule.
In the menu, type `none` to remove it.

**Editing by hand.** The settings live in `/jffs/addons/digestmerlin.d/digestmerlin.conf`
(created by the menu on the first change). Without the menu, create it from the sample and edit it:

```sh
cp /jffs/addons/digestmerlin.d/digestmerlin.conf.sample /jffs/addons/digestmerlin.d/digestmerlin.conf
nano /jffs/addons/digestmerlin.d/digestmerlin.conf    # or vi (nano: opkg install nano)
```

Check the effect with menu option 1 (or `sh /jffs/scripts/digestmerlin.sh preview`).
Your settings are kept when you update DigestMerlin.

## Writing a section

A section is a shell script in `/jffs/addons/digestmerlin.d/sections/`, named `NN-name.sh`
(NN sets the order). Line 2 gives its title:

```sh
#!/bin/sh
# TITLE: MY SECTION
. "$(dirname "$0")/lib.sh"

[ -f /jffs/scripts/mytool.sh ] || exit 3      # tool not installed: section skipped

echo "Something: OK"                           # text shown in the e-mail
add_alert "MyTool: something needs a look"     # goes to the ALERTS list
exit 0
```

`lib.sh` provides `read_logs` and `in_window` (syslog lines of the last 24 h), `nv` (nvram read with
a timeout), `fmt_age`, `fmt_time`, and `state_get` / `state_set` to remember a value between runs.

## Files

```
/jffs/scripts/digestmerlin.sh                main script
/jffs/addons/digestmerlin.d/sections/        one script per section
/jffs/addons/digestmerlin.d/digestmerlin.conf    your settings (optional)
/jffs/addons/digestmerlin.d/state/           values remembered between runs
```

## Uninstall

```sh
Menu option 7 removes everything (schedule, settings, history, files). Or by hand:

```sh
sh /jffs/scripts/digestmerlin.sh uninstall
rm -rf /jffs/addons/digestmerlin.d /jffs/scripts/digestmerlin.sh
```

## License

GPL-3.0. Thanks to the authors of the add-ons DigestMerlin reads, and to amtm for the shared e-mail library.

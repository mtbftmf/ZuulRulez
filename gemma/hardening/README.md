# Hardening: macOS service toggles

`macos-service-toggle.sh` disables background services a single-purpose LLM host doesn't need (Siri, Apple Intelligence, iCloud, Messages, telemetry…); `macos-service-toggle-reassert.sh` re-applies those overrides at every boot, because macOS 27 resets some of them early in boot. Used on the M5 Max canary MBP and on generic Gemma builds (runbook phase H). Read the service list before running `on`: comment out any group the host actually uses.

The scripts are user-independent: the per-user (`gui/<uid>`, `user/<uid>`) domain comes from the account that runs `sudo` (`SUDO_USER`), so on a generic build it is houdini (uid 501 on a fresh install), and the reassert re-targets to whoever is at the console. Protected and never disabled: sshd, Remote Management, Time Machine, AirPort and others in `PROTECTED_SERVICES`, plus `com.apple.watchdogd` (the system watchdog, mislabelled "Apple Watch" in an older copy) and `com.apple.rapportd` (inbound AirDrop and Universal Control).

## Install (on the host, as the admin account)

```bash
cd ~/ZuulRulez/gemma/hardening
sudo mkdir -p /usr/local/bin
sudo install -m 755 macos-service-toggle.sh macos-service-toggle-reassert.sh /usr/local/bin/
sudo install -m 644 -o root -g wheel com.macos-service-toggle.reassert.plist /Library/LaunchDaemons/
sudo /usr/local/bin/macos-service-toggle.sh on --dry-run
sudo /usr/local/bin/macos-service-toggle.sh on
sudo launchctl bootstrap system /Library/LaunchDaemons/com.macos-service-toggle.reassert.plist
sudo /usr/local/bin/macos-service-toggle.sh status
```

Undo everything this script changed: `sudo /usr/local/bin/macos-service-toggle.sh off`, then `sudo launchctl bootout system/com.macos-service-toggle.reassert`.

## Headless hosts

On a generic build nobody logs in on the desktop, so houdini's `gui/501` session domain doesn't exist and its session agents (most of the Siri and Apple Intelligence list) never start. Run over SSH, `on` therefore reports those as `[SKIP] … not found` and records only the system and `user/501` entries; that is expected, not a failure. If someone later logs in on the desktop regularly, run `on` again from a Terminal in that desktop session so the session agents get recorded too; the reassert daemon waits up to 120 s for a console user at boot and skips them otherwise. With automatic login turned on, the console session exists at every boot and the session entries are reasserted too (the M1 reports houdini on `console` a minute after boot).

## Troubleshooting

- `Bootstrap failed: 5: Input/output error`: the label is already loaded, maybe from an older plist. launchd keeps the loaded definition even after the file is overwritten, so unload it first: `sudo launchctl bootout system/com.macos-service-toggle.reassert`, then `bootstrap` again.
- `sudo launchctl print system/com.macos-service-toggle.reassert` shows `last exit code = 78: EX_CONFIG` and `job state = spawn failed`: launchd couldn't start the program. Seen on the M1 with an older plist that ran the script directly; the plist here runs it through `/bin/bash`. Reload it as above.
- No `/usr/local/var/macos-service-toggle/reassert.log`: the daemon has never run (the script writes that log on every run, even with nothing to do). Run `sudo launchctl kickstart -k system/com.macos-service-toggle.reassert` and check the log again.
- After a reboot, check: `grep 'REASSERT run:' /usr/local/var/macos-service-toggle/reassert.log | tail -2` shows a run with the new boot time, and `sudo /usr/local/bin/macos-service-toggle.sh status` shows no `DRIFTED` lines.

## Watch

`com.apple.mobileassetd` is in the list (high-risk group). Like the RemoveMacAI profile, it is part of how macOS downloads update assets. If a macOS update stalls with the profile already removed, run `sudo /usr/local/bin/macos-service-toggle.sh off`, update, then `on` again.

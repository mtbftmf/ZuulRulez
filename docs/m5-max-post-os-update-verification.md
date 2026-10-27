# M5 Max post-OS-update verification

Scope: the M5 Max Mac Studio (128 GB) and its canary, the M3 Pro MBP. The service tooling (`macos-service-toggle.sh` plus the reassert LaunchDaemon) is **not** part of the generic Gemma 4 builds for other Studios or the friends-and-family accounts.

| Machine | User (uid) | Role |
|---|---|---|
| M5 Max Mac Studio, 128 GB | ewagner (503) | Open WebUI, LM Studio, mlx-serve |
| M3 Pro 14" MBP, 18 GB | evwagner (502) | Canary: takes each macOS update first |

## Update order

1. Update the MBP first, then run the checklist below on it.
2. Take a Carbon Copy Cloner backup of the M5.
3. Update the M5 only after the MBP result is clean.

Apple silicon only lets a **volume owner** (an admin with a secure token) authorize a macOS update. ewagner (uid 503) is not the first account on the M5, so the update prompt rejects its password. Authenticate with the volume-owner account instead. To check:

```
sysadminctl -secureTokenStatus ewagner
sudo diskutil apfs listUsers /
```

## Post-update checklist

Run on each machine after the post-update reboot.

1. **Overrides held:** `sudo /usr/local/bin/macos-service-toggle.sh status`. Expect 0 `DRIFTED` and the machine's baseline count still disabled.
2. **Live processes.** `status` alone doesn't prove a service is off, so also check:
   ```
   cut -d'|' -f1 /usr/local/var/macos-service-toggle/disabled.state > /tmp/labels.txt
   launchctl list | grep -F -f /tmp/labels.txt | awk '$1 ~ /^[0-9]+$/'
   ```
3. **watchdogd enabled:** `sudo launchctl print-disabled system | grep watchdogd` should show `enabled` or nothing.
4. **GPU limit:** `iogpu.wired_limit_mb` resets to 0 on every reboot, and the reassert does not reapply it. Set it again before loading models. The M5 value is to be confirmed; 114688 (112 GB, 16 GB headroom) is proposed.
5. **Features:** AirDrop (both directions), Universal Control, ARD (both directions), sleep/wake, reboot.
6. **M5 only:** System Settings search (see the open issue below).

## Baselines

| Machine | Entries | System | Session |
|---|---|---|---|
| MBP | 62 | 10 | 52 |
| M5 | not installed | | |

The MBP was 63 before `com.apple.watchdogd` was removed (2026-10-27). The script's list has about 88 labels; labels missing on the OS build are skipped.

## MBP canary result: macOS 27.2 (Golden Gate), passed

- The reassert daemon, scripts and plist survived the update. 63 of 63 overrides held, 0 drifted (before the watchdogd fix).
- AirDrop (both directions), Universal Control, ARD (both directions), sleep/wake and reboot all worked. ARD works with `com.apple.screensharing` disabled.
- The RemoveMacAI profile was updated to the latest release before the 27.2 install. System Settings search works with it.

## Lessons

- `launchctl disable` survives reboot only because the reassert daemon reapplies it. It doesn't stop jobs that are already loaded.
- The reassert ran about 94 s after boot, after the disabled services had already started. About 40 of 52 session agents were still running (about 700 MB resident on the MBP).
- **The feature tests above prove less than they appear to.** Their dependencies (for example `identityservicesd`, `appleaccountd`, `cloudd`, `suggestd`) were mostly running, so a pass doesn't show those services can safely be stopped.
- SIP blocks `launchctl bootout` for Apple services. Don't disable SIP.
- Killing the processes doesn't stick: several restart on demand. A kill-after-disable patch was tried and reverted.
- Never disable `com.apple.rapportd`. It breaks inbound AirDrop and Universal Control.
- The reassert script replays only `disabled.state` and doesn't check `PROTECTED_SERVICES`.
- Known bug in `on`: `find_domain` uses `launchctl print`, which can't find a disabled, unloaded service. Rerunning `on` then drops that service from `disabled.state`, leaving an override `off` can't restore.

## Correction: com.apple.watchdogd (2026-10-27)

The toggle list labeled `com.apple.watchdogd` as "Apple Watch pairing/sync". It is the system watchdog, which detects userspace hangs and can force a recovery panic or reboot. That is why launchd kept restarting it. On the MBP it was:

- re-enabled with `sudo launchctl enable system/com.apple.watchdogd`
- removed from `SERVICE_DATA`
- added to `PROTECTED_SERVICES`
- removed from `disabled.state`

The pre-fix script is at `/usr/local/bin/macos-service-toggle.sh.bak`. The M5's unused copy in `~/Downloads` still has the old line.

## M5 status (2026-10-27)

- macOS 27.0.1 (26A434); 27.2 install in progress.
- No toggle or reassert daemon is installed. Recommendation: skip them on the M5. The disables only partly take effect, the saving is small on 128 GB, and the script has the bugs listed above. Keep the GPU limit and the Spotlight exclusion of the model directory.
- **Open issue:** System Settings search shows a dropdown, then empties. It's system-wide (a new test user shows it too) on a clean install (no Migration Assistant). Ruled out:
  - Spotlight index and load
  - service disables (all are also disabled on the MBP)
  - Siri.agent
  - per-user cache
  - the old RemoveMacAI release (the fault persisted after updating to the release the MBP runs)

  The remaining variable is 27.0.1 vs 27.2. Retest after the update.
- The RemoveMacAI profile matches the MBP except for `applicationaccess`, `removemacai` and a missing `com.apple.gamed`, probably a Game Center option chosen differently.

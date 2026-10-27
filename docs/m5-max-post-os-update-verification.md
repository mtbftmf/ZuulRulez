# M5 Max post-OS-update verification

Scope: the M5 Max Mac Studio (128 GB) and its canary, the M3 Pro MBP. The service tooling (`macos-service-toggle.sh` plus the reassert LaunchDaemon) is **not** part of the generic Gemma 4 builds for other Studios or the friends-and-family accounts.

| Machine | User (uid) | Role |
|---|---|---|
| M5 Max Mac Studio, 128 GB | ewagner (503) | Open WebUI, LM Studio, mlx-serve |
| M3 Pro 14" MBP, 18 GB | evwagner (502) | Canary: takes each macOS update first |

## Update order

1. Update the MBP first, then run the checklist below on it.
2. Take a Carbon Copy Cloner backup of the M5.
3. **Remove the RemoveMacAI profile** on the machine being updated (see below):
   ```
   sudo profiles remove -identifier io.github.omlahore.removemacai
   ```
4. Update the M5 only after the MBP result is clean. The command line is more reliable than System Settings and shows real progress:
   ```
   softwareupdate --list
   sudo softwareupdate --install "macOS 27.2-26B123" --restart --user mach5
   ```
   Use the label that `--list` prints.
5. After the update, reinstall the profile: `open ~/Downloads/RemoveMacAI.mobileconfig`, then approve it in System Settings › General › Device Management. Confirm with `sudo profiles list`.

### RemoveMacAI blocks macOS updates

The profile forces settings in `com.apple.MobileAsset` to stop Apple Intelligence models from downloading. That also stalls macOS updates. On the M5, the 27.2 download stopped at about 27.71% three times:

- System Settings
- `softwareupdate --install`
- the full installer (`softwareupdate --fetch-full-installer`)

A reboot didn't help. With the profile removed, the download passed that point straight away and the install completed.

The MBP's update worked with the profile installed only because the MBP got the profile about 40 minutes before its update. 27.2 had most likely already been downloaded in the background. Expect the MBP's next update to stall the same way.

### Volume owner

Apple silicon only lets a **volume owner** (an admin with a secure token) authorize a macOS update. On the M5 that is **mach5**. ewagner (uid 503) has no secure token, so the update prompt rejects its password. To check:

```
sysadminctl -secureTokenStatus ewagner
sudo diskutil apfs listUsers /
```

## Post-update checklist

Run on each machine after the post-update reboot.

1. **Reboot the other Mac too.** After the M5's update, AirDrop from the MBP to the Studio stuck at "Waiting". The Studio's `sharingd` logged `Unable to decrypt activity level … error -6727` for the MBP: the MBP still held a stale Continuity key. Turning Handoff off and on, and Bluetooth and Wi-Fi off and on, didn't fix it. Rebooting the MBP did.
2. **Overrides held** (toggle machines only): `sudo /usr/local/bin/macos-service-toggle.sh status`. Expect 0 `DRIFTED` and the machine's baseline count still disabled.
3. **Live processes.** `status` alone doesn't prove a service is off, so also check:
   ```
   cut -d'|' -f1 /usr/local/var/macos-service-toggle/disabled.state > /tmp/labels.txt
   launchctl list | grep -F -f /tmp/labels.txt | awk '$1 ~ /^[0-9]+$/'
   ```
4. **watchdogd enabled:** `sudo launchctl print-disabled system | grep watchdogd` should show `enabled` or nothing.
5. **GPU limit:** `iogpu.wired_limit_mb` resets to 0 on every reboot, and the reassert does not reapply it. Set it again before loading models. The M5 uses 114688 (112 GB, 16 GB headroom):
   ```
   sudo sysctl iogpu.wired_limit_mb=114688
   ```
6. **Profile reinstalled:** `sudo profiles list` shows `io.github.omlahore.removemacai`.
7. **Features:** AirDrop (both directions), Universal Control, ARD (both directions), sleep/wake, reboot.

## Baselines

| Machine | Entries | System | Session |
|---|---|---|---|
| MBP | 62 | 10 | 52 |
| M5 | not installed | | |

The MBP was 63 before `com.apple.watchdogd` was removed (2026-10-27). The script's list has about 88 labels; labels missing on the OS build are skipped.

## MBP canary result: macOS 27.2 (Golden Gate), passed

- The reassert daemon, scripts and plist survived the update. 63 of 63 overrides held, 0 drifted (before the watchdogd fix).
- AirDrop (both directions), Universal Control, ARD (both directions), sleep/wake and reboot all worked. ARD works with `com.apple.screensharing` disabled.
- The latest RemoveMacAI release was installed about 40 minutes before the 27.2 install. System Settings search works with it on the MBP.

## M5 result: macOS 27.2 (26B123), installed 2026-10-27

- The update needed the profile removed and the volume-owner account (mach5). See Update order.
- GPU limit set to 114688.
- AirDrop: Studio to MBP worked. MBP to Studio worked after rebooting the MBP (checklist step 1).
- Universal Control and ARD: **not yet tested** after the update. Universal Control worked the night before, but that was before the update and the key refresh.
- The RemoveMacAI profile was reinstalled after the update.
- The toggle and reassert daemon are not installed. Recommendation: skip them on the M5. The disables only partly take effect, the saving is small on 128 GB, and the script has the bugs listed under Lessons. Keep the GPU limit and the Spotlight exclusion of the model directory.

## Open issue: System Settings search broken on the M5

The search bar shows a dropdown, then empties, and no query returns results. Cmd-Space can still open Settings panes. The fault is system-wide (a new test user shows it too), and the M5 was a clean install (no Migration Assistant).

Ruled out:
- Spotlight index and load
- service disables (all are also disabled on the MBP)
- Siri.agent
- per-user cache
- the old RemoveMacAI release
- 27.0.1: it persists on 27.2
- the profile being installed: it persists with the profile removed

**Lead:** `/System/Library/AssetsV2/com_apple_MobileAsset_LinguisticData` exists on the MBP but not on the M5. The M5 has had the profile since Oct 5, which probably kept this asset from downloading. With the profile removed, neither searching nor `sudo killall mobileassetd` made it download right away. The profile was reinstalled, so the asset will likely stay missing.

To try again: remove the profile, leave it off for a day, and check:

```
ls /System/Library/AssetsV2 | grep -i linguistic
```

Then test search. Apple Intelligence models may download while the profile is off.

## Lessons

- `launchctl disable` survives reboot only because the reassert daemon reapplies it. It doesn't stop jobs that are already loaded.
- The reassert ran about 94 s after boot, after the disabled services had already started. About 40 of 52 session agents were still running (about 700 MB resident on the MBP).
- **The feature tests above prove less than they appear to.** Their dependencies (for example `identityservicesd`, `appleaccountd`, `cloudd`, `suggestd`) were mostly running, so a pass doesn't show those services can safely be stopped.
- SIP blocks `launchctl bootout` for Apple services. Don't disable SIP.
- Killing the processes doesn't stick: several restart on demand. A kill-after-disable patch was tried and reverted.
- Never disable `com.apple.rapportd`. It breaks inbound AirDrop and Universal Control.
- The reassert script replays only `disabled.state` and doesn't check `PROTECTED_SERVICES`.
- Known bug in `on`: `find_domain` uses `launchctl print`, which can't find a disabled, unloaded service. Rerunning `on` then drops that service from `disabled.state`, leaving an override `off` can't restore.
- A profile that blocks MobileAsset blocks more than AI models: it can block macOS updates and system assets that other features rely on.
- When comparing two Macs, check when each one got the change (`installationDate` in `sudo profiles show -type configuration`). The MBP looked like it proved the profile harmless, but it had only had the profile for 40 minutes.

## Correction: com.apple.watchdogd (2026-10-27)

The toggle list labeled `com.apple.watchdogd` as "Apple Watch pairing/sync". It is the system watchdog, which detects userspace hangs and can force a recovery panic or reboot. That is why launchd kept restarting it. On the MBP it was:

- re-enabled with `sudo launchctl enable system/com.apple.watchdogd`
- removed from `SERVICE_DATA`
- added to `PROTECTED_SERVICES`
- removed from `disabled.state`

The pre-fix script is at `/usr/local/bin/macos-service-toggle.sh.bak`. The M5's unused copy in `~/Downloads` still has the old line.

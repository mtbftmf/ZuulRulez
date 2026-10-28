# Rebuild runbook: Mac Studio → macOS Golden Gate + generic Gemma 4 build

Written for the first host (Mac Studio M1 Max, 32 GB, coming from macOS Tahoe 26) and reusable for any M-series Studio. Everything runs from the 14" MBP over SSH or Screen Sharing except **one visit to the machine** (Setup Assistant, ~15 minutes): an erased Mac has no account and no sharing turned on, and Setup Assistant can't be screen-shared.

Why upgrade first, then erase: Erase All Content and Settings (EACS) wipes every account and file but keeps the installed macOS. Upgrading to Golden Gate while the Mac is still reachable means the erased Mac comes back on Golden Gate, with no Recovery or USB install (Recovery can't be screen-shared either).

| Phase | Where | Time |
| --- | --- | --- |
| A. Preflight and upgrade to Golden Gate | MBP → SSH | 45-75 min, mostly download |
| B. Erase All Content and Settings | MBP → Screen Sharing | 5 min |
| C. Setup Assistant, turn on sharing | **At the machine** | 15 min |
| D. Bootstrap | MBP → SSH | 10 min |
| E. Install the stack | MBP → SSH + Screen Sharing | 30 min, mostly downloads |
| F. Open WebUI setup | MBP → browser | 15 min |
| G. Verify, benchmark, reboot test, record | MBP → SSH | 15 min |

The scripts are fetched from GitHub, so push the repo before starting.

## Before you start (MBP Terminal)

Set the Studio's address once per Terminal window. Use its `.local` name, or its Ethernet IP if the MBP is on the other subnet (Bonjour doesn't cross it). Set `OLDADMIN` to the admin account on the current Tahoe install.

```bash
export STUDIO=M1-Studio.local
export OLDADMIN=admin
```

## A. Preflight and upgrade (SSH, old system)

```bash
ssh "$OLDADMIN@$STUDIO"
```

On the Studio:

```bash
curl -fsSL https://raw.githubusercontent.com/mtbftmf/ZuulRulez/MacLLM/gemma/rebuild/00-preflight.sh -o ~/00-preflight.sh
curl -fsSL https://raw.githubusercontent.com/mtbftmf/ZuulRulez/MacLLM/gemma/rebuild/10-upgrade-os.sh -o ~/10-upgrade-os.sh
bash ~/00-preflight.sh
```

Fix every WARN that matters before going on:

- RemoveMacAI profile present: remove it (it stalls macOS downloads; see `docs/m5-max-post-os-update-verification.md`).
- `$OLDADMIN` has no secure token: use an account that has one as `VOLUME_OWNER`.
- Not on Ethernet: plug it in. Activation after the erase and FileVault unlock over SSH both want a wired link.
- Nothing on port 5900: turn on Remote Management now (needed for step B).

Then upgrade:

```bash
bash ~/10-upgrade-os.sh
```

The session drops when the Mac restarts. Wait 20-40 minutes. If FileVault is on, the Mac waits at the unlock screen: `ssh "$OLDADMIN@$STUDIO"` and enter the password to finish the boot (macOS 26 and later). Then confirm:

```bash
ssh "$OLDADMIN@$STUDIO" sw_vers
```

`ProductVersion` must start with 27. Run `bash ~/10-upgrade-os.sh` again if a newer 27.x point update is listed.

## B. Erase All Content and Settings (Screen Sharing)

1. Open Screen Sharing to the Studio and log in as `$OLDADMIN`.
2. System Settings → General → Transfer or Reset → **Erase All Content and Settings**.
3. Enter the admin password. If Find My is on, enter the Apple Account password: this signs out and removes Activation Lock.
4. Confirm. The connection drops and the Mac erases and restarts (a few minutes).

On the MBP, forget the old SSH host key, or the next login is refused:

```bash
ssh-keygen -R "$STUDIO"
```

## C. At the machine (the one visit)

Bring a display, a USB keyboard and a mouse (Bluetooth devices may need a cable to pair on an erased Mac).

1. **Activate Mac** over Ethernet.
2. Language, region; Migration Assistant → **Not Now**.
3. Apple Account → **Set Up Later** (a hosting box doesn't need one; it can be added later).
4. Create the account: Full name `houdini`, account name `houdini`, strong password. This first account is the admin and the volume owner.
5. FileVault: **on** (recommended; family chats live on this disk). With no Apple Account, macOS shows a recovery key: write it down and store it offline.
6. Location, analytics, Screen Time, Siri, Apple Intelligence: your choice; none are needed.
7. At the desktop, System Settings → General → Sharing:
   - **Remote Management** on → Options: turn on all → Allow access for: Only these users → houdini.
   - **Remote Login** on → Allow access for: houdini.
   - Local hostname → Edit → `M1-Studio` (optional; the bootstrap can set it too).
8. System Settings → Network → Ethernet: note the IP and make a DHCP reservation for it on the router.
9. Leave houdini logged in. Head back upstairs.

## D. Bootstrap (SSH as houdini)

```bash
ssh "houdini@$STUDIO"
```

On the Studio:

```bash
curl -fsSL https://raw.githubusercontent.com/mtbftmf/ZuulRulez/MacLLM/gemma/rebuild/30-bootstrap.sh -o ~/30-bootstrap.sh
MAC_NAME=M1-Studio bash ~/30-bootstrap.sh
```

This installs the Command Line Tools and Homebrew without dialogs, `brew install git gh jq`, clones the repo to `~/ZuulRulez` on MacLLM, sets the Pdl_Pwr commit identity for the repo, sets `pmset` (no sleep, wake on LAN, restart after power failure) and adds `setopt interactivecomments`.

Only if this Mac should push to GitHub itself: `gh auth login` (HTTPS, browser; open the URL and code on the MBP).

## E. Install the stack (SSH + Screen Sharing)

Open Screen Sharing to the Studio (log in as houdini) and keep it beside the SSH window. In SSH:

```bash
exec zsh -l
~/ZuulRulez/gemma/bin/install-gemma-stack.sh
```

When it says so, click through LM Studio's first-run screens in the Screen Sharing window (skip its model download). The script then downloads Gemma (Q4_0), installs Open WebUI, the daemon, the login item and the `~/bin` links.

Then in LM Studio (Screen Sharing):

- Developer → Server Settings: **Just-in-Time Model Loading off**, and any option that loads the last-used model at startup off (it would race the login item).
- My Models → gemma-4-26b-a4b-it-qat → gear: GPU offload max, context 16384, Try mmap() on.

Back in SSH:

```bash
~/bin/gemma-up.sh
```

## F. Open WebUI (MBP browser)

Open `http://M1-Studio.local:8080` (or the IP). **The first account created becomes the admin**: create houdini's account.

1. Admin Panel → Settings → Connections: OpenAI API lists `http://localhost:1234/v1`, no prefix, empty Model IDs; Ollama off. Leave Direct Connections empty.
2. Admin Panel → Settings → Interface: local and external Task Model = `gemma-4-26b-a4b-it-qat`.
3. Admin Panel → Settings → Models → gemma-4-26b-a4b-it-qat → Advanced Params: temperature 1.0, top_p 0.95, top_k 64.
4. Admin Panel → Settings → General: sign-ups on, default role **pending** (you approve each friend or family member under Admin Panel → Users).
5. Settings → Personalization → Memory: add the memories in `owui-memories.md`. Keep them short: every message carries them, and context is 16K here.
6. Optional: the AI Admin assistant from the original handoff (Knowledge from `~/ai-handoff`, system prompt in that doc), and the Gemma personas exported from the M5 (Workspace → Models → Export there, Import here; then fix the hardware line in each system prompt).

## G. Verify, benchmark, reboot test, record (SSH)

```bash
~/ZuulRulez/gemma/rebuild/40-verify.sh
python3 ~/bin/llm-bench.py --model gemma-4-26b-a4b-it-qat --label m1max-32
```

Reboot test:

```bash
sudo reboot
```

After a minute: `ssh "houdini@$STUDIO"` (unlocks FileVault), then Screen Sharing → log in as houdini, wait a minute, and run `40-verify.sh` again. It should pass with no manual `gemma-up.sh`.

Record the result: one CHANGELOG line (date, what changed, why, measured tok/s and verify result), one commit:

```bash
cd ~/ZuulRulez && git pull
git add -A && git commit -m "gemma: M1 Max rebuilt on Golden Gate, measured" && git push
```

## If something goes wrong

| Symptom | Fix |
| --- | --- |
| Upgrade download stalls at the same percentage | RemoveMacAI or another MobileAsset profile: `sudo profiles list`, remove it, retry |
| `softwareupdate` rejects the password | Account has no secure token: `VOLUME_OWNER=` an account that has one |
| No Golden Gate label in the list | `softwareupdate --fetch-full-installer`, then run the installer app over Screen Sharing |
| SSH refused after the erase | `ssh-keygen -R "$STUDIO"`; Remote Login on (step C7) |
| Screen Sharing refused | Remote Management on and houdini allowed (step C7) |
| Command Line Tools not listed | Run `xcode-select --install` in Terminal over Screen Sharing, then re-run the bootstrap |
| Installer waits on LM Studio | Finish its first-run screens in Screen Sharing; houdini must be logged in on the desktop |
| Gemma not loaded after reboot | houdini not logged in on the desktop yet; `tail ~/Library/Logs/gemma-up.log` |
| Other problems | The troubleshooting table in the original M1 handoff doc applies unchanged |

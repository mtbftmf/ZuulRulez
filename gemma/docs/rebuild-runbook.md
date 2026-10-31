# Rebuild runbook: Mac Studio → macOS Golden Gate + generic Gemma 4 build

Written for the first host (Mac Studio M1 Max, 32 GB, coming from macOS Tahoe 26) and reusable for any M-series Studio. Everything runs from the 14" MBP over SSH (Screen Sharing only for the erase) except **one visit to the machine** (Setup Assistant, ~15 minutes): an erased Mac has no account and no sharing turned on, and Setup Assistant can't be screen-shared.

Why upgrade first, then erase: Erase All Content and Settings (EACS) wipes every account and file but keeps the installed macOS. Upgrading to Golden Gate while the Mac is still reachable means the erased Mac comes back on Golden Gate, with no Recovery or USB install (Recovery can't be screen-shared either).

| Phase | Where | Time |
| --- | --- | --- |
| A. Preflight and upgrade to Golden Gate | MBP → SSH | 45-75 min, mostly download |
| B. Erase All Content and Settings | MBP → Screen Sharing | 5 min |
| C. Setup Assistant, turn on sharing | **At the machine** | 15 min |
| D. Bootstrap | MBP → SSH | 10 min |
| E. Install the stack | MBP → SSH | 30 min, mostly downloads |
| F. Open WebUI setup | MBP → browser | 15 min |
| G. Verify, benchmark, reboot test, record | MBP → SSH | 15 min |

The scripts are fetched from GitHub, so push the repo before starting.

## Before you start (MBP Terminal)

Set the Studio's address once per Terminal window. Use its `.local` name, or its Ethernet IP if the MBP is on the other subnet (Bonjour doesn't cross it). Set `OLDADMIN` to the admin account on the current Tahoe install.

```bash
export STUDIO=M1-Studio.local
export OLDADMIN=admin
```

## A0. Inventory before anything (SSH, both Studios)

Capture what is on the Mac before it's wiped, and compare it with another Studio. Read-only. On each Mac, logged in over SSH as an admin:

```bash
curl -fsSL https://raw.githubusercontent.com/mtbftmf/ZuulRulez/MacLLM/gemma/rebuild/05-inventory.sh -o ~/05-inventory.sh
bash ~/05-inventory.sh
```

It snapshots the account with UID 503 by default (`INV_USER=` for another). Over SSH, privacy-protected folders (Mail, Messages, Safari data) are skipped unless Remote Login's "Allow full disk access for remote users" is on; `errors.txt` counts them. Then on the MBP, copy both folders over and compare:

```bash
mkdir -p ~/inventories && cd ~/inventories
scp -r "$OLDADMIN@$STUDIO:inventory-*" .
curl -fsSL https://raw.githubusercontent.com/mtbftmf/ZuulRulez/MacLLM/gemma/rebuild/06-inventory-diff.py -o 06-inventory-diff.py
python3 06-inventory-diff.py inventory-M1-Studio-* inventory-M5-Studio-*
```

Use the M5's address for the second `scp`. Read `report.md`; `only-in-A.tsv` lists every file that exists only on the first Mac, which is what the erase would lose. Copy off anything worth keeping before step B.

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

- RemoveMacAI profile present: `10-upgrade-os.sh` offers to remove it (it stalls macOS downloads; see `docs/m5-max-post-os-update-verification.md`).
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
5. FileVault: **off** (choose not to turn it on). Generic builds come back unattended after power cuts; see "After a power failure" in `gemma/README.md` for the trade-off and how to turn it on later.
6. Location, analytics, Screen Time, Siri, Apple Intelligence: your choice; none are needed.
7. At the desktop, System Settings → General → Sharing:
   - **Remote Management** on → Options: turn on all → Allow access for: Only these users → houdini.
   - **Remote Login** on → Allow access for: houdini.
   - Local hostname → Edit → `M1-Studio` (optional; the bootstrap can set it too).
8. System Settings → Network → Ethernet: note the IP and make a DHCP reservation for it on the router.
9. Log out or leave it at the desktop; nothing needs a desktop session from here on. Head back upstairs.

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

## E. Install the stack (SSH)

Everything from here is command line. In the SSH session:

```bash
exec zsh -l
~/ZuulRulez/gemma/bin/install-gemma-stack.sh
```

It installs llama.cpp, downloads the Gemma GGUF and its vision projector (~16 GB), installs Open WebUI, writes and loads both LaunchDaemons (`com.gemma.llm`, `com.openwebui.serve`), links `~/bin`, then waits until the model answers.

To try MLX as well (adds ~16 GB, switches the daemon to it):

```bash
ENGINE=mlx ~/ZuulRulez/gemma/bin/install-gemma-stack.sh
```

Switch back the same way with `ENGINE=llamacpp`. Decide which one stays before step F, since Open WebUI personas are tied to the model id.

## F. Open WebUI (MBP browser)

Open `http://M1-Studio.local:8080` (or the IP). **The first account created becomes the admin**: create houdini's account.

1. Admin Panel → Settings → Connections: OpenAI API lists `http://127.0.0.1:1234/v1`, no prefix, empty Model IDs; Ollama off. Leave Direct Connections empty.
2. Admin Panel → Settings → Interface: local and external Task Model = the model id the installer printed (`gemma-4-26b-a4b-it-qat` on llama.cpp).
3. Admin Panel → Settings → Models → the Gemma model → Advanced Params: temperature 1.0, top_p 0.95, top_k 64.
4. Admin Panel → Settings → General: sign-ups on, default role **pending** (you approve each friend or family member under Admin Panel → Users).
5. Settings → Personalization → Memory: add the memories in `owui-memories.md`. Keep them short: every message carries them, and context is 16K here.
6. Optional: the AI Admin assistant from the original handoff (Knowledge from `~/ai-handoff`, system prompt in that doc), and the Gemma personas exported from the M5 (Workspace → Models → Export there, Import here; then fix the hardware line in each system prompt).

## G. Verify, benchmark, reboot test, record (SSH)

```bash
~/ZuulRulez/gemma/rebuild/40-verify.sh
python3 ~/bin/llm-bench.py --model gemma-4-26b-a4b-it-qat --label llamacpp
```

If MLX was installed too, benchmark it the same way and keep the faster one:

```bash
ENGINE=mlx ~/ZuulRulez/gemma/bin/install-gemma-stack.sh
python3 ~/bin/llm-bench.py --model mlx-community/gemma-4-26B-A4B-it-qat-4bit --label mlx
```

Reboot test:

```bash
sudo reboot
```

After a minute, `ssh "houdini@$STUDIO"`, check `uptime`, and run `40-verify.sh` again. It should pass with nobody logged in on the desktop (M1: within a minute of the restart). Only if FileVault was turned on does the first SSH login unlock the disk instead.

Record the result: one CHANGELOG line (date, what changed, why, measured tok/s and verify result), one commit:

```bash
cd ~/ZuulRulez && git pull
git add -A && git commit -m "gemma: M1 Max rebuilt on Golden Gate, measured" && git push
```

## H. Hardening: RemoveMacAI and service toggles (after G)

Same as on the M5 and MBP, because turning Siri and Apple Intelligence off in Settings did not stick. Only after G passes, so any later problem can be told apart from a build problem. Fetch the helper and take a baseline a few minutes after a reboot, with the model loaded:

```bash
bash ~/ZuulRulez/gemma/rebuild/50-harden.sh snapshot before
```

1. **RemoveMacAI.** Download the latest release from omlahore.github.io/RemoveMacAI to `~/Downloads/RemoveMacAI.mobileconfig` on the Studio, then:
   ```bash
   bash ~/ZuulRulez/gemma/rebuild/50-harden.sh profile
   ```
   Approve it over Screen Sharing: System Settings → General → Device Management.
2. **Service toggles.** Install from the repo copy in `gemma/hardening/` (README there: install, dry run, `on`, reassert daemon, undo). It protects com.apple.watchdogd and com.apple.rapportd and works for any account. Over SSH on a headless host, session-agent entries report `[SKIP]`; that is expected.
3. Reboot, unlock over SSH, wait a few minutes, then:
   ```bash
   bash ~/ZuulRulez/gemma/rebuild/50-harden.sh snapshot after
   bash ~/ZuulRulez/gemma/rebuild/50-harden.sh compare
   bash ~/ZuulRulez/gemma/rebuild/50-harden.sh status
   ~/ZuulRulez/gemma/rebuild/40-verify.sh
   ```
4. One CHANGELOG line with the compare result (RSS, swap, process count) and the verify result.

**macOS updates from now on:** `10-upgrade-os.sh` removes RemoveMacAI on request before updating; afterwards `50-harden.sh profile` puts it back, then `50-harden.sh status` and the post-update checklist in `docs/m5-max-post-os-update-verification.md` (overrides held, watchdogd enabled, rapportd untouched).

## If something goes wrong

| Symptom | Fix |
| --- | --- |
| Upgrade download stalls at the same percentage | RemoveMacAI or another MobileAsset profile: `sudo profiles list`, remove it, retry |
| `softwareupdate` rejects the password | Account has no secure token: `VOLUME_OWNER=` an account that has one |
| No Golden Gate label in the list | `softwareupdate --fetch-full-installer`, then run the installer app over Screen Sharing |
| SSH refused after the erase | `ssh-keygen -R "$STUDIO"`; Remote Login on (step C7) |
| Screen Sharing refused | Remote Management on and houdini allowed (step C7) |
| Command Line Tools not listed | Run `xcode-select --install` in Terminal over Screen Sharing, then re-run the bootstrap |
| Model server not ready | `tail -50 ~/Library/Logs/gemma-llm.log`; run `~/ZuulRulez/gemma/bin/gemma-serve.sh` by hand after `STOP_OWUI=0 ~/bin/gemma-down.sh` to watch it start |
| Out of memory or swapping | Lower `CTX` or `NP` in `~/.config/gemma.env`, then `RESTART=1 ~/bin/gemma-up.sh` |
| Nothing after a power failure | Wait two minutes and ping it; if FileVault was turned on, it is waiting: `ssh "houdini@$STUDIO"` and enter the password |
| Open WebUI problems | The Open WebUI rows of the original M1 handoff doc still apply; its LM Studio rows don't |

# Handoff: this Mac Studio (paste as the first chat, signed in as houdini)

You are running on the Mac described below, and I am its new owner and admin. Treat this message as the reference for the machine. Reply with a short summary of the first three things I should do, then answer my later questions in this chat from what is written here; if something isn't covered, say so rather than guessing.

## 1. What it is
- Mac Studio M1 Max (10 CPU / 24 GPU cores), 32 GB unified memory, macOS Golden Gate 27.2, Ethernet. Host name `M1-Studio` (`M1-Studio.local` on the same subnet).
- A private chat AI for friends and family on the LAN: Open WebUI in the browser on port 8080, backed by one local model, Gemma 4 26B-A4B (QAT, 4-bit, text and images). Nothing is exposed to the internet: no port forwarding, no TLS.
- One macOS account, `houdini`: admin, volume owner (authorizes macOS updates), runs both services, and is also the Open WebUI admin. No other accounts.
- Everything is command line over SSH. No desktop app is involved and nobody needs to log in on the desktop.

## 2. How it fits together
| Piece | Detail |
| --- | --- |
| Model server | LaunchDaemon `com.gemma.llm` (runs `~/ZuulRulez/gemma/bin/gemma-serve.sh` as houdini at boot). Homebrew `llama-server` (llama.cpp 0.8.0), GGUF Q4_0 plus vision projector, model id `gemma-4-26b-a4b-it-qat`. Listens on 127.0.0.1:1234 only, OpenAI API at `/v1`. 16K context, 2 requests at once. Log `~/Library/Logs/gemma-llm.log` |
| Open WebUI | LaunchDaemon `com.openwebui.serve`, version 0.12.5, venv `~/open-webui-venv`, data `~/open-webui-data`, on 0.0.0.0:8080. Log `~/Library/Logs/open-webui.log` |
| Settings | `~/.config/gemma.env` (ENGINE, CTX, NP, PORT, OWUI_PORT). Edit this, never the plists; the installer writes the plists |
| Weights | `~/models/llama.cpp` (about 16 GB; can always be downloaded again) |
| Scripts and docs | `~/ZuulRulez/gemma/` (README, `bin/`, `rebuild/`, `hardening/`, `docs/`); `~/bin` holds links into it; `~/ai-handoff` is an offline copy of the docs |
| Other ports | 22 (SSH), 5900 (Screen Sharing) |

Linux equivalents: `systemctl` → `sudo launchctl print|kickstart -k system/<label>`; unit files → `/Library/LaunchDaemons/*.plist`; `journalctl` → the log files above; `apt` → `brew`; `ss -ltnp` → `lsof -nP -iTCP -sTCP:LISTEN`; `free` → `memory_pressure`, `vm_stat`. BSD userland: `sed -i ''`.

## 3. Daily operation
| Task | Command |
| --- | --- |
| Health check (exit code = failures) | `~/ZuulRulez/gemma/rebuild/40-verify.sh` |
| Start whatever is stopped, wait until ready | `~/bin/gemma-up.sh` |
| Apply a `gemma.env` change | `RESTART=1 ~/bin/gemma-up.sh` |
| Stop both (frees ~17 GB) | `~/bin/gemma-down.sh` |
| Re-check or repair the install (safe to repeat) | `~/ZuulRulez/gemma/bin/install-gemma-stack.sh` |
| Upgrade llama.cpp | `brew upgrade llama.cpp`, then `RESTART=1 ~/bin/gemma-up.sh` |
| Upgrade Open WebUI (backup first, can roll back) | `~/bin/owui-upgrade.sh` |
| Benchmark | `python3 ~/bin/llm-bench.py --model gemma-4-26b-a4b-it-qat --label llamacpp` |
| Logs | `tail -f ~/Library/Logs/gemma-llm.log ~/Library/Logs/open-webui.log` |

Measured on this Mac: about 68 tok/s generating, about 390 tok/s reading prompts (a 7,800-token prompt takes ~20 s before the first word), first word on a short prompt in ~0.3 s. Memory: about 17 GB wired with the model loaded, no swap.

## 4. Open WebUI as set up
- The OpenAI connection points at `http://127.0.0.1:1234/v1`; the Ollama API is off.
- Task Model (titles, tags) = `gemma-4-26b-a4b-it-qat`. Model parameters: temperature 1.0, top_p 0.95, top_k 64.
- Sign-ups are on and new users start as **pending**: approve them under Admin Panel → Users. Every approved user sees the model, because the daemon sets `BYPASS_MODEL_ACCESS_CONTROL=true`.
- Thinking is left at the chat template default (on): better answers on hard questions, but slower, and the reasoning uses some of the 16K context.
- Three memories describe the build. Every message carries them, so keep any you add short.
- Web search and tools are **not** configured; they're yours to decide (see section 9).

## 5. Power, boot and security
- FileVault is **off** by the previous owner's choice, so the Mac comes back by itself after a power cut (`pmset autorestart 1`). Both daemons start with nobody logged in, and everything answers about a minute after power-on.
- Automatic login is off. Trade-off: the disk isn't encrypted, so keep the Mac somewhere private. To encrypt later: `sudo fdesetup enable -user houdini` and keep the recovery key it prints. After that, every reboot waits until someone runs `ssh houdini@` the Mac and enters the password.
- The model server only listens on localhost. Open WebUI, SSH and Screen Sharing are LAN-facing.

## 6. Hardening (Siri, Apple Intelligence, background services)
- **RemoveMacAI** configuration profile: installed. Check it with `bash ~/ZuulRulez/gemma/rebuild/50-harden.sh status`. Turning Siri and Apple Intelligence off in Settings did not stick, which is why the profile is used.
- **Service toggles**: `/usr/local/bin/macos-service-toggle.sh` disabled 63 background services (Siri, Apple Intelligence, iCloud, Messages, analytics and others). Its state is in `/usr/local/var/macos-service-toggle/`. A boot daemon, `com.macos-service-toggle.reassert`, re-applies the disables at every boot, because macOS 27 resets some of them early in boot. The log is `reassert.log` in that folder.
  - Check: `sudo /usr/local/bin/macos-service-toggle.sh status`. System services should show `[still disabled]` and none should show `DRIFTED`. Per-user (`gui/501`) entries show `[unknown/not found]` when nobody is logged in on the desktop; that is normal.
  - Undo everything: `sudo /usr/local/bin/macos-service-toggle.sh off`, then `sudo launchctl bootout system/com.macos-service-toggle.reassert`.
  - Never disabled: sshd, Remote Management, Time Machine, `com.apple.watchdogd` (the system watchdog) and `com.apple.rapportd`.
  - Details and troubleshooting: `~/ZuulRulez/gemma/hardening/README.md`.

## 7. macOS updates (order matters)
1. `bash ~/ZuulRulez/gemma/rebuild/10-upgrade-os.sh` over SSH. It offers to remove RemoveMacAI first (the profile stalls downloads) and asks for houdini's password.
2. After the update: `bash ~/ZuulRulez/gemma/rebuild/50-harden.sh profile` reinstalls the profile. `40-verify.sh` fails until you do.
3. If a download stalls even with the profile removed, `com.apple.mobileassetd` is the suspect. Run `sudo /usr/local/bin/macos-service-toggle.sh off`, update, then run `on` again.
4. Finish with `40-verify.sh`.

## 8. Backups
- `~/open-webui-data` is everyone's accounts and chats, and the only thing that can't be recreated. `owui-upgrade.sh` writes a verified backup to `~/owui-backups` (keeps 5) before every upgrade.
- For a manual backup: `~/bin/gemma-down.sh`, copy `~/open-webui-data` (tar or rsync to another machine or disk), then `~/bin/gemma-up.sh`.
- The backup includes `~/open-webui-data/.webui_secret_key`; keep it with the data, or logins won't survive a restore. Also worth keeping: `~/.config/gemma.env`.

## 9. Your decisions (left open on purpose)
- [ ] Change houdini's macOS password (System Settings → Users & Groups, over Screen Sharing). Change the Open WebUI admin password too (Settings → Account).
- [ ] Add your SSH key: `ssh-copy-id houdini@M1-Studio.local` (or its IP). Then consider turning off password logins for SSH.
- [ ] Reserve the Mac's IP address in your router (DHCP). Nothing on the Mac depends on the address.
- [ ] Web search: Admin Panel → Settings → Web Search. DuckDuckGo needs no key; Brave and Tavily need one; SearXNG can be self-hosted. Each search adds its results to the prompt, roughly 13 s of extra wait per 5,000 tokens.
- [ ] Tools (local folders, GitHub and others): Python tools under Workspace → Tools, or OpenAPI/MCP tool servers in the admin settings. Tools run as houdini, so limit a folder tool to one dedicated folder, give a GitHub token read-only access to just the repos it needs, and decide whether family members get tools. Check that a tool actually gets called before relying on it.
- [ ] Decide on backups (section 8) and whether to encrypt the disk (section 5).

## 10. Keeping your own notes and scripts (Git not required)
- `~/ZuulRulez` is just a folder to you. Don't move or rename it: the model daemon, the `~/bin` links and `40-verify.sh` all point into it.
- Keep your own notes and scripts in a separate folder, for example `~/admin/`. Then nothing you write collides with the build's files. Put machine settings in `~/.config/gemma.env`, not in the scripts.
- A dated snapshot of everything that matters: `tar czf ~/admin/snapshot-$(date +%F).tgz -C ~ ZuulRulez .config/gemma.env admin` (leave out `open-webui-data` unless you want chats in it).
- Git is installed if you ever want history. `git -C ~/ZuulRulez status` lists any file you changed in the build folder, and `git -C ~/ZuulRulez diff` shows how.

## 11. Don'ts
- Don't run the top-level `~/ZuulRulez/install.sh`. It belongs to a different machine.
- Don't edit the plists in `/Library/LaunchDaemons`. Edit `gemma.env` and re-run the installer.
- Don't put API keys or tokens in `~/ZuulRulez`. Keep them in Open WebUI or `~/.config`.
- Don't disable `com.apple.watchdogd`.

## 12. If something's wrong
- Start with `40-verify.sh`. It names the failing piece.
- Model not answering: `tail -50 ~/Library/Logs/gemma-llm.log`, then `RESTART=1 ~/bin/gemma-up.sh`.
- Web page down: `tail -50 ~/Library/Logs/open-webui.log`, then `sudo launchctl kickstart -k system/com.openwebui.serve`.
- Slow or swapping (`sysctl vm.swapusage`): lower `CTX` (for example 8192) or set `NP=1` in `gemma.env`, then `RESTART=1 ~/bin/gemma-up.sh`.
- An approved user sees no model: check that `BYPASS_MODEL_ACCESS_CONTROL` is `true` in `/Library/LaunchDaemons/com.openwebui.serve.plist`; re-running the installer restores it.
- Hardening drift after a reboot: see the Troubleshooting section of `gemma/hardening/README.md`.

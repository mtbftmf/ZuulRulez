# Generic Gemma 4 builds (friends-and-family hosts)

Scripted, single-model local LLM builds for M-series Mac Studios that host Open WebUI on the LAN for friends and family. Everything in this folder is generic: no host names, addresses or personal paths. The M5 Max stack (`m5/`, Flash-Next, mlx-serve, Auto Router, Caddy, RAID, service toggles, RemoveMacAI, GPU wired-limit tuning) is **not** part of these builds.

## What a build looks like

| Component | Setting |
| --- | --- |
| Hardware | Any Apple Silicon Mac Studio with 32 GB or more. First host: Mac Studio M1 Max (10 CPU / 24 GPU), 32 GB |
| OS | macOS Golden Gate 27.x, erased with Erase All Content and Settings, Ethernet |
| Account | `houdini`: the only macOS account, admin, volume owner (authorizes updates), runs the whole stack |
| Engine | LM Studio, server on `localhost:1234` only, JIT loading off |
| Model | `gemma-4-26b-a4b-it-qat` (Q4_0 GGUF from `lmstudio-community/gemma-4-26B-A4B-it-QAT-GGUF`), text and vision |
| Context | 16384 on 32 GB, 32768 on 48 GB and up (picked by the installer, kept in `~/.config/gemma.env`) |
| Front end | Open WebUI in `~/open-webui-venv`, launchd daemon `com.openwebui.serve` on `0.0.0.0:8080`, data in `~/open-webui-data` |
| Auto-load | LaunchAgent `com.houdini.gemma-up` runs `~/bin/gemma-up.sh` at every desktop login |
| Users | houdini is the Open WebUI admin; friends and family get Open WebUI accounts (new sign-ups wait for approval) |

## Files

| Path | What it does |
| --- | --- |
| `bin/install-gemma-stack.sh` | One-time install: Homebrew packages, LM Studio, Gemma, Open WebUI venv, daemon, login item, `~/bin` links, offline copy in `~/ai-handoff`. Safe to re-run |
| `bin/gemma-up.sh` | Start LM Studio's server, load Gemma at `CTX`, start Open WebUI if needed |
| `bin/gemma-down.sh` | Stop Open WebUI, unload models, stop the server (`STOP_OWUI=0` keeps Open WebUI) |
| `rebuild/00-preflight.sh` | Read-only checks on the old system: chip, memory, volume owners, RemoveMacAI, Find My, FileVault, SSH, Screen Sharing, Ethernet, available Golden Gate update |
| `rebuild/10-upgrade-os.sh` | Upgrade to the newest Golden Gate 27.x over SSH (`softwareupdate`, volume owner) |
| `rebuild/30-bootstrap.sh` | First run after Setup Assistant, over SSH: Command Line Tools and Homebrew headless, repo clone on MacLLM, commit identity, `pmset`, zsh paste fix, optional computer name |
| `rebuild/40-verify.sh` | Read-only check of the finished build; exit code = number of failures |
| `config/gemma.env.example` | Template for `~/.config/gemma.env` (model, quant, context, ports) |
| `docs/rebuild-runbook.md` | Step by step: which steps run over SSH, which over Screen Sharing, and the one step at the machine |
| `docs/owui-memories.md` | Open WebUI memory text for this project |

Shared from `m5/bin` (generic, linked into `~/bin` by the installer): `owui-upgrade.sh`, `llm-bench.py`.

## Rules for generic builds

- Do not run the top-level `./install.sh` on a generic build: it links the M5 scripts (`flash-up.sh` and friends) into `~/bin`. The Gemma installer does its own linking.
- `~/ZuulRulez` stays on MacLLM. Never `git checkout` there.
- Host values go in `~/.config/gemma.env`; never commit it. No LAN addresses, e-mail addresses, tokens or `/Users/<name>` paths in this folder (example names like `M1-Studio` are fine).
- Every change: one commit and one CHANGELOG line (date, what, why, measured result).

## Daily operation

| Task | Command |
| --- | --- |
| Load Gemma / start everything | `~/bin/gemma-up.sh` |
| Stop everything | `~/bin/gemma-down.sh` |
| Health check | `~/ZuulRulez/gemma/rebuild/40-verify.sh` |
| Upgrade Open WebUI (backup, rollback) | `~/bin/owui-upgrade.sh` |
| Benchmark | `python3 ~/bin/llm-bench.py --model gemma-4-26b-a4b-it-qat` |
| Pull repo changes | `cd ~/ZuulRulez && git pull` |
| Logs | `~/Library/Logs/gemma-up.log`, `~/Library/Logs/open-webui.log` |
| Turn auto-load off / on | `launchctl bootout gui/$(id -u)/com.$USER.gemma-up` / `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.$USER.gemma-up.plist` |

## After a power failure

With FileVault on, the Mac stops at the unlock screen and nothing runs. Since macOS 26, an admin can unlock it over SSH before login (Ethernet): `ssh houdini@` the Mac, enter houdini's password, and the boot completes. Open WebUI then starts on its own; Gemma loads only after houdini logs in on the desktop, so open Screen Sharing and log in. With FileVault off and automatic login on, both come back unattended, at the cost of an unencrypted disk holding everyone's chats.

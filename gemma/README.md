# Generic Gemma 4 builds (friends-and-family hosts)

Scripted, single-model local LLM builds for M-series Mac Studios that host Open WebUI on the LAN for friends and family. Everything is command line and runs over SSH; there is no GUI app to click through, and both services start at boot before anyone logs in. Everything in this folder is generic. The M5 Max stack (`m5/`, Flash-Next, mlx-serve, Auto Router, Caddy, RAID, GPU wired-limit tuning) is **not** part of these builds. Hardening is: the RemoveMacAI profile and the macOS service toggles, as on the M5 and MBP, applied after the build verifies (runbook phase H), because turning Siri and Apple Intelligence off in Settings did not stick.

## What a build looks like

| Component | Setting |
| --- | --- |
| Hardware | Any Apple Silicon Mac Studio with 32 GB or more. First host: Mac Studio M1 Max (10 CPU / 24 GPU), 32 GB |
| OS | macOS Golden Gate 27.x, erased with Erase All Content and Settings, Ethernet |
| Account | `houdini`: the only macOS account, admin, volume owner (authorizes updates), owns and runs both services |
| Model server | LaunchDaemon `com.gemma.llm` → `gemma/bin/gemma-serve.sh`, on `127.0.0.1:1234` only, OpenAI API at `/v1`, log `~/Library/Logs/gemma-llm.log` |
| Engine `llamacpp` (default) | Homebrew `llama-server`, GGUF Q4_0 from `lmstudio-community/gemma-4-26B-A4B-it-QAT-GGUF` plus its vision projector, cache `~/models/llama.cpp`; model id `gemma-4-26b-a4b-it-qat` |
| Engine `mlx` | `mlx_vlm.server` in `~/mlx-venv`, `mlx-community/gemma-4-26B-A4B-it-qat-4bit` (15.6 GB, vision) in the Hugging Face cache; model id = that repo name |
| Context | 16384 on 32 GB, 32768 on 48 GB and up; at most 2 requests at once (`CTX`, `NP` in `~/.config/gemma.env`) |
| Front end | Open WebUI in `~/open-webui-venv`, LaunchDaemon `com.openwebui.serve` on `0.0.0.0:8080`, data in `~/open-webui-data` |
| Users | houdini is the Open WebUI admin; friends and family get Open WebUI accounts (new sign-ups wait for approval) |

Both engines serve the same API and the same model weights family, so Open WebUI doesn't care which one runs. The model id differs, though: personas and the Task Model point at one id, so settle the engine before building personas.

## Files

| Path | What it does |
| --- | --- |
| `bin/install-gemma-stack.sh` | Install or re-check, all over SSH: Homebrew packages, engine, model download, both daemons, `~/bin` links, offline copy in `~/ai-handoff`, then starts and checks. Safe to re-run; `ENGINE=mlx` in front adds that engine and switches to it |
| `bin/gemma-serve.sh` | What the `com.gemma.llm` daemon runs: execs the chosen engine with the settings from `gemma.env` (localhost only, no downloads at start) |
| `bin/gemma-env.sh` | Sourced by every script: loads `~/.config/gemma.env`, defaults, model id per engine |
| `bin/gemma-up.sh` | Start whatever is stopped and wait until both answer; `RESTART=1` restarts the model server after an env change |
| `bin/gemma-down.sh` | Stop Open WebUI and the model server (`STOP_OWUI=0` stops only the model server) |
| `rebuild/00-preflight.sh` | Read-only checks on the old system: chip, memory, volume owners, RemoveMacAI, Find My, FileVault, SSH, Screen Sharing, Ethernet, available Golden Gate update |
| `rebuild/05-inventory.sh` | Read-only snapshot before a wipe: apps (version, App Store or not, size), Homebrew, launchd items, profiles, one user's account details (default UID 503) and every file in their home folder (size, date, path; caches skipped). Output stays on that Mac, never in the repo |
| `rebuild/06-inventory-diff.py` | Compares two snapshots (e.g. M1 vs M5): report.md plus full lists of files only on each side and files that differ |
| `rebuild/10-upgrade-os.sh` | Upgrade to the newest Golden Gate 27.x over SSH (`softwareupdate`, volume owner) |
| `rebuild/30-bootstrap.sh` | First run after Setup Assistant, over SSH: Command Line Tools and Homebrew headless, repo clone on MacLLM, commit identity, `pmset`, zsh paste fix, optional computer name |
| `rebuild/50-harden.sh` | Hardening helpers: memory snapshots before/after, RemoveMacAI install and wait, status of the profile and the service toggles (watchdogd and rapportd checks) |
| `rebuild/40-verify.sh` | Read-only check of the finished build, including one real chat completion; exit code = number of failures |
| `config/gemma.env.example` | Template for `~/.config/gemma.env` (engine, repos, quant, context, parallel, ports) |
| `docs/rebuild-runbook.md` | Step by step, with the one step at the machine |
| `docs/owui-memories.md` | Open WebUI memory text for this project |

Shared from `m5/bin` (generic, linked into `~/bin` by the installer): `owui-upgrade.sh`, `llm-bench.py`.

## For a Linux person

| Linux habit | Here |
| --- | --- |
| `systemctl status / restart / stop` | `sudo launchctl print system/com.gemma.llm` · `sudo launchctl kickstart -k system/com.gemma.llm` · `~/bin/gemma-down.sh` |
| unit files in `/etc/systemd/system` | plists in `/Library/LaunchDaemons` (written by the installer; edit `gemma.env`, not the plist) |
| `journalctl -u` | `tail -f ~/Library/Logs/gemma-llm.log ~/Library/Logs/open-webui.log` |
| `apt` | `brew` (in `/opt/homebrew`) |
| `ss -ltnp` | `lsof -nP -iTCP -sTCP:LISTEN` |
| `free -h`, `vmstat` | `top -l 1 \| grep PhysMem`, `vm_stat`, `sysctl vm.swapusage`, `memory_pressure` |
| GPU memory | Unified memory: macOS lets the GPU wire roughly two thirds of RAM by default (~21 GB on 32 GB) |

## Engines

| | llama.cpp (default) | MLX |
| --- | --- | --- |
| Weights | GGUF Q4_0 + vision projector | MLX 4-bit QAT |
| Concurrency | `NP` slots share one `CTX`-sized cache | up to `NP` sequences, each capped at `CTX` |
| Thinking | template default (`--reasoning auto`) | off unless a request enables it |
| Upgrade | `brew upgrade llama.cpp`, then `RESTART=1 ~/bin/gemma-up.sh` | `~/mlx-venv/bin/pip install -U mlx-vlm`, then restart |

Which is faster on a given Studio is measured, not assumed: run `llm-bench.py` on each (`--label llamacpp`, `--label mlx`) and record both in the CHANGELOG. On an M1 Max, an outside benchmark of a different model found llama.cpp about 30% faster at decode.

## Rules for generic builds

- Do not run the top-level `./install.sh` on a generic build: it links the M5 scripts (`flash-up.sh` and friends) into `~/bin`. The Gemma installer does its own linking.
- `~/ZuulRulez` stays on MacLLM. Never `git checkout` there.
- Host values go in `~/.config/gemma.env`; never commit it. No LAN addresses, e-mail addresses, tokens or `/Users/<name>` paths in this folder (example names like `M1-Studio` are fine).
- Every change: one commit and one CHANGELOG line (date, what, why, measured result).
- macOS updates: RemoveMacAI must come off first (it stalls the download) and go back on after. `10-upgrade-os.sh` removes it on request and `40-verify.sh` fails until `50-harden.sh profile` reinstalls it.

## Daily operation

| Task | Command |
| --- | --- |
| Health check | `~/ZuulRulez/gemma/rebuild/40-verify.sh` |
| Start / wait until ready | `~/bin/gemma-up.sh` |
| Apply a `gemma.env` change | `RESTART=1 ~/bin/gemma-up.sh` |
| Switch engine | `ENGINE=mlx ~/ZuulRulez/gemma/bin/install-gemma-stack.sh` (or `ENGINE=llamacpp`) |
| Stop everything (frees the memory) | `~/bin/gemma-down.sh` |
| Upgrade Open WebUI (backup, rollback) | `~/bin/owui-upgrade.sh` |
| Benchmark | `python3 ~/bin/llm-bench.py --model gemma-4-26b-a4b-it-qat --label llamacpp` |
| Pull repo changes | `cd ~/ZuulRulez && git pull`, then re-run the installer |

## After a power failure

FileVault is **off** on generic builds (owner's decision, 2026-10-28), so the Mac comes back unattended: it restarts by itself (`pmset autorestart 1`), boots without an unlock, and both daemons start with nobody logged in. Measured on the M1: everything up and `40-verify.sh` passing within a minute of the restart. The trade-off is an unencrypted disk holding everyone's chats; keep the Mac physically secure. To encrypt later: `sudo fdesetup enable -user houdini` (save the recovery key it prints); from then on every reboot waits until someone runs `ssh houdini@` the Mac over Ethernet and enters the password.

## Left for the new owner

Settings that depend on how the owner wants the box used, so the build leaves them off:

- **Web search ("internet access" in chats).** Off by default: no search engine is configured, so chats show no web-search toggle. To turn it on: Admin Panel → Settings → Web Search → enable, pick a search engine and save. DuckDuckGo needs no API key; Brave, Tavily and similar need one (keep keys in Open WebUI, never in this repo); SearXNG can be self-hosted. The toggle then appears in the chat input's options. Searches go out from the Studio, and results are added to the prompt: on a 32 GB M1 (16K context, ~390 tok/s prefill) a search that adds 5,000 tokens costs about 13 s before the answer starts.
- **Tools: local folders, GitHub and other code hosts.** None are installed. Open WebUI can give models tools in two ways (menu names vary between Open WebUI versions):
  - *Python tools* under Workspace → Tools: small functions that run inside Open WebUI.
  - *Tool servers* (OpenAPI, or MCP through a bridge such as `mcpo`) added under the admin settings for external tools: for example a filesystem server limited to one folder, or a GitHub server.

  Things to decide before adding any: tools run on the Studio as houdini, so a filesystem tool should be limited to a dedicated folder, never `~` or `~/.config`; a GitHub tool needs a token, which should be fine-grained, read-only and limited to the repos it needs, stored in Open WebUI or `~/.config`, never in this repo; tools can be enabled per model and per user, so decide whether family members get them or only the admin; and every tool call adds its output to the prompt, with the same prefill cost as web search. Gemma 4 can call tools on llama.cpp (the server runs with `--jinja`); check that a tool actually gets called before relying on it.

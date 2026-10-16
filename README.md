# Mac Studio System Monitor

A single-file Python system monitor for Apple Silicon Macs.  
Two views from one process: a floating **desktop widget** (tkinter + PIL) and a
**web dashboard** (Flask, port 9090) — both WCAG 2.1 AA contrast-compliant.

---

## What it shows

| Label | Description |
|-------|-------------|
| USE | CPU utilisation % |
| RAM | RAM used / total (GB) |
| MEM | Memory pressure % · swap % · compressed % |
| SSD | SSD usage % |
| GHz | P-cluster active frequency |
| GPU | GPU HW active residency % |
| PWR | CPU package power (mW) |
| SWP | Swap used / total (GB) |
| THM | Thermal pressure level |
| EFF | GPU residency ÷ CPU watts (%/W) |
| g4 t/s | Gemma-4 tokens/sec (live from LM Studio) |
| fls t/s | Flash-Next tokens/sec (live from LM Studio) |

### Graph (10-hour window, Y-axis auto-zoomed)

| Colour | Series |
|--------|--------|
| White / green / red | MEM pressure |
| Orange | SWP |
| Light grey | GPU (background reference) |
| Grey | MEM delta |
| Blue | EFF ÷ 500 |
| Violet | TPS ÷ 125 |

### LMS t/s — how it works

The monitor tails `lms log stream --source model --filter output --stats --json`
and reads `data.stats.tokensPerSecond` from each completed generation event.
It tracks the last reading per model abbreviation (`g4`, `flash`) and retains
it for up to one hour. An idle-watchdog thread demotes the status from Active
to Idle when no event arrives within 30 seconds.

**Note:** the t/s values are from real inference workloads, not synthetic
benchmarks. Typical ranges on an M3 Ultra / 192 GB Mac Studio:

- Gemma-4-26B-A4B-IT-QAT: ~80–118 t/s (graph scale: 125 t/s = 100%)
- Flash-Next: ~28–48 t/s

---

## Requirements

- macOS with Apple Silicon (M1–M5 family)
- Python 3.11+ (system or venv)
- `pip install psutil Pillow flask`
- `sudo` access for `powermetrics` (needed for GPU, PWR, GHz, THM, EFF)
- [LM Studio](https://lmstudio.ai) with `lms` CLI for the t/s rows (optional)

---

## Setup

### 1 — Clone and configure

```zsh
cd ~/ZuulRulez
git checkout M-ProcessorSystemMonitor
cp env.example ~/.config/macmonitor.env
```

Edit `~/.config/macmonitor.env` and fill in your paths.  
`~/.config/` is in `.gitignore` — this file is never committed.

### 2 — Install the script

```zsh
cp src/mac_monitor.py ~/.local/bin/mac_monitor.py
chmod +x ~/.local/bin/mac_monitor.py
```

### 3 — Run manually (for testing)

```zsh
set -a; source ~/.config/macmonitor.env; set +a
~/macmonitor-venv/bin/python3 ~/.local/bin/mac_monitor.py
```

Web dashboard: `http://<studio-lan-ip>:9090`

### 4 — Install as a LaunchDaemon (auto-start on boot)

```zsh
cp launchd/com.user.macmonitor.plist.template /tmp/macmonitor.plist
```

Open `/tmp/macmonitor.plist` and replace every `%%PLACEHOLDER%%` with your
actual values (username, venv path, script path, log path, env file path).

```zsh
sudo cp /tmp/macmonitor.plist /Library/LaunchDaemons/com.user.macmonitor.plist
sudo chown root:wheel /Library/LaunchDaemons/com.user.macmonitor.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.user.macmonitor.plist
```

### 5 — Stop / restart

```zsh
sudo launchctl bootout system /Library/LaunchDaemons/com.user.macmonitor.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.user.macmonitor.plist
```

---

## Branches

| Branch | Contents |
|--------|----------|
| `M-ProcessorSystemMonitor` | This monitor (desktop widget + web dashboard) |
| `MacLLM` | Local LLM stack — LM Studio, Open WebUI, router, benchmarks |

---

## Secrets and machine-specific values

**Never commit** tokens, passwords, API keys, LAN IP addresses, personal email
addresses, or `/Users/<name>` paths.

Machine-specific values live in `~/.config/macmonitor.env` (gitignored).  
See `env.example` for the full list of supported variables.

---

## Continuing development in a new chat

Give the AI the repo link and branch name, then say:

> Read `README.md` and `CHANGELOG.md` first, then help me with …

The AI will have full context from those two files without needing to re-read
the whole conversation history.

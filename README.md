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
| g4 t/s | Gemma 4 tokens/sec (mlx-serve on `127.0.0.1:11235`) |
| fls t/s | Flash-Next tokens/sec (mlx-serve on `127.0.0.1:11234`) |

### Graph (10-hour window, Y-axis auto-zoomed)

| Colour | Series |
|--------|--------|
| White / green / red | MEM pressure |
| Orange | SWP |
| Light grey | GPU (background reference) |
| Grey | MEM delta |
| Blue | EFF ÷ 500 |
| Violet | TPS ÷ 150 (finished requests, both models) |

### Model t/s — how it works

Both models run in their own mlx-serve (LM Studio was removed Nov 3, 2026). Every
5 s the monitor reads each server's `/metrics.json`:

- **decode t/s** = Δ`histograms.output_tokens.sum` / Δ`histograms.decode_time_seconds.sum`
  for requests that finished since the last poll; kept on screen for up to an hour.
- **live t/s** (shown with `~`) = Δ`gauges.generation_tokens_live` / Δt while
  `gauges.requests_running` > 0. Never add `counters.generation_tokens_total`; it
  double-counts.

Row colour: bright while generating or within an hour of the last request, grey when
the server is up but idle, dark when it is down. Each finished-request reading is also
added to the graph's violet TPS line. Server URLs can be overridden with
`MONITOR_G4_URL` / `MONITOR_FLS_URL`.

**Note:** the t/s values are from real inference workloads, not synthetic
benchmarks. Typical ranges on the M5 Max / 128 GB Mac Studio (Nov 3, 2026):

- Gemma 4 26B-A4B QAT: ~78–142 t/s (78 while Flash is also busy)
- Flash-Next (MTP on): ~63–93 t/s

---

## Requirements

- macOS with Apple Silicon (M1–M5 family)
- Python 3.11+ (system or venv)
- `pip install psutil Pillow flask`
- `sudo` access for `powermetrics` (needed for GPU, PWR, GHz, THM, EFF)
- mlx-serve with `--metrics` for the t/s rows (optional; rows show `—` without it)

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

Web dashboard: `https://<studio-hostname>.local:9443` — the monitor binds 127.0.0.1; Caddy provides HTTPS

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
| `MacLLM` | Local LLM stack — mlx-serve (Flash-Next, Gemma 4), Open WebUI, router, benchmarks |

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

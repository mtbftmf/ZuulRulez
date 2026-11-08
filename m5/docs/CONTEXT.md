# ZuulRulez Monitor — Session Context

> Feed this file to any LLM session before working on the monitor code.
> Last updated: 2026-11-08

---

## Hardware estate

| Machine | Role | Branch/Repo |
|---|---|---|
| Mac Studio M5 Max | Primary workstation + MLX inference | `M-ProcessorSystemMonitor` in `ZuulRulez-monitor` |
| MacBook Pro M3 Pro 14" | Portable; runs same monitor | same branch |
| Mac Studio M1 Max 32 GB | Headless Gemma 4 LLM server (shipped to friend in CA) | `MacLLM` in `ZuulRulez` |

---

## Repos

- **`~/ZuulRulez-monitor/`** — monitor app repo (M5 Studio)
  - Branch: `M-ProcessorSystemMonitor`
  - Remote: `https://github.com/mtbftmf/ZuulRulez.git`
  - Source: `src/mac_monitor.py`
  - Deployed binary: `~/.local/bin/mac_monitor.py`

- **`~/ZuulRulez/`** — main repo (M5 Studio, `MacLLM` branch)
  - Docs: `m5/docs/` — canonical home for policy/context docs
  - Audio and other machine configs live here

---

## Monitor app — `mac_monitor.py`

### What it is
Single Python file: tkinter desktop GUI + Flask web dashboard.
PIL/Pillow `ImageDraw` for desktop graph rendering.
WCAG 2.1 AA / 508 compliant (≥4.5:1 contrast on `#08080f` background).

### Key config constants (M5 Max)
```python
TPS_GRAPH_SCALE   = 150.0   # mlx-serve: g4 ~142 t/s, flash ~93 t/s
EFF_GRAPH_SCALE   = 500.0   # M5 Max GPU/W peaks ~300-400
WEB_PORT          = 9090
MLX_POLL_INTERVAL = 5
PM_INTERVAL       = 5       # powermetrics sample interval (seconds) — was 15
```

### Two mlx-serve instances (M5 Max)
- Port 11234 — Flash-Next (fls), workhorse for deep reasoning, ~78 GB resident
- Port 11235 — Gemma 4 (g4), router/vision/tasks (26B MoE), evicts when idle

### Memory
- 128 GB unified memory; Flash holds ~78 GB resident, Gemma ~1.6 GB when idle
- Both simultaneously would exceed 128 GB — MLX manages via weight eviction
- `ngram_warm_bytes: 0` in mlx-serve metrics indicates evicted model
- Peak observed: ~100 GB during simultaneous heavy use (no swap)

### Power label (PWR/W)
- Stat row labelled **PWR/W** — reports SoC package power (CPU+GPU+ANE combined), displayed in watts
- Source: `powermetrics` `Combined Power` field via `CPU_PWR_RE` regex (reports mW, divided by 1000 for display)
- This is **not** wall power (excludes unified memory, SSD, PSU conversion loss)
- Typical values: 0.1–0.3 W idle, 7–15 W under heavy LLM load on M5 Max
- For wall power: use a smart plug or UPS that reports load
- Display format — web: `0.1 W (max 7.5 W)`; desktop compact: `0.1 (7.5) W`
- Graph series: gold line, scale PS=20000 mW (20 W = 100%), legend `PWR ÷20W`
- `_pwr_history` list populated every 5s, persisted in `mem_history.json`

### Lifetime-max peaks
- `_max_tps` (dict, keyed by model) and `_max_pwr_mw` (float) track session peaks
- **Persisted across restarts** to `~/.local/share/macmonitor_peaks.json`
- Loaded at startup via `_load_peaks()`; written via `_save_peaks()` only when a new peak is set (not every sample)
- `get_model_display(key, compact=False)` and `get_cpu_power(compact=False)` — GUI call sites pass `compact=True`
- PKG max is a 5s-averaged peak, not a 1s instantaneous burst
- Web dashboard (full): `117.3 (max 117)` / `0.1 W (max 7.5 W)`
- Desktop GUI (compact): `117.3 (117)` / `0.1 (7.5) W`

### Graph series (web dashboard)
| Series | Color | Scale | Notes |
|---|---|---|---|
| MEM | green→yellow→red | 0–100% | threshold coloring |
| SWP | orange | 0–100% | |
| GPU | grey | 0–100% | 50% alpha |
| MEM Δ | grey/white | centered 50% | clamped ±10 GB |
| EFF | blue | ÷500 | %/W efficiency |
| TPS | violet | ÷150 | tok/s, 60s gap break |
| PWR | gold | ÷20W (PS=20000 mW) | SoC package watts — raise PS if gold line clips |

### Network
- Flask listens on `host="127.0.0.1"`, port `9090`
- Caddy HTTPS proxy on port `9443` (external access)
- Web API route: `GET /api` (not `/api/stats`)
- Internal curl: `curl http://127.0.0.1:9090/api`

### Process management
- **System LaunchDaemon** — `/Library/LaunchDaemons/com.user.macmonitor.plist`, root-owned, runs as `ewagner` via `UserName` key. Survives reboot. Lives in the **system domain**, not the user domain.
  - Verify domain: `sudo launchctl print system/com.user.macmonitor | grep -E 'path =|state =|pid ='`
  - NOT in `~/Library/LaunchAgents/` — that directory has no mac-monitor plist
- **`KeepAlive` is true** — `sudo launchctl stop` kills the process but launchd immediately restarts it. To restart with a new binary: `sudo kill $(pgrep -f mac_monitor)` — launchd relaunches automatically within seconds.
- Python 3.14 (not Homebrew 3.15) — 3.15 lacks tkinter; any `nohup python3` failure in log is harmless
- Check running PID: `pgrep -f mac_monitor`
- Logs: `~/Library/Logs/macmonitor.log` (stdout) and `~/Library/Logs/macmonitor.err` (stderr).
  - Verify: `sudo lsof -nP -p $(pgrep -f mac_monitor.py | head -1) | grep -E 'macmonitor\.(log|err)'`
  - Expected noise: `.err` gets a repeating `NSXPCSharedListener … 'com.apple.view-bridge': Connection interrupted` line after every start; monitor still answers on 9090

### PIL graph — desktop
- Throttled to every 3rd tick (15 s) to reduce CPU
- MEM-delta line uses clamped calculation (see fix below)

---

## Key fixes applied (chronological)

### 2026-11-01 — ARD typing lag (resolved)
- **Symptom:** 2–3 s keyboard lag via Apple Remote Desktop after Golden Gate 27.2 + Xcode update
- **Root cause:** AOC display slept via DP/CalDigit TS3 Plus → macOS fell back to screensharingd virtual framebuffer → WindowServer `set_cursor_surface` failures stalled ARD input dispatch
- **Fix:** AOC connected directly via HDMI; `pmset -a displaysleep 0`

### 2026-11-05 — MEM-delta graph spike fix
- **Symptom:** Extreme white/grey vertical spikes in MEM-delta graph line during MLX model load/unload
- **Root cause:** Delta multiplier was unbounded `d * 5`; large memory swings amplified to full-height spikes
- **Fix — PIL delta calculation:**
  ```python
  dlt.append((mem_snap[i][0], min(100, max(0, 50 + min(10, max(-10, d)) * 2.5))))
  ```

### 2026-11-06 — JS web graph delta clamp fix
- **Symptom:** Web dashboard graph completely frozen — numerical stats updating but graph not drawing
- **Root cause:** PIL fix applied only to Python. JS canvas graph in `HTML_TEMPLATE` still used unbounded `* 5`. Out-of-range delta values corrupted y-axis zoom (`yLo`/`yHi`), causing `drawGraph()` to render nothing.
- **Fix — JS inside `HTML_TEMPLATE`:**
  ```javascript
  for(let i=6;i<mem.length;i++){const dd=mem[i][1]-mem[i-6][1],dc=Math.min(10,Math.max(-10,dd));d.push([mem[i][0],Math.min(100,Math.max(0,50+dc*2.5))]);}
  ```
- **Lesson:** PIL graph (desktop) and JS canvas graph (web) are independent renderers — fixes must be applied to both.

### 2026-11-08 — Lifetime-max display for t/s and power
- Added `_max_tps` dict and `_max_pwr_mw` float globals
- Web dashboard: full `(max N)` suffix; desktop GUI: compact `(N)` suffix
- `get_model_display()` and `get_cpu_power()` accept `compact=False` param

### 2026-11-08 — Power display in watts, PWR/W label
- `get_cpu_power()` now divides mW by 1000, displays to 1 decimal place in W
- Label changed to `PWR/W` (fits tkinter column without overlap)
- Verified with powermetrics: 0.1–0.3 W idle, spikes to ~1.5 W during light load

### 2026-11-08 — PKG power graph series
- Added `_pwr_history` (5s samples) persisted to `mem_history.json`
- Gold `PWR÷20W` line added to web dashboard graph and legend
- Scale PS=20000 mW (20 W = 100%) gives headroom for M5 Max workloads

### 2026-11-08 — Persist lifetime-max peaks across restarts
- Added `PEAKS_FILE` (`~/.local/share/macmonitor_peaks.json`)
- `_load_peaks()` called at startup; `_save_peaks()` called only when a new peak is set
- Peaks survive daemon restarts and reboots — required before publishing wattage claims

---

## Pending (ordered by what each unblocks)

1. **Run measurement window** — cold 12K persona prefill + 24K deep-work generation, both models resident at different points. Check `~/.local/share/macmonitor_peaks.json` after. Run `sudo powermetrics -i 5000 --show-power | tee /tmp/pm_peak.log` in parallel for ground truth.
2. **Thermal pressure history** — log `_thm_history` alongside other series; enables "no throttling across 18h" claim. Currently only displays `Nominal`, not recorded over time.
3. **Wh/1k tokens** — offline calc: integrate `_pwr_history` over a known window, divide by tokens from `/metrics.json`. No daemon change needed — data already being collected.
4. **PS scale check** — if cold prefill causes gold PWR line to clip at top of graph, raise `PS` from 20000.

---

## M1 Studio Max — headless monitor (`m1_monitor.py`)

Separate file for the headless M1 server shipped to CA friend.
- Web-only (no tkinter)
- llama.cpp 0.8.0 on port 8080, Prometheus `/metrics` for Gemma 4 tok/s
- Flask on port 9090
- TPS scale: 60 t/s, PWR scale: 60 W (32 GB unified memory)
- 36-hour graph history
- No HDMI dummy plug needed (SSH-only access)

---

## Commit / security rules (must follow)

- **Never commit:** tokens, passwords, API keys, LAN IP addresses, personal email addresses, `/Users/<name>` paths
- Machine-specific values go in `~/.config/*.env` (git-ignored); provide `env.example` with placeholders
- Each change: one commit + one CHANGELOG line (what changed, why, measured result if any)
- Shell commands pasted to zsh: no `#` comments inline, no `<placeholder>` text, don't pipe JSON through `echo`
- Heredoc commit messages via `git commit -m "$(cat <<'EOF' ... EOF)"`
- **Multi-edit patches: always deliver as a downloadable Python script, never as shell heredocs** — heredocs containing `EOF` in content will terminate early
- Attribution lines at end of every commit message:
  ```
  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01FrXUfoq33ugWc7b3mZ2nmq
  ```

---

## Quick diagnostics

```bash
# Is monitor running and in which domain?
pgrep -f mac_monitor
sudo launchctl print system/com.user.macmonitor | grep -E 'path =|state =|pid ='

# Restart with new binary (KeepAlive=true — launchctl stop won't stick)
sudo kill $(pgrep -f mac_monitor)

# Is API healthy?
curl -s http://127.0.0.1:9090/api | python3 -c "import json,sys; d=json.load(sys.stdin); print('OK, keys:', len(d))"

# Check persisted peaks
cat ~/.local/share/macmonitor_peaks.json

# Port bind — confirm loopback only
sudo lsof -nP -iTCP:9090 -sTCP:LISTEN

# Logs (stdout / stderr)
tail -20 ~/Library/Logs/macmonitor.log
tail -20 ~/Library/Logs/macmonitor.err

# Verify log path against reality
sudo launchctl print system/com.user.macmonitor | grep -E 'stdout path|stderr path'
sudo lsof -nP -p $(pgrep -f mac_monitor.py | head -1) | grep -E 'macmonitor\.(log|err)'

# Verify powermetrics is reading correctly (run during a generation)
sudo powermetrics -n 5 -i 2000 --samplers cpu_power | grep -i "combined power"

# Git — always print, never hard-code hashes
git -C ~/ZuulRulez-monitor log --oneline -5
git -C ~/ZuulRulez log --oneline -5
```

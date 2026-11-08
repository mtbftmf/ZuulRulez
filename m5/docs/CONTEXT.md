# ZuulRulez Monitor — Session Context

> Feed this file to any LLM session before working on the monitor code.
> Last updated: 2026-11-08 (session 3)

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

---

## Monitor app — `mac_monitor.py`

### What it is
Single Python file: tkinter desktop GUI + Flask web dashboard.
PIL/Pillow `ImageDraw` for desktop graph rendering.
WCAG 2.1 AA / 508 compliant (≥4.5:1 contrast on `#08080f` background).

### Key config constants (M5 Max)
```python
TPS_GRAPH_SCALE   = 150.0   # mlx-serve: g4 ~111 t/s, fls ~81 t/s single; combined ~126 t/s
EFF_GRAPH_SCALE   = 10.0    # tok/s/W; at 3.2 tok/s/W = 32% of graph
WEB_PORT          = 9090
MLX_POLL_INTERVAL = 5
PM_INTERVAL       = 5       # powermetrics sample interval (seconds)
```

### Two mlx-serve instances (M5 Max)
- Port 11234 — Flash-Next (fls), workhorse for deep reasoning, ~78 GB resident
- Port 11235 — Gemma 4 (g4), router/vision/tasks (26B MoE), evicts when idle

### Memory
- 128 GB unified memory; Flash holds ~78 GB resident, Gemma ~1.6 GB when idle
- Both simultaneously would exceed 128 GB — MLX manages via weight eviction
- Peak observed: ~100 GB during simultaneous heavy use (no swap)

### Power label (⚡)
- Stat row labelled **⚡** — reports SoC package power (CPU+GPU+ANE combined), displayed in watts
- Source: `powermetrics` `Combined Power (CPU + GPU + ANE)` field
- **Critical:** `CPU_PWR_RE = re.compile(r"^Combined Power \(CPU \+ GPU \+ ANE\):\s*([\d.]+)\s*mW", re.MULTILINE)`
- During MLX inference GPU dominates at 46–53W; CPU-only is ~5–7W. Regex MUST match Combined Power.
- Typical values: 0.1–0.3 W idle, 39–64 W during heavy MLX generation
- Display: web `49.0 W (max 64.5 W)`; desktop compact `49.0 (64.5) W`
- Graph: gold line, PS=100000 mW (100W = 100%), legend `⚡ ÷100W`
- `_pwr_history` populated every 5s, persisted in `mem_history.json`

### 🧠 MEMBRAIN row
- Label: `🧠` — memory pressure (not raw %)
- Value: `get_memory_pressure()` returns `"78% 80%↑ 82%"` (min/cur/max), color-coded
- Distinct from RAM row which shows raw GB (`102.7/128G`)

### T/W row (tok/s per watt)
- Label: **T/W** — replaces EFF (GPU%/W was constant at load, uninformative)
- `get_efficiency()` sums `decode_tps` from all MLX servers active in last 30s, divides by combined SoC watts
- Guards: power must be ≥5W (`mw >= 5000`); at least one model active in last 30s
- Shows `…` at idle — correct, stale tps / idle power gives nonsense
- Verified: 3.2 tok/s/W at 39W with g4+fls both active (126 t/s combined)
- `_eff_history` populated from combined tps/W during active windows only
- Scale: `EFF_GRAPH_SCALE=10.0`; JS `ES=10`; at 3.2 tok/s/W = 32% of graph

### Lifetime-max peaks
- `_max_tps` (dict, keyed by model) and `_max_pwr_mw` (float) tracked and persisted
- File: `~/.local/share/macmonitor_peaks.json` (includes `max_pwr_ts` timestamp)
- Loaded at startup via `_load_peaks()`; written via `_save_peaks()` only on new peak
- Verified peaks: g4 max 111 t/s, fls max 81 t/s, PWR max 78.4W

### Graph series (web dashboard)
| Series | Color | Scale | Notes |
|---|---|---|---|
| MEM | green→yellow→red | 0–100% | threshold coloring |
| SWP | orange | 0–100% | |
| GPU | grey | 0–100% | 50% alpha |
| MEM Δ | grey/white | centered 50% | clamped ±10 GB |
| T/W | blue | ÷10 | tok/s/W, gaps at idle |
| TPS | violet | ÷150 | tok/s, 60s gap break |
| ⚡ | gold | ÷100W (PS=100000 mW) | SoC package watts |

**Important:** `collectV(pwr,PS)` is intentionally NOT in y-axis zoom — power spikes would rescale % series.

### Network
- Flask listens on `host="127.0.0.1"`, port `9090`
- Caddy HTTPS proxy on port `9443` (external access)
- Web API route: `GET /api`

### Process management
- **System LaunchDaemon** — `/Library/LaunchDaemons/com.user.macmonitor.plist`
- **`KeepAlive` is true** — `sudo launchctl stop` immediately relaunches. To deploy:
  ```zsh
  cp ~/ZuulRulez-monitor/src/mac_monitor.py ~/.local/bin/mac_monitor.py
  sudo kill $(pgrep -f mac_monitor)
  ```
- Python 3.14 (not Homebrew 3.15 — lacks tkinter)
- Logs: `~/Library/Logs/macmonitor.log` / `macmonitor.err`

---

## Key fixes applied (chronological)

### 2026-11-01 — ARD typing lag (resolved)
- AOC display slept via DP/CalDigit → macOS fell back to screensharingd virtual framebuffer
- Fix: AOC via HDMI direct; `pmset -a displaysleep 0`

### 2026-11-05 — MEM-delta graph spike fix (PIL)
```python
dlt.append((mem_snap[i][0], min(100, max(0, 50 + min(10, max(-10, d)) * 2.5))))
```

### 2026-11-06 — JS web graph delta clamp fix
```javascript
for(let i=6;i<mem.length;i++){const dd=mem[i][1]-mem[i-6][1],dc=Math.min(10,Math.max(-10,dd));d.push([mem[i][0],Math.min(100,Math.max(0,50+dc*2.5))]);}
```
**Lesson:** PIL (desktop) and JS canvas (web) are independent renderers — fixes must apply to both.

### 2026-11-08 — Lifetime-max display, watts, PKG graph, peak persistence
- `_max_tps` dict and `_max_pwr_mw` float with file persistence
- Power in watts, gold graph series, peaks file

### 2026-11-08 — Combined Power regex fix (critical, 5e4296f)
- Old: `^CPU Power:` → ~5–7W (CPU only)
- Fixed: `^Combined Power \(CPU \+ GPU \+ ANE\):` → 49–64W at load
- Also fixed: `now` UnboundLocalError in powermetrics poller (crashed every 5s, all stats stale)
- ⚡ label (was PWR/W), 🧠 label (was MEM), PS=80000, ES=10

### 2026-11-08 — T/W replaces EFF (fb51a48, d942c3f)
- GPU%/W was ~constant at load (GPU always 99.9%) — replaced with combined tok/s/W
- Sums decode_tps from all active MLX servers; 5W power floor; 30s recency window
- Verified: 3.2 tok/s/W at 39W (g4+fls combined 126 t/s)

---

## Publishable numbers (verified 2026-11-08)

| Metric | Value | Context |
|---|---|---|
| Idle power | 0.1–0.3 W | Combined SoC (CPU+GPU+ANE) |
| Sustained generation | ~49 W | Both models active |
| Peak (5s average) | 78.4 W | Recorded with timestamp |
| T/W at load | ~3.2 tok/s/W | g4+fls combined, 126 t/s / 39W |
| RAM at load | 102.7/128 GB | No swap |
| Thermal | Nominal | No throttling observed |

Post ¶4: *"One box, one cable, no rack: 49 W sustained through generation, 78 W peak in five-second samples — under a desk, not in a closet."*
Say "combined SoC package (CPU+GPU+ANE)" if asked; never "the box". State "five-second samples" for defensibility.

### 2026-11-08 — T/W window fix + current-power gate + PS=100000 (0eb4881)
- T/W window mismatch: tps window was 30s but power was instantaneous 5s sample.
  Fixed: `get_efficiency()` and `_eff_history` both average `_pwr_history[-6:]` (30s).
- Added `if m < 5000: return "…"` gate on current instantaneous power — prevents
  stale 30s window from showing non-zero T/W at idle after generation ends.
- PS raised 80000→100000 (old 80W was 98% utilised at 78.4W peak).
- Verified: 3.2 tok/s/W at 32.5W; `…` at idle. Peak: 78.4W.

---

## Pending

1. **Run cold measurement window** — 12K persona prefill + 24K deep-work generation, verify ⚡ 50–60W, check peaks file
2. **Thermal pressure history** — `_thm_history` for "no throttling across 18h" claim
3. **Wh/1k tokens** — integrate `_pwr_history` / tokens from `/metrics.json`

---

## M1 Studio Max — headless monitor (`m1_monitor.py`)
- Web-only (no tkinter); llama.cpp 0.8.0 on port 8080
- Flask on port 9090; TPS scale 60 t/s, PWR scale 60W

---

## Commit / security rules

- **Never commit:** tokens, passwords, API keys, LAN IPs, personal emails, `/Users/<name>` paths
- Each change: one commit + one CHANGELOG line
- **Multi-edit patches: always deliver as a downloadable Python script, never as shell heredocs**
- Attribution on every commit:
  ```
  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01FrXUfoq33ugWc7b3mZ2nmq
  ```

---

## Quick diagnostics

```bash
pgrep -f mac_monitor
curl -s http://127.0.0.1:9090/api | python3 -c "import json,sys; d=json.load(sys.stdin); print('OK, keys:', len(d))"
cat ~/.local/share/macmonitor_peaks.json
sudo powermetrics -n 3 -i 2000 --samplers cpu_power | grep -i "combined power"
tail -20 ~/Library/Logs/macmonitor.log
tail -5 ~/Library/Logs/macmonitor.err
git -C ~/ZuulRulez-monitor log --oneline -5
```

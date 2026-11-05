# ZuulRulez Monitor — Session Context

> Feed this file to any LLM session before working on the monitor code.
> Last updated: 2026-11-05

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
MLX_URL           = "http://127.0.0.1:11234"   # primary (Gemma 4)
MLX_POLL_INTERVAL = 5
```

### Two mlx-serve instances (M5 Max)
- Port 11234 — Gemma 4 (G4), ~142 t/s peak
- Port 11235 — Flash (fls), ~93 t/s peak

### Network
- Flask listens on `host="127.0.0.1"`, port `9090`
- Caddy HTTPS proxy on port `9443` (external access)
- Web API route: `GET /api` (not `/api/stats`)
- Internal curl: `curl http://127.0.0.1:9090/api`

### Process management
- **LaunchAgent** manages restart — uses Python 3.14 (not Homebrew 3.15)
- Python 3.15 (Homebrew) lacks tkinter; `nohup python3` will fail with `ModuleNotFoundError: _tkinter` — this is harmless, ignore it
- Check running PID: `pgrep -f mac_monitor`
- Log: `~/mac_monitor.log`

### PIL graph — desktop
- Throttled to every 3rd tick (15 s) to reduce CPU
- MEM-delta line uses clamped calculation (see fix below)

---

## Key fixes applied (chronological)

### 2026-11-01 — ARD typing lag (resolved)
- **Symptom:** 2-3 s keyboard lag via Apple Remote Desktop after Golden Gate 27.2.
- **Root cause:** AOC display slept via DP/CalDigit TS3 Plus -> macOS fell back to
  the screensharingd virtual framebuffer -> WindowServer set_cursor_surface
  failures stalled ARD input dispatch.
- **Fix:** Force the virtual display to true 1080p with scaling off:
  displayplacer id:15C9F10C-0D98-43BA-B726-77AD38EFFF11 res:1920x1080 hz:60
  color_depth:4 scaling:off. Re-verify Scaling: off after each new session.
- **Note:** HDMI dummy plug recommended for ARD headless use; not needed SSH-only.

### 2026-11-05 — AOC produces no EDID (UNRESOLVED)
- AOC yields no EDID via HDMI, via HDMI->USB-C, or through either dock; four
  reboots and mode resets were byte-identical.
- pmset -a displaysleep 0 is NOT a fix - it was already 0 and the failure recurred.
- Treat as physical: AC-out 30s on dock and panel, boot with one dock attached,
  input pinned manually in the AOC OSD. Do not relitigate software.

### 2026-11-05 — MEM-delta graph spike fix (commit `69ce3aa`)
- **Symptom:** Extreme white/grey vertical spikes in MEM-delta graph line during MLX model load/unload (switching Gemma 4 ↔ Flash)
- **Root cause:** Delta multiplier was unbounded `d * 5`; large memory swings from MLX weight swaps amplified to full-height spikes
- **Fix — line 583** (delta calculation):
  ```python
  dlt.append((mem_snap[i][0], min(100, max(0, 50 + min(10, max(-10, d)) * 2.5))))
  ```
- **Fix — line 124** (delta color):
  ```python
  "delta": (80, 80, 95),    # dimmed — spike context only
  ```
- Previous values: multiplier `* 5` unbounded; color `(170, 170, 170)`

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
- Attribution lines at end of every commit message:
  ```
  Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01FrXUfoq33ugWc7b3mZ2nmq
  ```

---

## Quick diagnostics

```bash
# Is monitor running?
pgrep -f mac_monitor

# Is API healthy?
curl -s http://127.0.0.1:9090/api | python3 -c "import json,sys; d=json.load(sys.stdin); print('OK, keys:', len(d))"

# Recent log
tail -20 ~/mac_monitor.log

# Git status
git -C ~/ZuulRulez-monitor status
git -C ~/ZuulRulez-monitor log --oneline -5
```

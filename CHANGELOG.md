# Changelog

All notable changes to the Mac Studio System Monitor are listed here,
newest first. Format: `YYYY-MM-DD — what changed, why, measured result`.

---

## 2026-11-05 — web dashboard bound to loopback; Caddy :9443 is the only ingress

The Flask server ran `flask_app.run(host="0.0.0.0", ...)` on :9090, so with the application
firewall disabled any host on the LAN could read the dashboard unauthenticated in cleartext:
baseline probe `http://192.168.68.105:9090/` returned 200 before the change. Caddy already
reverse-proxied `127.0.0.1:9090` for :9443, so closing the wildcard bind needed no Caddyfile
edit or reload. The fix is committed rather than edited only in `~/.local/bin` because the
deployed file is a copy of `src/mac_monitor.py` on this branch: a deploy from origin would
have silently restored `0.0.0.0`.

One line, `host="0.0.0.0"` -> `host="127.0.0.1"` (line 774, the file's only `0.0.0.0`).
Deployed to `~/.local/bin/mac_monitor.py` and restarted with `launchctl kickstart -k
system/com.user.macmonitor`; no reboot, no plist change, no venv change.

Result on the M5 (14:26): `lsof` shows `127.0.0.1:9090` only, no `*:9090`. Loopback 200;
`curl http://192.168.68.105:9090/` fails with exit 7 (connection refused, 1 ms);
`https://Mach5s-Mac-Studio.local:9443` 200; `launchctl print` state running, runs 1 -> 2,
last exit code 0 (SIGTERM handled cleanly), PID stable at 6903 across a second 15 s check.
Direct :9090 URLs in the module docstring and README were corrected to the `https` :9443
URL in the preceding commit.

## 2026-11-03 — g4 t/s and the TPS graph from mlx-serve; LM Studio code removed

LM Studio was removed from the M5 on Nov 3 (both models now run in mlx-serve), which left the
`g4 t/s` row and the graph's TPS line dead: both were fed only by `lms log stream`. One poller
now reads `/metrics.json` from Gemma (`:11235`) and Flash (`:11234`) every 5 s with the formulas
Flash already used (decode = Δoutput_tokens.sum / Δdecode_time_seconds.sum; live = Δgeneration_tokens_live
/ Δt while running, shown with `~`). Finished-request readings from both models feed the TPS line.
Removed: the `lms log stream` reader, its idle watchdog, the GGUF-rollback check of
`localhost:1234` and the `fls*` label. TPS graph scale 120 → 150 t/s (Gemma now reaches ~142) in
the widget, the web page script and its legend.

Repo hygiene: the background image path was hard-coded as `/Users/<name>/…` and the
`MONITOR_*` variables in `env.example` were never read. The script now loads the env file
named by `MONITOR_ENV_FILE` (set in the LaunchDaemon plist) or `~/.config/macmonitor.env`,
and takes `MONITOR_BG_IMAGE`, `MONITOR_HISTORY_FILE`, `MONITOR_STATE_FILE`, `MONITOR_G4_URL`,
`MONITOR_FLS_URL` from it (same defaults as before).

Tested in the workspace against two stub mlx-serve endpoints: live 140 / 90 t/s with `~`, decode
rates kept after requests finish, down server `—` (dark), idle server grey, graph points from both
models; env file values picked up; `/api` returns the new G4/FLS fields.

Result on the M5 (17:24): after the restart both rows showed grey `—` (servers up, no request yet);
one 200-token request to each server gave G4 139.9 t/s (200 tokens / 1.43 s decode) and FLS 154.4 t/s
(200 / 1.30 s; counting in words is easy for MTP), both rows bright; daemon log clean.

---

## 2026-10-17 — MBP monitor vertical mini strip

Propagated vertical mini strip layout from Studio monitor to MBP monitor.
Rows stack top-to-bottom: MEM · GPU · SWP · BAT · ▼ expand (130 × 110 px).
Replaced horizontal MINI_HEIGHT bar; added MINI_WIDTH / MINI_ROW_H constants.

---

## 2026-10-16 — Initial repo import

Imported working monitor source into `M-ProcessorSystemMonitor` branch.

### Features at import

- **Desktop widget** — tkinter overlay on `#08080f` background, 360 × 455 px,
  12 stat rows, PIL-rendered graph (10 h window, Y-axis auto-zoom).
- **Web dashboard** — Flask server on port 9090, live-polling canvas graph,
  same 10 h window, WCAG 2.1 AA colour contrast throughout.
- **Stats displayed** — CPU USE, RAM, MEM pressure, SSD, GHz, GPU residency,
  PWR (mW), SWP, THM (thermal), EFF (%/W), g4 t/s, fls t/s.
- **LMS real-time t/s** — passive throughput from `lms log stream`, per-model:
  `g4` (Gemma-4-26B-A4B-IT-QAT, ~80–118 t/s) and `fls` (Flash-Next, ~28–48 t/s).
  Idle watchdog demotes Active → Idle after 30 s of silence.
- **Graph lines** — MEM (colour by pressure), SWP (orange), GPU (light grey,
  background), MEM-Δ (grey), EFF ÷500 (blue), TPS ÷125 (violet).
  GPU intentionally muted so coloured lines dominate visually.
- **Y-axis auto-zoom** — graph scales to the visible data range ± 5 %,
  minimum 10 % span; grid labels show actual percentage values.
- **Repo hygiene** — personal paths (`BG_IMAGE`, `HISTORY_FILE`, `STATE_FILE`)
  moved to env vars loaded from `~/.config/macmonitor.env` (gitignored).
  LaunchDaemon shipped as a template with `%%PLACEHOLDER%%` markers.

### Known behaviour

- `g4 t/s` and `fls t/s` show the *last recorded* throughput for each model
  (retained up to 1 hour). Both rows dim when LMS is Idle or Off.
- `GHz` shows `N/A` when `powermetrics` P-cluster frequency is unavailable.
- Background image path must be set in `~/.config/macmonitor.env`;
  the widget runs without it (transparent background fallback).

## 2026-11-01 — ARD typing lag diagnosed and resolved (Mac Studio M5 Max)

**Symptom:** 2-3s keyboard lag when typing via Apple Remote Desktop after Golden Gate 27.2 + Xcode update.

**Diagnosis:** `system_profiler SPDisplaysDataType` showed only a "Screen Sharing Virtual Display" — the AOC U2790B (connected via DP 1.2 through CalDigit TS3+) had slept and macOS dropped it, falling back to a screensharingd virtual framebuffer. WindowServer logs showed repeated `failed set_cursor_surface` errors against the virtual display, stalling ARD input event dispatch.

**Fix:** Connected AOC directly via HDMI (Mac Studio HDMI 2.1 port). Real hardware display restored; virtual display gone. ARD cursor compositing works correctly against a real framebuffer.

**Prevent recurrence:** `sudo pmset -a displaysleep 0` — keeps display signal active so macOS never drops the real display and falls back to virtual.

**Note for headless deployments:** Any Mac running without a physical display will exhibit this ARD lag. Use an HDMI dummy plug (4K@60Hz rated) to give macOS a real framebuffer. Confirmed needed for M1 Studio Max shipping as headless Gemma 4 LLM server.

## 2026-11-05 — display path regressed; Studio is headless (addendum to the ARD entry)
- The HDMI + `pmset displaysleep 0` mitigation above has failed. AOC trains at
  firmware, dies at macOS handoff; no HID activity wakes it. Four reboots: no change.
- `displayplacer` lists only the Screen Sharing virtual display. WindowServer's
  displays plist has no AOC entry: no EDID completion, no cached mode to reset.
- Two Thunderbolt docks attached — ACASIS TB501Pro (fw 62.62) and CalDigit TS3 Plus
  (fw 44.1). DP alt-mode allocation spans both and clears only with AC removed.
- Holds so far: `displayplacer id:15C9F10C-0D98-43BA-B726-77AD38EFFF11
  res:1920x1080 hz:60 color_depth:4 scaling:off` — ARD encodes true 1080p instead
  of 3840x2160 HiDPI. Re-verify after each new Screen Sharing session.
- `sudo pmset -u sleep 0` applied.
- Also 2026-11-05 (was undocumented, code-only in `69ce3aa`): MEM-delta line no
  longer produces full-height white spikes on MLX weight swaps. Delta is clamped
  to +/-10 before the 2.5x scale (`src/mac_monitor.py:583`) and the delta colour
  is dimmed from `170,170,170` to `80,80,95` (`src/mac_monitor.py:124`).
- Correction to the entry above: `sudo pmset -a displaysleep 0` is NOT a
  prevention. `displaysleep` was already 0 on every profile when checked, and the
  failure recurred anyway. Do not treat it as a fix.

## 2026-11-06 — JS web graph delta clamp fix (Mac Studio M5 Max)
Symptom: Web dashboard graph frozen — y-axis zoom broken by out-of-range delta values from unbounded *5 multiplier.
Fix: JS canvas delta now matches PIL fix: clamp to ±10, scale by 2.5. Both graphs now consistent.

## 2026-11-08 — Lifetime-max display for t/s and power
- Added `_max_tps` dict and `_max_pwr_mw` float globals tracking peak values since daemon start
- Web dashboard shows full form: `117.3 (max 117)` / `629 mW (max 7293 mW)`
- Desktop GUI shows compact form: `117.3 (117)` / `629 (7293) mW`
- `get_model_display()` and `get_cpu_power()` accept `compact=False` param
- Commit: 70bd88f

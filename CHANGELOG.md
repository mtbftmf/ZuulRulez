# Changelog

All notable changes to the Mac Studio System Monitor are listed here,
newest first. Format: `YYYY-MM-DD — what changed, why, measured result`.

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

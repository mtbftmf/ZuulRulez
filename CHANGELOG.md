# Changelog

All notable changes to the Mac Studio System Monitor are listed here,
newest first. Format: `YYYY-MM-DD — what changed, why, measured result`.

---
## 2026-11-18 
- mbp_monitor: 3-thread cadence split (power ~17s / mem 5s / battery 60s), Combined-Power parse, sudo -n, persistence decoupled from GUI + _pwr_history restored across restarts, GPU stale-repeat set None on miss (divergence from Studio's reviewed cosmetic-no-fix position; MBP's slower cycle justifies), peaks engine (schema 1, file-only) — engine landed in this commit via hunk fusion; PKV display deferred. NOTE: _load_peaks() startup call lands in the display commit; this checkout alone does not reload peaks — never deployed standalone. Measured: staged blob compiles standalone; additions scan 0; all three peaks defs staged.
- mbp_monitor: env-file loader, env-overridable paths (incl. new MONITOR_PEAKS_FILE), schema 1 constants, Combined-Power regex + state scaffolding — declarations only. env.example gains MBP block; Studio placeholder paths moved to ~/ style. Measured: 28/28 anchors unique; staged blob py_compile standalone; additions scan 0; tracked env.example now 0 /Users/ hits.

## 2026-11-15
- peaks schema v3: per-model max_tps_ts stamped only on a new high; version-aware _load_peaks null-patch (schema-2 files keep max_pwr_ts); verified at boot PID 38567, stamp 2026-11-15T16:38:34 preserved.
- mlx peak/decode ratio: gate `decode_tps`, the lifetime peak and the TPS graph to intervals where
  `requests_running <= 1` at both polls. `d_out / d_dec` divides deltas of two histogram families and
  `/metrics.json` is rendered family-by-family, so a poll landing between the `output_tokens` write
  and the `decode_time_seconds` write charges one completion's decode time against two completions'
  tokens and the ratio doubles. `fls` recorded 111.64 = 2 x 55.8 (measured two-up per-stream 55.5 and
  56.1) during today's load test; the earlier 164.86 = 2 x 82.4 against a lifetime mean of 83.5. The
  origin given in the entry above — high MTP acceptance on a short completion — was wrong, and
  `MLX_PEAK_MIN_TOK` never addressed it. A per-stream rate is only defined for one stream; under
  concurrency the row shows only the live box aggregate and its `n=`. Verified both directions: a
  solo 800-token run published 94.55 with the row at 91.4/95 against the server's own 91.382, and a
  two-request run left the stored peak byte-identical. Solo tearing can still skew a reading a few
  percent — it cannot double it. Peak and last rate are now explicitly solo statistics and the TPS
  graph has deliberate gaps under load. Compact display drops the peak and the decimals so `~113 n2`
  fits MINI_WIDTH (130 px).

- mlx display: emit the `~` prefix the docstring already promised for a live rate. The
  `generation_tokens_live` gauge flushes in ~2 s lumps, so its relative error is flush/span —
  measured ±110 % at a 2 s poll (130.6 against a true 109) and ±27 % at the 8 s window
  (99.4, 104.4). No span that fits inside a normal generation gives better than ~25 %; the
  decode ratio at completion is exact and reads 55.5-56.1 tok/s per stream under two-up load.

- mlx live t/s: sample over a rolling span >= `MLX_LIVE_WINDOW` (8 s), stamp the clock after the fetch
  rather than before it, and label the row with the mean concurrency of that span.
  `gauges.generation_tokens_live` flushes ~220-token lumps every 2.0-2.55 s (see the Nov 15
  `llm-rate-probe.py` entry in MacLLM), so the old 5 s division was quantization; stamping before two
  blocking fetches let a slow poll divide an ~8 s gauge gap by `dt = 5`, up to 1.6x; and the
  instantaneous `requests_running` label read `n=1` on a span that was mostly two-up. Measured after
  the window fix: `99.4 n=2` and `104.4` against a true aggregate of ~105-109, nothing above 130. The
  mean-concurrency label shipped in the same change and is re-measured next load test.
- mlx peak: a completion must emit >= `MLX_PEAK_MIN_TOK` (64) tokens to set the lifetime peak. `fls`
  had pinned at 164.9 against a lifetime mean of 83.5 (9,678 tok / 1,159.7 s over 43 requests); a short
  completion with very high MTP acceptance reaches a rate no real traffic does, and the warmup
  `repeat_token` run is the suspected origin, unconfirmed. Stored `fls` peak purged, one 800-token
  generation re-baselined it at 89.4. `decode_tps` and the TPS graph still record every completion.

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

## 2026-11-08 — PKG label and 5s power sampling
- Renamed PWR→PKG in web dashboard and desktop GUI (SoC package power: CPU+GPU+ANE, not wall power)
- Reduced PM_INTERVAL 15s→5s for better peak resolution on _max_pwr_mw

## 2026-11-08 — PKG power graph series
- Added _pwr_history (5s samples) persisted to mem_history.json
- Gold PWR÷20W line added to web dashboard graph and legend
- Scale PS=20000 mW (20W = 100%) gives good headroom for M5 Max workloads

## 2026-11-08 — Persist lifetime-max peaks across restarts
- Added PEAKS_FILE (~/.local/share/macmonitor_peaks.json)
- Stores _max_tps (per model) and _max_pwr_mw; loaded at startup, written only when a new peak is set
- Peaks now survive daemon restarts and reboots

## 2026-11-08 — Combined Power regex, scales, scoping bug, ⚡/🧠 labels
- CPU_PWR_RE now matches "Combined Power (CPU + GPU + ANE)" instead of "CPU Power" — GPU dominates MLX inference at 46-53W; old regex read CPU-only ~5-7W (~10x underreport). Verified: ⚡ now shows 49-64W during generation.
- Fix UnboundLocalError: 'now' used in _pwr_history.append() before assignment; renamed to _now_pwr. This crash caused powermetrics poller to skip vm_stat every cycle, leaving MEM/GPU/SWP/THM/T/W all stale.
- _save_peaks() adds max_pwr_ts timestamp for audit trail.
- collectV(pwr,PS) removed from JS y-axis zoom — power spikes were rescaling all percentage series.
- PS=80000 (80W headroom; was 20000). EFF_GRAPH_SCALE=10.0 and JS ES=10 (was 500).
- PWR/W label → ⚡ (single char, frees column width). MEM label → 🧠 (MEMBRAIN), value reverts to pressure min/cur/max string now that poller no longer crashes.
- Commit: 5e4296f

## 2026-11-08 — EFF (GPU%/W) replaced by T/W (tok/s per watt)
- GPU residency pins at ~99.9% during any MLX load, making GPU%/W nearly constant and uninformative.
- get_efficiency() now returns combined tok/s across all active MLX servers divided by combined SoC watts.
- _eff_history populated from combined tps/W during active generation windows only (30s recency guard).
- EFF_GRAPH_SCALE=10 unchanged; at 141 t/s / 49W = 2.9 tok/s/W = 29% of graph.
- Labels updated: stat row T/W, legend T/W ÷10, graph title T/W.
- Commit: fb51a48

## 2026-11-08 — T/W combined tps, 5W power floor
- T/W now sums decode_tps from all MLX servers active in last 30s instead of last _tps_history entry (single model, last-writer-wins).
- Power floor raised 10mW → 5000mW: prevents nonsense readings when powermetrics samples at idle between bursts.
- Verified: 3.2 tok/s/W at 39W with g4+fls both active (126 t/s combined); shows … at idle.
- Peak PWR updated to 64.5W.
- Commit: d942c3f

## 0eb4881 — T/W window fix, current-power gate, PS=100000 (2026-11-08)

**Problem 1 — T/W window mismatch (Flash's catch):**
`get_efficiency()` summed tps for models active in last 30s but divided by
the *instantaneous* 5s power sample. A model that finished generating 29s ago
still contributed tokens but zero watts → inflated T/W.
Fix: average `_pwr_history` over the same 30s window (`[-6:]` to cap at 6
samples × 5s). Same fix applied to `_eff_history` append.

**Problem 2 — stale T/W after generation ended:**
30s window average lagged real-time; T/W showed 1.9 tok/s/W at 0.6W idle.
Fix: added `if m < 5000: return "…"` gate on current instantaneous power
(`_state["cpu_power_mw"]`).

**Problem 3 — PS=80000 almost clipping:**
Peak of 78.4W = 98% of 80W scale.
Fix: PS raised to 100000 (100W); legend updated to `⚡ ÷100W`.

**Verified:** T/W: 3.2 tok/s/W at 32.5W during generation; `…` at idle/post-gen.
Peak PWR: 78.4W (new high, 5s average).
## Unreleased

- `src/mac_monitor.py`: track daemon source with Path.home()-derived defaults and wrapper call site.
- `sudoers.d/mac-monitor.example`: add placeholder sudoers rule for the pinned wrapper.
- Peaks provenance: seed samplers and wrapper metadata; add sampler sentinel.

## 2026-11-16
S15730: schema 3 (8ecdcc8) live in daemon PID 2946. First max_tps_ts stamp
(2026-11-16T08:21:01, value 151.1458) quarantined as tear class 3 - completion-boundary
interleave; gate now 0-for-3 at boundaries. Purge 3 executed bootout-first with pgrep
empty; non-resurrection proven by the daemon 08:33 self-heal write (fls 97.6388, ts map
empty). Solo-gate plausibility guard remains OPEN (reject candidates above ~1.3x recent
tps_history median, or require ratio re-read before promotion).
## 2026-11-16 (guard)
Peak plausibility guard deployed 09:21: reject d_cnt>=2 completion-boundary
interleaves, plus candidates above 1.3x median of last 20 solo rates; stalled
count counter degrades to median-only per the known unreliable-count builds.
Validation: first post-quarantine candidate 124.3255 at 09:13:59 (pre-guard
daemon) confirmed class 4 tear - exceeds measured dual-stream aggregate ~110 -
purged bootout-first, sidecar sealed. Both checks reject it in replay.

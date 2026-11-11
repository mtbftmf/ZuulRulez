# ZuulRulez Monitor — Session Context

> Feed this file to any LLM session before working on the monitor code.
> Last updated: 2026-11-08 (session 5)

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
- Port 11234 — Flash-Next (fls), workhorse for deep reasoning, 73.7 GiB resident
- Port 11235 — Gemma 4 (g4), router/vision/tasks (26B MoE), evicts when idle

### Memory
- 128 GB unified memory
- Flash-Next: 73.7 GB resident (IOAccelerator/Metal); 4,384 KB ever swapped
- Gemma 4: ~16.0 GB resident when loaded
- **Both simultaneously resident: ~90 GB** (74.1 + 16.0 GiB, confirmed via vmmap)
- n-gram table: 29.9 GB virtual, 7 MB resident (clean mmap, kernel-reclaimable)
- phys_footprint: 75 GiB / phys_footprint_peak: 86 GiB (11 GiB gap = table read then reclaimed)
- SWP: 281 MB of 411 MB total attributed to pids 975+981 — working-set signal, not noise
- Display SWP as absolute MB; the "/2G" denominator is dynamic backing-store, not capacity
- **Do NOT run vmmap OR footprint during a measurement window** — both suspend the target

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
| Sustained generation | ~49 W | Combined SoC (CPU+GPU+ANE); DRAM excluded |
| Peak (5s average) | **92.6 W** | Post-regex-fix only (pre-5e4296f entries are CPU-only); `max_pwr_mw` 92615, max_pwr_ts 2026-11-11T07:33:30, read from `~/.local/share/macmonitor_peaks.json`. Set during the `llm-bench.py --sweep 100000,130000,185000` run (07:30-07:37); the benchmark does not stamp its steps, so which step is not known. Previous peak 85.0 W (2026-11-09T08:41:27). |
| Wh/1k tokens | **0.0408 Wh/1k** | Measured 2026-11-09; flash-next :11234 decode-only; 8,000 tokens; 58.8 W median SoC; 41.2% powermetrics coverage; DRAM excluded; lower bound. |
| T/W at load | ~3.2 tok/s/W | g4+fls combined, 126 t/s / 39W |
| Models on disk | 100G + 15G (GiB) | `du -shL` symlinks |
| Flash weight files | 70.1 GiB (75.3 GB decimal) | safetensors index byte sum |
| Flash + ngram on disk | 70.1 + 27.8 = 97.9 GiB ≈ du's 100G | confirms GiB unit |
| Both models resident | ~90 GiB | vmmap: 74.1 GiB (pid 975) + 16.0 GiB (pid 981) simultaneously |
| Flash ever swapped | 4,384 KB | vmmap swapped column — negligible |
| RAM at load | 102.7/128 GB | vm_stat; two instruments agree on ~90 GiB model residency |
| Thermal | Nominal | No throttling observed |

Post ¶4/¶7 — observed-peak framing (permanent; ceiling framing superseded 2026-11-08):
*"One box, one cable, no rack: the chip's own draw sits around 49 W sustained through generation (combined SoC package), and the highest five-second reading on record is 92.6 W — under a desk, not in a closet."*

**49 W sustained** is the anchor: identical across every verified measurement table. Does not move.
**82.7 W** = highest five-second reading on record. "On record" is exact — persistence shipped
  2026-11-08 with the file created immediately after deploy; the window is hours old, not lifetime.
  Keep "five-second" attached every time — the interval is what makes the number defensible.

Provenance of 82.7 W — established by magnitude, not timestamp:
- Pre-fix regex matched ^CPU Power:, worth 5–7 W during MLX inference
- Combined Power was 50–64 W simultaneously; no pre-fix parse could reach 82,706 mW
- Because pre-fix readings ran ~10x too low, any post-fix generation reading instantly
  overwrote the file — 82.7 W is reachable only by the corrected parse
- max_pwr_ts shipped in the same commit as the regex fix and dates nothing on its own

Semantics caveat: max_pwr_ts is written by _save_peaks() on any new peak (TPS or power),
so it may be a save stamp, not a power-sample stamp. Optional tightening: assign it only
in the power-peak branch (one-line change; deliver as a Python script per standing rule).

Peak series (all 5-second averages): 64.2 → 64.5 → 78.4 → **82.7 W**

Superseded — for the record:
Sessions s5/s6 prescribed "nothing over 80 W in five-second samples" because peaks kept
moving as fixes landed. The box hit 82.7 W. That is the ceiling framing's defect demonstrated
on live data: any stated ceiling is a falsifiable claim against a distribution still being
sampled, in a comment thread that cannot be edited. Observed-peak wording is permanent.

max_tps g4 120.3 / fls 103.2 (from peaks file) — NOT upper bounds.
_max_tps was session-only and reset on every restart until persistence landed at 27b5862,
with ~8 deploys that day. s3 stat row shows fls 57.6 (max 81) in the same table as
RAM 102.7 GB. Do not cite 103.2 against any throughput claim. Use conservative 100 tok/s.

PS scale check closed, no action: PS moved 20000 → 80000 → 100000; 82.7/100 puts the
gold line at 83% of scale, no clipping.

PCIe framing dead: 82.7 W > 75 W PCIe slot supply.
Idle power (0.1–0.3 W) is SoC package idle, not system idle — drop from post.

### 2026-11-08 — T/W window fix + current-power gate + PS=100000 (0eb4881)
- T/W window mismatch: tps window was 30s but power was instantaneous 5s sample.
  Fixed: `get_efficiency()` and `_eff_history` both average `_pwr_history[-6:]` (30s).
- Added `if m < 5000: return "…"` gate on current instantaneous power — prevents
  stale 30s window from showing non-zero T/W at idle after generation ends.
- PS raised 80000→100000 (old 80W was 98% utilised at 78.4W peak).
- Verified: 3.2 tok/s/W at 32.5W; `…` at idle. Peak: 78.4W.

---

## Flash-Next architecture — fully measured from tensor shapes (2026-11-08)

All numbers weight-side confirmed from safetensors index unless marked.

```
model_type:            qwen4_exp (Qwen4ExpForConditionalGeneration)
num_hidden_layers:     48 (confirmed: indices 0–47, all carry switch_mlp)
num_experts:           512
num_experts_per_tok:   10
moe_intermediate_size: 640
hidden_size:           2560
attention:             linear_attn (SSM-style: A_log, dt_bias) — NOT standard self-attention
                       present in 36 of 48 layers; 12 layers use a differently named path
MTP:                   own decoder block (language_model.mtp.layers.0.*); enabled in server config
vision:                333 tensors, 0.45B BF16 params, 0.90 GB — not read during text decode
language_model_only:   False (vision tower in weights)
tie_word_embeddings:   False (embeddings and lm_head are separate, both quantized)
dense layers:          NONE — 144 expert tensors under model.layers (3 × 48)
```

**Expert pool (tensor shapes):**
switch_mlp.gate_proj.weight = U32 [512, 640, 320]; scales = BF16 [512, 640, 40]
Inner dim = 40 × 64 = 2560 ✓ (matches hidden_size)
One matrix: 512 × 640 × 2560 = 838.9M params; × 3 × 48 = **120.8B** (main layers)
Including MTP block: 147 expert tensors = 3 × 49 → **123.31B**
Scale-group route: 1.93e9 × 64 = 123.3B — agrees exactly when MTP counted

**Quantization (measured as bytes ÷ scale_groups × 64):**
- switch_mlp (routed experts): **0.500 B/param → 4-bit**
- router gate, shared_expert, linear_attn, hyper-conn: **1.000 B/param → 8-bit**
- group-64 affine throughout; expert metadata: 8.04 GB (scales + biases)
- 67.28 GB weights + 8.04 GB metadata = 75.32 GB ≈ 75.30 GB measured ✓
- "mixed-4-8bit" pack name is literally accurate: 4-bit experts, 8-bit everything else

**Parameter budget:**
| Bucket | Params | B/param |
|---|---|---|
| expert (switch_mlp, 48+MTP layers) | 123.31B | 0.500 |
| attn (linear_attn) | ~2.1B | 1.001 |
| shared expert | 0.24B | 1.001 |
| gate (router) | 0.06B | 1.000 |
| hyper-conn | 0.66B | 1.008 |
| ple | 0.03B | ~1.0 |
| q_emb (MTP/embed, quantized) | ~1.95B | mixed |
| bf16_vision | 0.45B | 2.000 |
| bf16_other (norms) | ~0 | 2.000 |
| **TOTAL** | **~128.8B** | |

NOTE: per-family attn/ple/hyper/q_emb splits are approximate (regex leak in bucket script);
totals are reliable. Do not publish per-family figures.

**s6 stale errors — do not inherit:**
- "48 × 10 × 3 × 640 × 2560 ≈ 7.9B active": the value is wrong, the formula is not — it already
  counts 10 experts per layer, so there is no missing ÷512 (that would give 4.6M). The product is
  2,359,296,000 = 2.36B. Publish "2.4B routed expert parameters active per token"; never "2.4B
  active" unqualified.
- "610 GB/s corroborated" / "Flash is saturating the bus": derived from the same bad 7.9B value,
  and "corroborated" against a 400 GB/s ceiling the same paragraph already exceeds — a reading
  cannot corroborate a ceiling it surpasses. Publish NO bandwidth figure, range or utilization %:
  bytes/token is underdetermined (MTP acceptance rate) and no measured ceiling for this chip
  exists in the record. The elimination argument needs no ceiling, which is why it is the only
  bandwidth-adjacent claim in the post. Never pair a GB/s figure with a ceiling in a reply.
- "57 collections / all file-*": superseded by 62 collections / 8,736 vectors plus an 11-vector
  memory store. "all file-*" was a tautology of the query filter (name LIKE 'file-%'), not a
  finding — a NOT LIKE 'file-%' query returns user-memory-*. State the scope whenever a Chroma
  count is quoted, and do not present 57 → 56 → 62 as one continuous verified series.
- "Total expert pool at 4-bit ≈ 100B+": superseded by tensor-shape measurement (~121B across the
  48 main layers, ~123B including the MTP block). Do not republish 100B.
- "70 GB of 4-bit weights" (s6 ¶3 post copy): superseded. Flash is 73.7 GB resident, 4-bit on the
  routed experts and 8-bit on the non-expert quantized components.
- Hook "115 GB of model weights on disk": wrong noun and wrong units. 115 GB is model FILES from
  du -shL (GiB) ≈ 85 GB weights + 30 GB n-gram table. du reports GiB; safetensors sums are
  decimal. The shipped post uses the corrected wording.
- Post-copy attribution reads "(Claude)"; every commit trailer reads "Co-Authored-By: Claude
  Sonnet 4.6". Published attribution is Claude Sonnet 4.6 only — no other model, in any channel.

**Per-token read estimate:**
- 2.36B routed experts + ~3.1B always-read (attn, shared, hyper, router) ≈ **~5.4B per forward pass**
- Do NOT publish a utilization percentage or "not saturating"
- max_tps.fls = 103.2 from peaks file — NOT an upper bound; _max_tps was session-only and
  reset on every restart until 27b5862 (~8 deploys that day). Do not cite 103.2 against
  any throughput claim. Use conservative 100 tok/s in all published arithmetic.
- Elimination argument: 73.7 GB × 100 tok/s (conservative) = 7,370 GB/s ≈ **7,400 GB/s** needed
  No Mac has that. Sparsity proven by elimination, indifferent to true throughput figure.
  Units note: 73.7 GB is the vmmap IOAccelerator figure for Flash's resident weights [s6], and
  vmmap size columns are binary (GiB). Read as GiB that is ~79.1 GB decimal, so the dense-read
  requirement rises to ~7.9 TB/s — it never falls. The safetensors decimal sum of all tensors
  is a DIFFERENT quantity (every tensor incl. scales/biases, not just resident weights) and
  must not be cited as the source of 73.7. "7,400 GB/s" is conservative under either reading;
  nobody should "correct" it upward to match the binary interpretation.

**Units (pinned):**
75.3 GB decimal = 70.1 GiB safetensors + 27.8 GiB ngram_table.bin = 97.9 GiB ≈ du's 100G
Hook: "85 GiB of weights plus a 30 GiB lookup table" is correct (70.1 Flash + ~15 Gemma ≈ 85)
Always state GiB when citing du output; use decimal GB for index byte sums.

**Architecture notes for future sessions:**
- Expert tensors: `mlp.switch_mlp.*`, NOT `mlp.experts.N.*` — standard regex finds nothing
- PLE is one module per layer (not per-layer embedding tables)
- MTP at `language_model.mtp.layers.0.*` explains the 49th expert block
- DRAM excluded from powermetrics Combined Power — confirmed: https://developer.apple.com/forums/thread/709276

---

## Knowledge base (Open WebUI, confirmed 2026-11-08)

| Store | Collections | Vectors | Notes |
|---|---|---|---|
| Knowledge base (file-*) | 62 | 8,736 | Uploaded documents; real index |
| Memory (user-memory-*) | 1 | 11 | Extracted facts from conversations |

Source: `~/open-webui-data/vector_db/chroma.sqlite3` join query

---

## Pending

1. **Cold prefill measurement** — 12K persona prefill + 24K deep-work generation.
   CRITICAL RULES:
   - Do NOT run `flash-up.sh` first — it starts, warms and checks both servers, spending the cold cost
   - Restart LaunchAgents directly; treat request 1 as the sample
   - Ban covers BOTH `vmmap` AND `footprint` during the window (both suspend the target)
   - `footprint` is the source of the 75/86 GiB phys_footprint pair — do not run it in-window
   Run powermetrics:
   ```zsh
   sudo powermetrics -n 240 -i 5000 --samplers cpu_power,thermal_power_source | tee /tmp/pm_peak.log
   grep -iE 'combined power|thermal|speed limit|pressure' /tmp/pm_peak.log | sort -u
   ```
   (-n 240 = 1200s; covers ~170s workload with margin)

2. **`_thm_history`** — record thermal pressure using `thermal_power_source` sampler
   (NOT `thermal` — that sampler name is invalid)

3. **Wh/1k tokens (real)** — integrate `_pwr_history` over known generation window ÷ token count
   from `/metrics.json`. Label: "SoC package energy per 1,000 tokens — lower bound, DRAM excluded."

4. **SWP display** — change from "0.5/2G" to absolute MB; denominator is not a capacity.

5. **Post length check** — after tagging [Name]: `pbpaste | wc -m` against 3,000-char limit.

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

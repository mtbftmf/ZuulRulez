# M5 Max System Profile (Flash-Next workhorse)

Applies ONLY to the M5 Max Studio 128 GB host. Generic M-series Studios running the
Gemma 4 build for friends-and-family hosting (houdini account, `m1/` scripts) do not
use any of this: no Flash-Next, no mlx-serve, no 128 GB memory budget.

Current as of 2026-10-25. Dated history is in `CHANGELOG.md`; the switch from the
LM Studio GGUF to mlx-serve is planned and tracked in `M5_MAX_MLX_SWITCH_PLAN.md`.

## Model and engine

| Item | Setting |
| --- | --- |
| Model | Qwen3.8-Flash-Next, MLX pack `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit`, identifier `flash-next` |
| Files | Hugging Face cache snapshot, linked as `~/.mlx-serve/models/flash-next` (the link name is the model id). 94.7 GB: ~100 weight shards (~65 GB), `ngram_table.bin` (30 GB), `model-vision.safetensors` (856 MB); MTP head inside the shards |
| Quant | 4-bit affine (mixed 4/8-bit); arch `qwen4_exp` (48 layers: Gated DeltaNet 3:1 with Qwen Sparse Attention, 512-expert MoE, 10 routed + 1 shared) |
| Engine | mlx-serve 26.10.3 (MLX 0.32.3), Homebrew tap `ddalcu/mlx-serve`, `brew pin`ned |
| Server | `127.0.0.1:11234` only (the mlx-serve default is `0.0.0.0`), OpenAI-compatible `/v1`, `/health`, `/metrics.json` |
| Process | LaunchAgent `com.$USER.mlx-serve` (KeepAlive, ThrottleInterval 30), template `m5/launchd/mlx-serve.plist.template` |
| Logs | `~/.mlx-serve/logs/mlx-serve-11234.log` (rotates at 32 MB), `~/Library/Logs/mlx-serve.log` |
| Storage | Internal drive. Never on the external RAID0 (the 30 GB n-gram table is memory-mapped; the stripe has no redundancy) |
| Rollback | AtomicChat `Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64` GGUF (88 GB) in LM Studio, `FLASH_BACKEND=gguf` in `~/.config/macllm.env`. Kept until two weeks after the switch |

## Server flags (`mlx-serve.plist.template`)

| Flag | Value | Why |
| --- | --- | --- |
| `--host` | `127.0.0.1` | The default binds the whole LAN |
| `--ctx-size` | 131072 | Same 128K as the GGUF; native max 256K |
| `--mtp` | on | Native MTP head: 67 → 92 tok/s for ~4.7 GB wired |
| `--no-pld` | off | Prompt-lookup drafting not measured; MTP outranks it anyway |
| `--max-concurrent` | 2 | A second Flash chat starts at once (each ~51 tok/s, 100.6 total) instead of queueing |
| `--metrics` | on | `/metrics.json` for the System Monitor |
| `--ple-gpu` | not set | Keeps the n-gram table mmapped (CPU gather) instead of 30 GB resident |
| `--prefix-cache-disk` | not set | SSD prefix tier off; hot cache ~5.2 GB (one 128K session) |

mlx-serve picks its own prefill chunk from free memory (2048 tokens at load on Oct 24) and
plans against a 110 GB wired budget internally; `iogpu.wired_limit_mb` stays 0 (default).

## Reasoning effort

- mlx-serve turns thinking **off** unless the request turns it on. With thinking off Flash
  answered a two-step price question wrong ($83.33 instead of $75.00, Oct 24).
- Every path sends `chat_template_kwargs` `{"enable_thinking": true, "reasoning_effort": "medium"}`
  (`xhigh` for deep work): Auto Router v1.4.1 (valves `STRONG_THINKING`, `STRONG_EFFORT`,
  `DEEP_EFFORT`) and every Flash-* persona (custom parameter `params.custom_params`; Flash-IT-Deep
  `xhigh`). Copy to new personas with `REF=muse-general PARAM_KEYS=custom_params owui-sync-flash.sh`.
- The template is the stock Qwen one in the pack (`chat_template.jinja`): default xhigh when
  `enable_thinking` is undefined, `low`/`medium`/`xhigh` accepted. `[effort:...]` markers do nothing here.
- Effort is a nudge, not a budget (Oct 18-19 probes on the GGUF; Oct 24 on MLX medium used more
  tokens than xhigh on a short question). `max_tokens` is the real time limit: Auto caps Flash
  medium 8192, Flash xhigh 24576, Gemma none.

## Measured (Oct 24-25)

| | Value |
| --- | --- |
| Decode | 93.5 tok/s (no MTP: 67.2) |
| Decode @ 28K context | 88.3 tok/s |
| Prefill @ 7.8K | 2,506 tok/s |
| Time to first token | 268 ms; 11.3 s @ 28K |
| Prefix cache, 11,989-token prompt repeated | TTFT 5.75 s → 0.11 s |
| Gemma busy with image requests at the same time | Flash 56.8 tok/s (44.9 @ 28K), Gemma 49.1 tok/s |
| Two Flash requests at once | 51.5 tok/s each, 100.6 total |
| Test 1, bare API prompt, medium | ~62 s for ~5.6K tokens (GGUF ~105 s, same length) |
| First request after reboot without warm-up | 4.3 s (next 0.96 s); `flash-up.sh` warm-up takes it at login (4 s) |

GGUF on LM Studio for comparison: 48.4 tok/s decode, 934 tok/s prefill, 45.3 @ 28K, 31 s TTFT @ 28K.

## Memory

| State | Wired (whole system) |
| --- | --- |
| Idle, both models loaded | ~18 GB (mlx-serve releases wiring when idle) |
| Flash generating | ~88-98 GB |
| Flash + Gemma both busy | peak 101.7 GB |

No swap growth and pressure normal in every test. The n-gram table (`ngram_warm_bytes`, ~32 GB)
lives in the page cache, not wired memory, so `top`'s "used" sits near 126 GB. Flash process
memory: `memory_mb` ~75 GB in `/metrics.json`. After a reboot, before any request, macOS
compressed the idle weights (41 GB compressor); a long idle under memory pressure can do it again,
costing one ~3-4 s request.

## Metrics (`GET http://127.0.0.1:11234/metrics.json`, mlx-serve 26.10.3)

Sections: `counters`, `gauges`, `decode_serial`, `histograms`, `sessions`.

| Want | Fields |
| --- | --- |
| Decode tok/s per completed request | Δ`histograms.output_tokens.sum` / Δ`histograms.decode_time_seconds.sum` |
| Prefill tok/s | Δ`histograms.prompt_tokens.sum` / Δ`histograms.prefill_time_seconds.sum` |
| Live throughput | Δ`gauges.generation_tokens_live` / Δt while `gauges.requests_running` > 0. `generation_tokens_live` is the cumulative count updated per token (completed + in-flight); `counters.generation_tokens_total` catches up when a request finishes (both 519 at idle on Oct 25). Do not add them |
| TTFT, end to end | `histograms.time_to_first_token_seconds`, `histograms.e2e_request_latency_seconds` (Δsum / Δcount) |
| Load | `gauges.requests_running`, `requests_waiting`, `requests_prefilling`, `gpu_utilization_pct` |
| Memory | `gauges.memory_mb`, `mlx_active_bytes`, `mlx_cache_bytes`, `ngram_warm_bytes` |
| Prefix cache | `counters.prefix_cache_hits_total` / `prefix_cache_queries_total` |

Histograms have `count`, `sum`, `bounds`, `bucket_counts`.

## Open WebUI memory text

Source text for the Open WebUI memories about this host (Settings → Personalization → Memory).
Replace the older Flash-Next memories (engine, effort, measured performance) with these.

1. M5 Max Flash-Next engine: Flash-Next (`flash-next`) runs on mlx-serve 26.10.3 (MLX pack
   ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit) at 127.0.0.1:11234, LaunchAgent
   com.$USER.mlx-serve, 128K context, MTP on, 2 concurrent requests, metrics at /metrics.json.
   Gemma 4 26B-A4B QAT stays on LM Studio at localhost:1234 (32K). Open WebUI has both
   connections. flash-up.sh starts both, warms Flash and checks them; FLASH_BACKEND=gguf in
   ~/.config/macllm.env rolls Flash back to the LM Studio GGUF. LM Studio's window shows only Gemma.
2. M5 Max Flash-Next effort: mlx-serve turns thinking off unless a request sends
   chat_template_kwargs {"enable_thinking": true, "reasoning_effort": "medium"} (low, medium or
   xhigh); thinking-off answers are worse. Auto Router v1.4.1 and every Flash persona send it
   (Flash-IT-Deep xhigh). [effort:...] markers only matter on the GGUF rollback. Effort barely
   changes reasoning length; max_tokens is the real limit (Auto: Flash 8192, deep 24576, Gemma none).
3. M5 Max measured performance (Oct 24-25): Flash on mlx-serve 93 tok/s decode, 88 tok/s at 28K,
   2,500 tok/s prefill, 11 s TTFT at 28K, prefix cache 5.75 s → 0.11 s at 12K; with Gemma busy
   Flash 57 tok/s and Gemma 49 tok/s. Gemma alone 124 tok/s. Wired ~18 GB idle, ~88-102 GB while
   Flash works, no swap. The old GGUF did 48 tok/s and 934 tok/s prefill.

The repo-workflow and M5-scope memories from Oct 23 are unchanged.

## Still open

- Swap watch through Oct 27 (`sysctl vm.swapusage`).
- 10-prompt quality check, GGUF vs mlx-serve, before deleting the GGUF.
- `max_tokens` on Flash personas used outside Auto.
- RAID guard retry still misses the TB5 volume after a reboot (20 s).

# M5 Max System Profile (Flash-Next workhorse)

Applies ONLY to the M5 Max Studio 128 GB host. Generic M-series Studios running the
Gemma 4 build for friends-and-family hosting (houdini account, `m1/` scripts) do not
use any of this: no Flash-Next, no rewritten template, no 128 GB memory budget.

Current as of 2026-10-23. Dated history is in `CHANGELOG.md`.

## Model and engine

| Item | Setting |
| --- | --- |
| Model | AtomicChat `Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64`, identifier `flash-next` |
| Format | GGUF, 33 shards, ~88 GB of weights; arch `qwen4exp` (MoE + hybrid linear attention, full attention every 4 layers) |
| Quant | Labelled Q4_K_M; mixed quant averaging 4.27 bits per weight. Not MLX |
| Engine | LM Studio llama.cpp (Metal) runtime 2.63.0 since Oct 23 (2.61.0 kept for rollback) |
| Server | `localhost:1234` only, JIT loading off |
| Storage | Internal drive. Never on the external RAID0 (88 GB is memory-mapped; the stripe has no redundancy) |

## Load settings (`flash-up.sh`: `--gpu max --context-length 131072`)

| Setting | Value | Status |
| --- | --- | --- |
| Context | 128K (native max 256K) | Raised from 32K Oct 23. Parallel slots share the full context; a 100.9K-token prompt ran at 41.0 tok/s decode. Gemma stays at 32K: at 128K, LM Studio's load guardrail refuses Flash (it counts all 88 GB as resident) |
| GPU offload | Full | |
| Parallel | 4 | |
| mmap | On | Per-layer embeddings (35.8 GB) stay mostly on SSD |
| Keep in Memory | Off | Turn on first if decode jitters under memory pressure |
| Chat template box | Default | Template lives in GGUF shard 1 (see below) |
| Flash attention | Runtime default, not recorded | Not measured yet: compare `llm-probe.py --suite ctx` with it on and off |
| KV cache quantization | Runtime default (unquantized) | Leave it: the KV cache is only ~3 GB at 128K |
| Speculative decoding | None | Dropped Oct 16: no MTP or draft tensors in this GGUF, and MoE + hybrid attention make a draft model unlikely to help |

## Reasoning effort

- Default `medium`, set by the rewritten template in shard 1; `[effort:xhigh]` or
  `[effort:low]` in the first system message overrides it. LM Studio ignores
  `reasoning_effort` in requests.
- Effort is a nudge, not a budget (Oct 18-19 probes): reasoning length is nearly flat
  across levels on easy and medium prompts, and on a hard prompt every level ran
  ~10 min. `[effort:low]` buys no speed.
- `max_tokens` is the real time limit. Auto Router v1.3.2 caps: Flash medium 8192,
  Flash xhigh 24576, Gemma none. Persona caps for Flash personas picked directly are
  suggested in the README but not yet applied.

## Measured

| | Value |
| --- | --- |
| Decode | 48.1 tok/s (runtime 2.63.0; was 48.3 on 2.61.0) |
| Prefill @ 7.8K | 934 tok/s (was 942) |
| Time to first token | 257 ms |
| Decode generating to 28K | 45.8-46.3 tok/s |
| Decode @ 100.9K-token prompt (128K context) | 41.0 tok/s; prefill 867 tok/s, TTFT 116 s |
| Prefix cache, 11.9K-token prompt repeated | TTFT 12.9 s -> 0.05 s |
| Both models busy (Gemma vision + Flash) | Flash 28.7 tok/s, Gemma 62.1 tok/s |

## Memory (Oct 17 snapshot, `llm-mem.py`)

| | Weights resident | Working memory |
| --- | --- | --- |
| Flash-Next | 67.4 GB of 88.0 GB (77%) | 8.3 GB |
| Gemma 4 26B-A4B QAT | 13.4 GB (100%) | 9.8 GB |

Flash weights: experts 47.2 GB, per-layer embeddings 35.8 GB (sparse lookup, mostly on
SSD), attention 1.5 GB, the rest under 1 GB each. KV cache ~0.75 GB at 32K (~3 GB at 128K), linear-attention
state not included. Resident size moves with mmap paging; peak wired with both models
generating was 75.8 GB, no swap.

## Still open

- Flash attention on vs. off (`--suite ctx`, compare prefill at 16K-30K).
- `max_tokens` on Flash personas used outside Auto.

# Changelog

Newest first. Entries before Oct 16, 2026 were reconstructed from chat history.

## 2026-10-19
- Auto Router v1.3.2: per-route `max_tokens` valves (Flash medium 8192, Flash xhigh 24576, Gemma none); a request's own `max_tokens` still wins; `/route` and the status line show the cap; a reply cut off by the cap ends with a note. Why: Auto builds its own LM Studio request, so `/deep` and score-7 xhigh routes ran uncapped, and effort does not bound length (hard prompt ran ~10 min at every level). Result: mock LM Studio test passed (each route sends the right cap, chat setting overrides, cut-off note in streaming and non-streaming); on the Mac, `/route` shows 24,576 for `/deep` and no cap for Gemma, and with `STRONG_MAX_TOKENS` set to 64 a `/flash` request stopped at 64 tokens with the cut-off note (valve then restored to 8192).
- README: hard-prompt effort test at a 28K cap, corrected effort takeaway, suggested `max_tokens` per persona (not yet applied in Open WebUI). Why: the 8K-cap run clipped every level, so it couldn't show whether effort matters on hard tasks. Result (`llm-probe.py --suite effort --max-tokens 28000`, 1 run each): low 27,992 reasoning tokens → cap, default 25,489 + 2,129 answer → finished, xhigh 27,986 → cap, ~10 min each; effort does not predict length, so `max_tokens` is the real limit; decode held 45.8–46.3 tok/s to 28K.

## 2026-10-18
- `llm-probe.py` added (effort, context-per-request and prefix-cache probes; complements `llm-bench.py`), results in README. Why: confirm parallel 4 isn't splitting the 32K context, that `[effort:…]` markers reach the template, and what each effort level costs. Result: a 17.8K-token prompt passes, so slots share the full 32K; prefix cache cuts TTFT 12.9 s → 0.05 s on 11.9K tokens; markers switch the injected instruction (prompt +33 low, +45 xhigh), but reasoning tokens are nearly flat across levels on easy and medium prompts (medium prompt: low 436, default 445, xhigh 492), and on a hard prompt every level, low included, ran past 8,192 tokens, so `max_tokens` is the real limit; decode steady at 47.8–48.4 tok/s.
- Personas: the single Musician persona on each model replaced by Clarinet-Sax Musician and Guitar Musician (acoustic, classical and electric 6-string), four personas in all (Flash and Gemma). Why: clarinet/sax and guitar need different advice, and one combined prompt diluted both. Result: 15 personas (Flash 8, Gemma 7); clarinet-sax prompts unchanged from the old Musician ones, guitar prompt new. Prompt text is not in the repo because it names personal gear.
- Dropdown re-sorted (Auto first, then A-Z) after the persona change. Why: the manual order list still held the removed ids and left the new personas at the end.
- CHANGELOG: removed two duplicated 2026-10-16 lines (speculative decoding entry appeared three times).

## 2026-10-16
- Speculative decoding for Flash dropped from the plan. Why: `llm-mem.py` shows no MTP or draft tensors in the Flash-Next GGUF, and its hybrid linear-attention plus MoE design makes a separate draft model unlikely to help. Next speed option, if any: an MLX build (mlx-serve), measured end to end.
- `llm-bench.py`: `--load-image` checked before any test starts. Why: a missing image crashed the run after the setup step instead of stopping with a clear message. Result: fails fast with a `screencapture` hint.
- `llm-bench.py`: optional `--long-ctx N` (decode speed deep in a long context), `--mem` (peak wired, compressor, pressure, swap growth, page-ins per test) and `--load-model` / `--load-image` (second model kept busy, optionally with vision requests). Why: check whether Flash's hybrid attention holds decode flat at depth, and whether combined Gemma vision + Flash load causes swap or mmap page-in stutter. Default run and share line unchanged. Result: at 28K context Flash decode 48.1 → 44.9 tok/s (−7%), Gemma 124.0 → 90.7 (−27%); no swap, pressure normal, page-ins ≤ 0.3 GB; wired follows the active model (72.3 GB Flash, 20.7 GB Gemma, 18.3 GB idle baseline). Combined load (Gemma vision requests back to back while Flash is measured): Flash decode 28.7 tok/s (−40%), 26.8 at 28K, prefill 746 tok/s (−20%); Gemma 62.1 tok/s (−50%); peak wired 75.8 GB, no swap, pressure normal.
- Open WebUI upgraded 0.12.2 to 0.12.3 (backup in ~/owui-backups).
- Repo created: MacLLM branch with all M5 scripts, router, templates folder, M1 scripts, docs.
- Scripts sanitized for the repo: login email moved to `~/.config/macllm.env`; LaunchAgent is now a template rendered with `$USER`.

## 2026-10-15
- Benchmarks: Flash 48.3 tok/s, 942 tok/s prefill, 253 ms TTFT; Gemma 125.4 tok/s, 3,618 tok/s prefill, 112 ms TTFT.
- Memory: ~89 GB for both models (Flash 66.5, Gemma 22.5). Wired limit left at default.

## 2026-10-14
- Auto Router v1.2 installed and verified: scoring router, `/deep`, `/route`, no `reasoning_effort` sent.
- Auto Router v1.3 / v1.3.1: automatic xhigh on depth phrases or score ≥ 7; DEEP_PHRASES optional.
- Built-in tools turned off on all Gemma personas (`owui-sync-flash.sh REF=gemma-it`).
- Stale "Reasoning budget" block removed from Flash-General.

## 2026-10-12
- Rebuild of shard 1 from the original template proved byte-identical; original-shard backup deleted.

## 2026-10-11
- Flash-Next chat template rewritten in shard 1: default effort medium, `[effort:…]` markers. Test 1: ~4 min → ~35 s; speed unchanged (47.4 tok/s).
- Flash-IT-Deep persona (`[effort:xhigh]`).
- Built-in tools off on all Flash personas (`owui-sync-flash.sh`).
- Reasoning Budget filter tested at low/medium: ineffective, left off.
- `flash-up.sh` load retries and 30 s login delay (fixes "Engine protocol startup was aborted").
- `llm-mem.py`, `owui-sort-models.sh`, `gguf-template.py`, `gguf-set-template.py` added.

## 2026-10-10
- Open WebUI Task Model moved to Gemma; `/nothink`, tool list and stale context removed from prompts. Test 1: ~7.5 min → ~4 min.
- Auto Router v1.1; `llm-bench.py` baseline 47.3 tok/s / 932 tok/s prefill.

## 2026-10-09 (approx.)
- Muse removed; Flash-Next + Gemma stack built; personas cloned to Flash; startup/shutdown scripts; Open WebUI upgraded and DATA_DIR moved; M1 Max Gemma-only handoff.
2026-06-16 docs: earmark Auto Router M5 Max policy in MacLLM branch only. Why: keep 128 GB unified-memory routing and repo workflow out of generic Gemma builds. Result: docs only; no runtime or model change.

# Changelog

Newest first. Entries before Oct 16, 2026 were reconstructed from chat history.

## 2026-10-16
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

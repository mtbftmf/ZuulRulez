# Changelog

Newest first. Entries before Oct 16, 2026 were reconstructed from chat history.

## 2026-10-24
- Flash attention recorded, and Flash-Next found to have vision. `ps` on the llama-server processes shows Flash-Next started with `--flash-attn on` and `--mmproj mmproj-Qwen3.8-Flash-Next-F16.gguf` (862 MB), Gemma with `--flash-attn auto`. LM Studio exposes no flash-attention switch (CLI, Model Defaults, load settings), so the on/off comparison is closed. Why: the last open measurement, and the router assumed Flash was text-only. Result: Flash-Next described a desktop screenshot correctly; Auto Router v1.3.4 turns `STRONG_HAS_VISION` on by default, so `/flash` and `/deep` accept images and an image chat too big for Gemma goes to Flash instead of being trimmed. Images still default to Gemma.
- `llm-bench.py` v2: `--label` and a saved history (`~/llm-bench-history.jsonl`, `--history` lists it); each run is compared with the last one of the same model, label and machine, and drops over `--regress-pct` (default 7%) are flagged; `--vs LABEL` compares with another label for A/B tests. New `--sweep N,N` (prefill and decode at several depths), `--streams N` (simultaneous requests), and reasoning vs answer tokens on the gen test. Default run unchanged apart from the summary line now starting `llm-bench v2`. Why: compare runs across runtime, setting and model changes without copying numbers by hand; the sweep is what the flash-attention test needs. Result: tested against a mock server (sweep, streams, comparison, history, error path); not yet run on the Mac.

## 2026-10-23
- Auto Router v1.3.3 deployed in Open WebUI and verified. Why: confirm the context guard before relying on it. Result: with `FAST_CTX` set to 2000, `/route thanks, what about VLANs?` went to Flash (~1,659 estimated tokens over the 1,024 floor left after the 4,096 reserve); `FAST_CTX` restored to 32768. Open WebUI Flash-Next memory updated: Flash 128K, Gemma 32K, v1.3.3 guard.
- Auto Router v1.3.3: context guard. A Gemma route estimated over 28,672 tokens (`FAST_CTX` 32768 − `FAST_CTX_RESERVE` 4096; chars ÷ 3 + 1,100 per image) goes to Flash; image or `/gemma` requests drop the oldest messages to fit instead. Why: with Flash at 128K, a short follow-up in a long chat could score low and overflow Gemma's 32K. Result: offline test, 18-message ~213K-token chat routes to Flash; image and `/gemma` cases trimmed to ~27.8K; short chats unchanged.
- Flash context 32K -> 128K (`FLASH_CTX` default 131072; native max 262,144 for both models). Gemma stays at 32K: with both at 128K, LM Studio's load guardrail refused Flash (estimate 96.1 GB, counting all mmap'd weights as resident). Why: room for long documents and logs. Result: short decode 48.8 tok/s and prefill 942 tok/s unchanged; at a 100,926-token prompt decode 41.0 tok/s (-16%), prefill 867 tok/s, TTFT 116 s; peak wired 74.9 GB, Flash working memory 6.9 GB, no swap, pressure normal, page-ins 0.3 GB.
- Open WebUI memory: M5-only scope rule, Flash-Next model/engine facts and ZuulRulez repo workflow added as 3 memories (source text in m5/docs/M5_MAX_SYSTEM_PROFILE.md). Why: local chats lacked the current system details. Result: a new chat answers "which runtime does flash-next use?" with 2.63.0; memory text not in the repo.
- M5 Auto Router policy and `auto_router.m5.env.example` brought back in line with v1.3.2. Why: both still carried v1.2 values after the Oct 22 restore (`STRONG_REASONING_EFFORT`, which v1.3.2 has no valve for, and caps 16384 Flash / 2048 Gemma), and listed no `/deep` route. Result: docs and template only; caps now 8192 Flash, 24576 Flash xhigh, none for Gemma, matching the deployed router.
- `m5/docs/M5_MAX_SYSTEM_PROFILE.md`: Flash-Next model, engine, load settings, effort, measured speed and memory in one place, marked M5 Max only (not the generic Gemma builds). Why: the system spec lived only in chats and had gone stale (speculative decoding still listed as open, runtime 2.61.0, no probe results). Result: docs only; values taken from the Oct 15-23 CHANGELOG entries.
- `flash-up.sh` survives a failing raid guard and a non-interactive start; the guard now always returns 0 (result in `RAID_GUARD_RC`). Why: after a reboot Gemma loaded (LM Studio session restore) but Flash did not; the LaunchAgent exited 1 right after the guard reported the TB5 volume unavailable, and the script's `sudo launchctl` calls cannot prompt without a terminal. Result: next cold boot loaded both models at parallel 4 with Open WebUI healthy; log lines now carry timestamps.
- `flash-up.sh` retries the raid guard after the models load. Why: the TB5 volume mounts between 20 s and about 90 s after boot, later than `RAID_TIMEOUT`, so `raid-archive` was not linked. Result: not yet confirmed at a reboot.
- LM Studio llama.cpp runtime 2.61.0 -> 2.63.0 (`lms runtime update`; 2.61.0 stays installed for rollback). Why: a test model (Flint, 40B) failed with "unknown model architecture". Result: it loads and generates. Flash decode 48.1 tok/s (was 48.3), TTFT 257 ms, prefill 934 tok/s @ 7.8K (was 942); Gemma decode 123.3 (was 125.4), prefill 3,512 (was 3,618). No meaningful change to the working pair.
- Rewriting a GGUF chat template needs LM Studio's metadata caches cleared, and the `gguf-template.py` banner stripped before the template is written back. Why: Flint's template used a `\x00` escape that LM Studio's template parser rejects; the first rewrite loaded the old template from cache and the second leaked the `=====` banner into every prompt. Result: gotchas added to the README.
- External RAID0 (TB5) added as extra model storage and scratch on the M5 Max Studio only, via `m5/scripts/raid-guard.sh` (sourced by `flash-up.sh`; `RAID_ENABLED=0` by default, so generic builds skip it). Why: capacity for extra models and recreatable scratch without crowding the 1 TB internal drive. Flash-Next, Gemma, LM Studio config and the Open WebUI DB stay internal because Flash memory-maps 88 GB and the stripe has no redundancy and has unmounted once. Result: external sequential read 4,897 MB/s at 214 us, fsync'd write 747 MB/s; an internal-drive comparison under the same test is not yet measured. Details in `m5/docs/m5-max-raid-tiering.md`.
- README: repo layout table lists `m5/scripts/`, `m5/config/` and `m5/docs/`. Why: the RAID commit added the three folders. Result: documentation only, no behavior change.

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
2026-10-22 docs: earmark Auto Router M5 Max policy in MacLLM branch only. Why: keep 128 GB unified-memory routing and repo workflow out of generic Gemma builds. Result: docs only; no runtime or model change.
2026-10-22 config: add m5/config/auto_router.m5.env.example as M5-only valve template. Why: earmark 128 GB routing values without touching generic Gemma builds; real overrides go to ~/.config, not the repo. Result: docs/template only, no runtime change.
2026-10-22 router: auto_router v1.1 -> v1.2 scored route, /fast //strong aliases, small-code-block demotion, per-model max_tokens, non-stream effort fallback, retuned Valves 1800/0/3/medium. Why: stop over-routing the 88 GB mmap Flash-Next model on this 128 GB M5 Max. Result: source only; runtime unchanged until v1.2 is re-pasted into Open WebUI Pipes.
2026-10-22 chore: correct dates on the two prior CHANGELOG entries (were 2026-06-16 and 2026-06-17; work occurred 2026-10-22). Why: template dates supplied earlier were wrong. Result: CHANGELOG metadata only; no code or config change.
2026-10-22 router: restore auto_router.py to v1.3.2 (834ecb5) after verifying d01095e v1.2 was a downgrade. Why: v1.2 dropped DEEP_SCORE/DEEP_PHRASES/DEEP_MARKER/DEEP_MAX_TOKENS/STRONG_HAS_VISION and _keywords/_add_marker/_cap/_cap_note; changed caps FAST 0->2048 and STRONG 8192->16384; reintroduced reasoning_effort. Result: MacLLM source safe again; v1.2 remains in history as d01095e only; deploy v1.3.2 until v1.4 is built from v1.3.2.

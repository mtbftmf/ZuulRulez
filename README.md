# MacLLM: dual-LLM stack on a Mac Studio M5 Max

Local LLM setup that runs two models side by side in LM Studio behind Open WebUI, with a scoring router that picks a model (and reasoning effort) per message. Everything runs on the Mac; the LM Studio API is localhost-only.

![Environment](docs/images/llm-environment.png)

## Stack

| Component | Setting |
| --- | --- |
| Hardware | Mac Studio M5 Max (18 CPU / 40 GPU), 128 GB, 1 TB, macOS 27.0.1 |
| Workhorse | `flash-next` = AtomicChat `Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64` (33-shard GGUF, 88 GB of weights) |
| Router / vision / tasks | `gemma-4-26b-a4b-it-qat` (13.4 GB). Flash-Next also has vision (862 MB mmproj, loaded automatically) |
| Load settings | Context: Flash 128K, Gemma 32K (both support 256K); GPU max, parallel 4, mmap on (Flash: Keep in Memory off) |
| Server | LM Studio on `localhost:1234` only; no LAN binding, no CORS, JIT off |
| Front end | Open WebUI 0.12, launchd daemon on `:8080`, data in `~/open-webui-data` |
| GPU wired limit | macOS default (`iogpu.wired_limit_mb` = 0, ~96 GB) |

## Measured (Oct 15, 2026)

| | Flash-Next | Gemma 4 26B |
| --- | --- | --- |
| Generation | 48.3 tok/s | 125.4 tok/s |
| Prefill (~7.8K tokens) | 942 tok/s | 3,618 tok/s |
| Time to first token | 253 ms | 112 ms |
| Generation @ 28K context (Oct 16) | 44.9 tok/s (−7%) | 90.7 tok/s (−27%) |
| Prefill @ 28K context (Oct 16) | 909 tok/s, 31 s TTFT | 2,805 tok/s, 10 s TTFT |
| Peak wired while generating (Oct 16) | 72.3 GB | 20.7 GB |
| Both busy (Gemma vision + Flash, Oct 16) | 28.7 tok/s, 26.8 @ 28K | 62.1 tok/s |
| Memory (weights + working) | 58.4 + 8.1 = 66.5 GB | 13.4 + 9.1 = 22.5 GB |

Idle baseline is ~18 GB wired; with both models generating at once, peak wired is 75.8 GB (no swap, pressure normal), well under the ~96 GB default limit. Contention costs speed, not memory: each model loses 40–50% while the other is busy.

Both models together: ~89 GB real memory (`llm-mem.py`). Flash's 35.8 GB per-layer embedding table stays mostly on SSD via mmap (~6 GB resident).

Test 1 ([Raspberry Pi Wi-Fi troubleshooting prompt](m5/tests/test1-pi-wifi.md)), end to end in Open WebUI: ~7.5 min out of the box → ~4 min after prompt cleanup → **~35 s** at medium effort. Generation speed never changed; the gain is less wasted reasoning.

![Efficiency](docs/images/flash-next-tuning.png)

### MLX runtime test (Oct 24, not yet adopted)

Same Flash-Next weights family on [mlx-serve](https://github.com/ddalcu/mlx-serve) 26.10.3 (pack `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit`, 4-bit affine, n-gram table mmapped like the GGUF), Gemma loaded in LM Studio, `llm-bench.py --long-ctx 28000 --mem`:

| | LM Studio GGUF | mlx-serve | mlx-serve + MTP |
| --- | --- | --- | --- |
| Decode | 48.4 tok/s | 67.2 tok/s | 92.0 tok/s |
| Decode @ 28K | 45.3 tok/s | 64.2 tok/s | 89.6 tok/s |
| Prefill @ 7.8K | 934 tok/s | 2,522 tok/s | 2,522 tok/s |
| TTFT @ 28K | 31.0 s | 11.2 s | 11.3 s |
| Peak wired (incl. ~18 GB idle) | 75.8 GB | 95.5 GB | 100.2 GB |

No swap, pressure normal in all three. The runtime alone gives 1.4x decode and 2.7x prefill; MTP adds another 1.37x decode for ~4.7 GB wired. mlx-serve sends `enable_thinking: false` unless the request says otherwise, and with thinking off Flash answered a two-step price question wrong ($83.33 instead of $75.00); with `chat_template_kwargs: {"enable_thinking": true}` it was right in 2.2 s. Effort (`reasoning_effort` low/medium/xhigh) is a request field there, but medium used more tokens than xhigh on that question.

### Behavior probes (Oct 18, `llm-probe.py`)

| Check | Result |
| --- | --- |
| Context per request (parallel 4, 32K) | A 17.8K-token prompt passed; the limit is the full 32,768 shared by all slots, not 8K per slot |
| Prefix cache (11.9K-token prompt sent twice) | TTFT 12.9 s → 0.05 s |
| Decode across code, prose and reasoning prompts | 47.8–48.4 tok/s |
| Effort, easy prompt (reasoning tokens, median) | low 170 · default 281 · xhigh 257 |
| Effort, medium prompt (probability question) | low 436 · default 445 · xhigh 492; ~14–18 s for every level |
| Effort, hard prompt (integer search) | every level, low included, hit the 8,192-token cap while still reasoning |
| Effort, same hard prompt, 28K cap (Oct 19, 1 run each) | low 27,992 reasoning → cap · default 25,489 + 2,129 answer → finished · xhigh 27,986 → cap; ~10 min each |
| Decode while generating to 28K | 45.8–46.3 tok/s |

Takeaway: effort level does not predict reasoning length. On easy and medium prompts the model sets its own depth; on a hard one every level ran ~10 min, and low ran longest. Medium stays the default, `[effort:low]` buys no speed, and `[effort:xhigh]` is a nudge, not a guarantee (Test 1's gain was specific to that task). `max_tokens` per persona is the only real time limit: at ~46 tok/s each 1K tokens is ~22 s. A capped run that is still reasoning returns little or no answer, so caps on deep personas should be generous. Flash attention on vs. off is not settled yet: the quick suite's short prompts can't show a prefill difference; compare `--suite ctx` runs instead.

## Effort control

Flash-Next's stock chat template forces `xhigh` reasoning, LM Studio ignores `reasoning_effort` in requests, and its Chat Template box blocks paste. The template inside GGUF shard 1 was rewritten instead (`m5/bin/gguf-set-template.py`): default `medium`; `[effort:xhigh]` or `[effort:low]` in the first system message overrides it.

Ways to get xhigh: the Flash-IT-Deep persona; `[effort:xhigh]` in a persona or a chat's system prompt; `/deep` in Auto; or automatically in Auto (depth phrases such as "think carefully" / "deep dive", or a routing score of 7+).

Reapply after a model re-download (templates: `m5/templates/`):

```bash
cd ~/.lmstudio/models/AtomicChat/Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64
~/.lmstudio/bin/lms unload flash-next
python3 ~/bin/gguf-set-template.py Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64-00001-of-00033.gguf ~/flash-next-template-medium.jinja ~/shard1-new.gguf
python3 ~/bin/gguf-template.py ~/shard1-new.gguf | grep -c effort_ns
mv ~/shard1-new.gguf Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64-00001-of-00033.gguf
~/bin/flash-up.sh
```

Verify with `~/.lmstudio/bin/lms log stream`: a plain request shows no "Reasoning effort is set" line; an `[effort:xhigh]` request does.

Or check token counts: `llm-probe.py --suite effort` shows the prompt growing by the injected instruction (low +33, xhigh +45 tokens over default). Effort is a tendency, not a budget: set `max_tokens` on personas that must stay fast.

Suggested `max_tokens` (Open WebUI → persona → Advanced Params):

| Personas | max_tokens | Worst case at ~46 tok/s |
| --- | --- | --- |
| Flash-Chef, Finance, General, IT, Scripting, both Musicians | 8192 | ~3 min |
| Flash-IT-Deep | 16384–24576 | ~6–9 min |

Persona caps are not set yet. Auto ignores persona settings and uses its own valves (see Auto Router).

## Auto Router (`m5/openwebui/auto_router.py`, v1.3.3)

Paste into Open WebUI → Admin → Functions. Routing, first match wins:

1. Prefix: `/flash` `/strong` → Flash (medium); `/deep` → Flash + `[effort:xhigh]`; `/gemma` `/fast` → Gemma; `/route` → dry run that reports the route.
2. Image attached → Gemma (faster). Flash-Next has vision too: `/flash` or `/deep` with an image goes to Flash (`STRONG_HAS_VISION`, on by default).
3. Short continuation ("continue", "yes") → Flash if the previous answer was long, else Gemma.
4. Depth phrase or score ≥ 7 → Flash (xhigh); score ≥ 3 → Flash (medium). Scoring: +3 code task, +3 task phrase (troubleshoot, root cause, audit, WACC…), +2 over 1,800 chars, +2 more over 5,400.
5. Otherwise → Gemma.

Context guard (v1.3.3): Gemma is loaded at 32K, Flash at 128K. A Gemma route whose whole request (system prompt, history, images) is estimated over `FAST_CTX` − `FAST_CTX_RESERVE` (32,768 − 4,096) goes to Flash instead. An image chat that is too big goes to Flash as well (v1.3.4). Only with `/gemma` (or `STRONG_HAS_VISION` off) are the oldest messages dropped until it fits and the status line says so. Estimate: characters ÷ 3 + 1,100 per image. Set `FAST_CTX` to whatever `lms ps` shows for Gemma; 0 turns the guard off.

The router never sends `reasoning_effort`. Thresholds and phrase lists are valves.

Token caps (v1.3.2): Auto builds its own request to LM Studio, so persona `max_tokens` settings never reach it. Valves set the cap per route: `STRONG_MAX_TOKENS` 8192 (Flash, medium), `DEEP_MAX_TOKENS` 24576 (Flash, xhigh), `FAST_MAX_TOKENS` 0 (Gemma, no cap). A `max_tokens` already in the request wins. `/route` and the status line show the cap; a reply cut off by it ends with a note.

## Open WebUI setup

- Connections: OpenAI API `http://localhost:1234/v1` (LM Studio, Gemma) and `http://127.0.0.1:11234/v1` (mlx-serve, `flash-next`), no key, no prefix; Ollama and Direct Connections off. `flash-next` must appear once in the model list.
- Flash-* personas carry the custom parameter `chat_template_kwargs` = `{"enable_thinking": true, "reasoning_effort": "medium"}` (`xhigh` on Flash-IT-Deep). Without it mlx-serve answers with thinking off. Copy to new personas with `REF=muse-general PARAM_KEYS=custom_params owui-sync-flash.sh`.
- Task Model: Gemma (titles, tags, follow-ups never hit Flash).
- Personas: Flash-* (Chef, Clarinet-Sax Musician, Finance, General, Guitar Musician, IT, IT-Deep, Scripting) and Gemma-* (same set minus IT-Deep), plus Auto. Built-in tools off on all of them.
- Dropdown order: Auto first, then A–Z (`owui-sort-models.sh`).
- Scripts authenticate with a login token; put `OWUI_EMAIL` in `~/.config/macllm.env` (see `env.example`).

## Daily operations

| Task | Command |
| --- | --- |
| Start / reload both models | `~/bin/flash-up.sh` |
| Stop everything | `~/bin/flash-down.sh` |
| Upgrade Open WebUI (with backup and rollback) | `~/bin/owui-upgrade.sh` |
| Benchmark | `python3 ~/bin/llm-bench.py --model flash-next` |
| Benchmark at depth, with memory | `python3 ~/bin/llm-bench.py --model flash-next --long-ctx 28000 --mem` |
| Context sweep, labeled for A/B (v2) | `python3 ~/bin/llm-bench.py --model flash-next --sweep 16000,24000,30000 --label fa-on` |
| 1 vs 2 simultaneous requests (v2) | `python3 ~/bin/llm-bench.py --model flash-next --streams 2` |
| Saved runs (v2; each run is compared with the last one of the same model and label) | `python3 ~/bin/llm-bench.py --history` |
| Benchmark under combined load | add `--load-url http://localhost:1234/v1 --load-model gemma-4-26b-a4b-it-qat --load-image ~/Pictures/test.png` (Flash on mlx-serve, Gemma on LM Studio) |
| Probe context, cache and effort | `python3 ~/bin/llm-probe.py --suite all` |
| Compare probe runs | `python3 ~/bin/llm-probe.py --summary llm-probe-history.csv` |
| Memory per model | `python3 ~/bin/llm-mem.py` |
| Watch requests | `~/.lmstudio/bin/lms log stream` |
| Copy a persona setting to sibling personas | `owui-sync-flash.sh` (report → dry run → `DRY_RUN=0`) |
| Re-sort dropdown | `~/bin/owui-sort-models.sh` |
| See where Auto would send a message | `/route <message>` in a throwaway Auto chat |

## Repo layout

| Path | Contents |
| --- | --- |
| `m5/bin/` | Scripts linked into `~/bin` by `install.sh` |
| `m5/launchd/` | Login LaunchAgent template (rendered to `com.$USER.flash-up`) |
| `m5/openwebui/` | Open WebUI functions (router, filter) |
| `m5/scripts/` | Optional helpers sourced by `m5/bin` scripts (`raid-guard.sh`; M5 Max only, off by default) |
| `m5/config/` | Env templates; copy to `~/.config/` and fill in (never commit the filled-in file) |
| `m5/docs/` | Host-specific notes, M5 Max only: system profile, Auto Router policy, external RAID0 tiering |
| `m5/templates/` | Stock and edited Flash-Next chat templates |
| `m1/` | Gemma-only installer and scripts for a 32 GB M1 Max Studio |
| `docs/images/` | Diagram and efficiency chart |
| `CHANGELOG.md` | Dated history of changes and measured results |

Install or update on the Mac: `./install.sh` (dry run), then `./install.sh --apply` (add `--launchd` to install the login agent).

## Never commit

Model weights, `~/open-webui-data`, Open WebUI exports or backups (they contain chats, memories and personal prompts), tokens, API keys, AWS credentials. `.gitignore` covers the common cases.

## Gotchas

- zsh: `#` is not a comment in pasted commands, `<placeholder>` text is read as a redirect, and `echo` turns `\n` inside JSON into real newlines; read JSON files with `jq` directly.
- A model re-download restores the stock template (xhigh). Leave LM Studio's Chat Template box at default.
- `lms ps` shows file size, not memory. `top`'s "used" includes file cache; wired is ~19 GB after reboot and 70–74 GB once Flash runs.
- Open WebUI valves: click "Custom" to flip a valve back to Default; saved valve values survive a function code update.
- launchctl: wait ~5 s after `bootout` before `bootstrap`.
- Folders: `~/ZuulRulez` stays on MacLLM (`~/bin` links point into it; never `git checkout` there). Monitor work goes in `~/ZuulRulez-monitor` (git worktree).
- Rewriting a GGUF chat template (`gguf-set-template.py`): `gguf-template.py` prints a `=====` banner line before the template; strip it before writing the file back, or it is rendered into every prompt. LM Studio then keeps using the old template until `~/.lmstudio/.internal/gguf-metadata-cache.json` and `model-index-cache.json` are deleted (run `flash-down.sh` first, `flash-up.sh` after; both are rebuilt on rescan). LM Studio's template parser also rejects `\x` escapes (e.g. `replace("\x00", "")`).
- A GGUF that fails with "unknown model architecture" needs a newer llama.cpp runtime: `lms runtime update`. Older runtimes stay installed; roll back with `lms runtime select`. Re-run `llm-bench.py` for both models after a runtime change.

# MacLLM: dual-LLM stack on a Mac Studio M5 Max

Generic single-model Gemma 4 builds for other Studios live in [`gemma/`](gemma/README.md); everything else in this README is the M5 Max.

Local LLM setup that runs two models side by side behind Open WebUI: Flash-Next in mlx-serve and Gemma 4 in LM Studio, with a scoring router that picks a model (and reasoning effort) per message. Everything runs on the Mac; both model servers are localhost-only.

![Environment](docs/images/llm-environment.png)

## Stack

| Component | Setting |
| --- | --- |
| Hardware | Mac Studio M5 Max (18 CPU / 40 GPU), 128 GB, 1 TB, macOS 27.0.1 |
| Workhorse | `flash-next` = MLX pack `ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit` (4-bit affine, ~65 GB weights + 30 GB n-gram table mmapped), via `~/.mlx-serve/models/flash-next`. Vision and MTP included |
| Flash server | [mlx-serve](https://github.com/ddalcu/mlx-serve) 26.10.3 (`brew pin`ned) on `127.0.0.1:11234`, LaunchAgent `com.$USER.mlx-serve`: `--ctx-size 131072 --mtp --no-pld --max-concurrent 2 --metrics` |
| Router / vision / tasks | `gemma-4-26b-a4b-it-qat` (13.4 GB) in LM Studio on `localhost:1234` (32K context, parallel 4, no LAN binding, no CORS, JIT off) |
| Rollback | `FLASH_BACKEND=gguf` in `~/.config/macllm.env`: `flash-up.sh` stops mlx-serve and loads the AtomicChat `Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64` GGUF (88 GB) in LM Studio as `flash-next`. Kept until two weeks after the switch |
| Front end | Open WebUI 0.12, launchd daemon on `:8080`, data in `~/open-webui-data` |
| HTTPS | Caddy (`brew services`) with its own local CA: Open WebUI on `:8443`, System Monitor on `:9443`; HTTP ports still open. Setup, per-device CA trust and the two-network name issue: `m5/docs/m5-max-https.md` |
| GPU wired limit | macOS default (`iogpu.wired_limit_mb` = 0, ~96 GB) |

## Measured (Oct 24-25, 2026: Flash on mlx-serve)

| | Flash-Next (mlx-serve + MTP) | Gemma 4 26B (LM Studio) |
| --- | --- | --- |
| Generation | 93.5 tok/s | 124 tok/s |
| Prefill (~7.8K tokens) | 2,506 tok/s | 3,534 tok/s |
| Time to first token | 268 ms | 128 ms |
| Generation @ 28K context | 88.3 tok/s | 90.7 tok/s |
| TTFT @ 28K context | 11.3 s | 10 s |
| Both busy (Gemma image requests + Flash) | 56.8 tok/s, 44.9 @ 28K | 49.1 tok/s |
| Two Flash requests at once | 51.5 tok/s each, 100.6 total | |
| Prefix cache, ~12K-token prompt repeated | TTFT 5.75 s → 0.11 s | |

Wired memory: ~18 GB idle; ~88-102 GB while Flash is generating or just after (mlx-serve releases its wiring when idle). Peak 101.7 GB with both models busy, no swap, pressure normal. After a reboot macOS compresses the idle Flash weights; `flash-up.sh` sends a 1-token warm-up so the ~4 s first-request cost is paid at login.

Test 1 ([Raspberry Pi Wi-Fi troubleshooting prompt](m5/tests/test1-pi-wifi.md)), end to end in Open WebUI: ~7.5 min out of the box → ~4 min after prompt cleanup → **~35 s** at medium effort (GGUF, Oct 11). Bare API prompt, same settings: mlx-serve ~62 s vs GGUF ~105 s for the same answer length.

![Efficiency](docs/images/flash-next-tuning.png)

### GGUF era (Oct 15-16, LM Studio; now the rollback)

| | Flash-Next GGUF | Gemma 4 26B |
| --- | --- | --- |
| Generation | 48.3 tok/s | 125.4 tok/s |
| Prefill (~7.8K tokens) | 942 tok/s | 3,618 tok/s |
| Generation @ 28K context | 44.9 tok/s | 90.7 tok/s |
| Prefill @ 28K context | 909 tok/s, 31 s TTFT | 2,805 tok/s, 10 s TTFT |
| Both busy (Gemma vision + Flash) | 28.7 tok/s, 26.8 @ 28K | 62.1 tok/s |
| Peak wired, both generating | 75.8 GB | |

### MLX vs GGUF (Oct 24 test)

Pack and runtime as above, Gemma loaded in LM Studio, `llm-bench.py --long-ctx 28000 --mem`:

| | LM Studio GGUF | mlx-serve | mlx-serve + MTP |
| --- | --- | --- | --- |
| Decode | 48.4 tok/s | 67.2 tok/s | 92.0 tok/s |
| Decode @ 28K | 45.3 tok/s | 64.2 tok/s | 89.6 tok/s |
| Prefill @ 7.8K | 934 tok/s | 2,522 tok/s | 2,522 tok/s |
| TTFT @ 28K | 31.0 s | 11.2 s | 11.3 s |
| Peak wired (incl. ~18 GB idle) | 75.8 GB | 95.5 GB | 100.2 GB |

No swap, pressure normal in all three. The runtime alone gives 1.4x decode and 2.7x prefill; MTP adds another 1.37x decode for ~4.7 GB wired. mlx-serve sends `enable_thinking: false` unless the request says otherwise, and with thinking off Flash answered a two-step price question wrong ($83.33 instead of $75.00); with `chat_template_kwargs: {"enable_thinking": true}` it was right in 2.2 s. Effort (`reasoning_effort` low/medium/xhigh) is a request field there, but medium used more tokens than xhigh on that question.

### Behavior probes (Oct 18, `llm-probe.py`, GGUF)

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

On mlx-serve, thinking and effort are request fields: `chat_template_kwargs: {"enable_thinking": true, "reasoning_effort": "medium"}` (`low`, `medium` or `xhigh`). mlx-serve turns thinking **off** when a request omits it, and Flash then answers worse (Oct 24: a two-step price question came back wrong), so every path to Flash sends it: Auto (valves `STRONG_THINKING`, `STRONG_EFFORT`, `DEEP_EFFORT`) and every Flash-* persona (custom parameter, see Open WebUI setup). Any new client that calls `127.0.0.1:11234` directly must send it too.

Ways to get xhigh: the Flash-IT-Deep persona; `/deep` in Auto; or automatically in Auto (depth phrases such as "think carefully" / "deep dive", or a routing score of 7+).

### GGUF rollback only

Flash-Next's stock chat template forces `xhigh` reasoning, LM Studio ignores `reasoning_effort` in requests, and its Chat Template box blocks paste. The template inside GGUF shard 1 was rewritten instead (`m5/bin/gguf-set-template.py`): default `medium`; `[effort:xhigh]` or `[effort:low]` in the first system message overrides it. Auto Router in `EFFORT_MODE` marker sends `[effort:xhigh]` for deep routes.

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

| Personas | max_tokens | Worst case at ~90 tok/s (mlx-serve) |
| --- | --- | --- |
| Flash-Chef, Finance, General, IT, Scripting, both Musicians | 8192 | ~1.5 min |
| Flash-IT-Deep | 16384–24576 | ~3–4.5 min |

Persona caps are not set yet. Auto ignores persona settings and uses its own valves (see Auto Router).

## Auto Router (`m5/openwebui/auto_router.py`, v1.4.1)

Paste into Open WebUI → Admin → Functions (`pbcopy < ~/ZuulRulez/m5/openwebui/auto_router.py`, then Cmd-A, Cmd-V, Save; copy nothing else in between). Gemma requests go to `LMSTUDIO_URL`, Flash requests to `STRONG_URL` (mlx-serve). Routing, first match wins:

1. Prefix: `/flash` `/strong` → Flash (medium); `/deep` → Flash (xhigh); `/gemma` `/fast` → Gemma; `/route` → dry run that reports the route. Prefixes work on messages with attachments (v1.4.1: Open WebUI's leading `<attached_files>` block is skipped).
2. Image attached → Gemma (faster). Flash-Next has vision too: `/flash` or `/deep` with an image goes to Flash (`STRONG_HAS_VISION`, on by default; MTP is off for image turns).
3. Short continuation ("continue", "yes") → Flash if the previous answer was long, else Gemma.
4. Depth phrase or score ≥ 7 → Flash (xhigh); score ≥ 3 → Flash (medium). Scoring: +3 code task, +3 task phrase (troubleshoot, root cause, audit, WACC…), +2 over 1,800 chars, +2 more over 5,400.
5. Otherwise → Gemma.

Context guard (v1.3.3): Gemma is loaded at 32K, Flash at 128K. A Gemma route whose whole request (system prompt, history, images) is estimated over `FAST_CTX` − `FAST_CTX_RESERVE` (32,768 − 4,096) goes to Flash instead. An image chat that is too big goes to Flash as well (v1.3.4). Only with `/gemma` (or `STRONG_HAS_VISION` off) are the oldest messages dropped until it fits and the status line says so. Estimate: characters ÷ 3 + 1,100 per image. Set `FAST_CTX` to whatever `lms ps` shows for Gemma; 0 turns the guard off.

Effort (v1.4.0): with `EFFORT_MODE` kwargs (default) every Flash request carries `chat_template_kwargs` `{enable_thinking: true, reasoning_effort: medium}`, `xhigh` for deep routes; `EFFORT_MODE` marker restores the GGUF behaviour (template default, `[effort:xhigh]` marker). Thresholds and phrase lists are valves.

Token caps (v1.3.2): Auto builds its own request to the model server, so persona `max_tokens` settings never reach it. Valves set the cap per route: `STRONG_MAX_TOKENS` 8192 (Flash, medium), `DEEP_MAX_TOKENS` 24576 (Flash, xhigh), `FAST_MAX_TOKENS` 0 (Gemma, no cap). A `max_tokens` already in the request wins. `/route` and the status line show the cap; a reply cut off by it ends with a note.

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
| Start / reload both models | `~/bin/flash-up.sh` (Gemma in LM Studio, Flash in mlx-serve, warm-up, checks) |
| Stop everything | `~/bin/flash-down.sh` (`STOP_MLX=0` keeps mlx-serve) |
| Is Flash up? | `curl -s http://127.0.0.1:11234/health` |
| Restart Flash only | `launchctl kickstart -k gui/$UID/com.$USER.mlx-serve` |
| Flash logs | `~/.mlx-serve/logs/mlx-serve-11234.log`, `~/Library/Logs/mlx-serve.log` |
| Flash metrics (tok/s, memory, TTFT) | `curl -s http://127.0.0.1:11234/metrics.json` |
| Roll back to the GGUF / return to MLX | `FLASH_BACKEND=gguf ~/bin/flash-up.sh` / `~/bin/flash-up.sh` |
| Upgrade Open WebUI (with backup and rollback) | `~/bin/owui-upgrade.sh` |
| Benchmark (finds the server that serves the model) | `python3 ~/bin/llm-bench.py --model flash-next` |
| Benchmark at depth, with memory | `python3 ~/bin/llm-bench.py --model flash-next --long-ctx 28000 --mem` |
| Context sweep, labeled for A/B (v2) | `python3 ~/bin/llm-bench.py --model flash-next --sweep 16000,24000,30000 --label fa-on` |
| 1 vs 2 simultaneous requests (v2) | `python3 ~/bin/llm-bench.py --model flash-next --streams 2` |
| Saved runs (v2; each run is compared with the last one of the same model and label) | `python3 ~/bin/llm-bench.py --history` |
| Benchmark under combined load | add `--load-model gemma-4-26b-a4b-it-qat --load-image ~/Pictures/test.png` (each model is sent to its own server) |
| Probe context, cache and effort | `python3 ~/bin/llm-probe.py --suite all` |
| Compare probe runs | `python3 ~/bin/llm-probe.py --summary llm-probe-history.csv` |
| Memory per model | `python3 ~/bin/llm-mem.py` (GGUF models; for Flash on mlx-serve use `memory_mb` in `/metrics.json`) |
| Watch Gemma requests | `~/.lmstudio/bin/lms log stream` |
| Copy a persona setting to sibling personas | `owui-sync-flash.sh` (report → dry run → `DRY_RUN=0`) |
| Fix one line in every persona's system prompt | `owui-prompt-lines.py` (report), then `--apply`; rules in `~/.config/owui-prompt-lines.json` (example in `m5/config/`). Your personal system prompt (Persistent User Context) is not a persona: edit it in Settings → General, then reload the page |
| Re-sort dropdown | `~/bin/owui-sort-models.sh` |
| See where Auto would send a message | `/route <message>` in a throwaway Auto chat |
| Restart HTTPS front end after editing `/opt/homebrew/etc/Caddyfile` | `brew services restart caddy` |
| CA root to install on a new device | `/opt/homebrew/var/lib/caddy/pki/authorities/local/root.crt` |

## Repo layout

| Path | Contents |
| --- | --- |
| `m5/bin/` | Scripts linked into `~/bin` by `install.sh` |
| `m5/launchd/` | LaunchAgent templates rendered by `install.sh --launchd`: `com.$USER.flash-up` (login script), `com.$USER.mlx-serve` (Flash server) |
| `m5/openwebui/` | Open WebUI functions (router, filter) |
| `m5/scripts/` | Optional helpers sourced by `m5/bin` scripts (`raid-guard.sh`; M5 Max only, off by default) |
| `m5/config/` | Env templates; copy to `~/.config/` and fill in (never commit the filled-in file) |
| `m5/docs/` | Host-specific notes, M5 Max only: system profile, Auto Router policy, mlx-serve switch plan, local HTTPS, external RAID0 tiering |
| `m5/templates/` | Stock and edited Flash-Next chat templates (GGUF rollback) |
| `m5/tests/` | Fixed prompts for end-to-end comparisons (Test 1) |
| `gemma/` | Generic Gemma 4 builds for other M-series Studios (houdini account, friends-and-family hosting): installer, up/down scripts, rebuild scripts (preflight, Golden Gate upgrade, bootstrap, verify), runbook, Open WebUI memory text. See `gemma/README.md`; none of the M5 stack applies there |
| `docs/images/` | Diagram and efficiency chart |
| `CHANGELOG.md` | Dated history of changes and measured results |

Install or update on the Mac: `./install.sh` (dry run), then `./install.sh --apply` (add `--launchd` to install or update both LaunchAgents; a changed mlx-serve agent restarts Flash).

## Never commit

Model weights, `~/open-webui-data`, Open WebUI exports or backups (they contain chats, memories and personal prompts), tokens, API keys, AWS credentials. `.gitignore` covers the common cases.

## Gotchas

- HTTPS: `ERR_SSL_PROTOCOL_ERROR` means HTTPS went to a plain HTTP port (8080 / 9090); use 8443 / 9443. A `.local` name that fails while the IP works means the client is on the other subnet (see `m5/docs/m5-max-https.md`).

- zsh: `#` is not a comment in pasted commands, `<placeholder>` text is read as a redirect, and `echo` turns `\n` inside JSON into real newlines; read JSON files with `jq` directly.
- mlx-serve turns thinking off unless the request sends `chat_template_kwargs` `{"enable_thinking": true}`. New Flash personas need the custom parameter (copy with `owui-sync-flash.sh`).
- mlx-serve binds to `0.0.0.0` (the whole LAN) by default; the LaunchAgent passes `--host 127.0.0.1`. Check with `lsof -nP -iTCP:11234 -sTCP:LISTEN`.
- mlx-serve is pinned (`brew pin mlx-serve`). Upgrade on purpose: unpin, upgrade, `llm-bench.py --label mlx-prod` (flags drops over 7%), pin again.
- GGUF rollback only: a model re-download restores the stock template (xhigh). Leave LM Studio's Chat Template box at default.
- `lms ps` and LM Studio's window show only Gemma now; Flash lives in mlx-serve. `top`'s "used" includes file cache (the 30 GB n-gram table); wired is ~18 GB idle and ~88-102 GB while Flash is working.
- Open WebUI valves: click "Custom" to flip a valve back to Default; saved valve values survive a function code update.
- launchctl: wait ~5 s after `bootout` before `bootstrap`.
- Folders: `~/ZuulRulez` stays on MacLLM (`~/bin` links point into it; never `git checkout` there). Monitor work goes in `~/ZuulRulez-monitor` (git worktree).
- GGUF rollback only: rewriting a GGUF chat template (`gguf-set-template.py`): `gguf-template.py` prints a `=====` banner line before the template; strip it before writing the file back, or it is rendered into every prompt. LM Studio then keeps using the old template until `~/.lmstudio/.internal/gguf-metadata-cache.json` and `model-index-cache.json` are deleted (run `flash-down.sh` first, `flash-up.sh` after; both are rebuilt on rescan). LM Studio's template parser also rejects `\x` escapes (e.g. `replace("\x00", "")`).
- A GGUF (Gemma, or the Flash rollback) that fails with "unknown model architecture" needs a newer llama.cpp runtime: `lms runtime update`. Older runtimes stay installed; roll back with `lms runtime select`. Re-run `llm-bench.py` for both models after a runtime change.

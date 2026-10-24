# M5 Max: switch Flash-Next from LM Studio GGUF to mlx-serve

Plan, written 2026-10-24. Applies ONLY to the M5 Max Studio 128 GB host. Nothing here is done
yet; each step becomes one commit and one CHANGELOG line when it is.

## Why

Measured Oct 24 (`llm-bench.py --long-ctx 28000 --mem`, Gemma loaded in LM Studio):

| | LM Studio GGUF (today) | mlx-serve + MTP |
| --- | --- | --- |
| Decode | 48.4 tok/s | 92.0 tok/s |
| Decode @ 28K | 45.3 tok/s | 89.6 tok/s |
| Prefill @ 7.8K | 934 tok/s | 2,522 tok/s |
| TTFT @ 28K | 31.0 s | 11.3 s |
| Peak wired | 75.8 GB | 100.2 GB |

The runtime alone gives 1.4x decode and 2.7x prefill; MTP adds 1.37x decode for ~4.7 GB.

## Target layout

| Piece | Before | After |
| --- | --- | --- |
| Flash-Next | LM Studio, GGUF, `localhost:1234`, id `flash-next` | mlx-serve, MLX pack, `127.0.0.1:11234`, id `flash-next` |
| Gemma 4 26B | LM Studio `:1234` | unchanged |
| Flash process | loaded by `flash-up.sh` via `lms load` | own LaunchAgent `com.$USER.mlx-serve`, KeepAlive |
| Effort control | rewritten template in GGUF shard 1, `[effort:xhigh]` marker | request field `chat_template_kwargs: {enable_thinking, reasoning_effort}` |
| Thinking default | on (template, medium) | **off in mlx-serve unless the request turns it on** |
| Open WebUI | one connection (LM Studio) | two: LM Studio `:1234` (Gemma), mlx-serve `:11234` (Flash) |
| Auto Router | one URL for both models | v1.4.0: `STRONG_URL` for Flash, kwargs effort |
| Rollback | n/a | `FLASH_BACKEND=gguf` in `~/.config/macllm.env`, router valves back |

Keeping the id `flash-next` is the key decision: Flash-* personas reference it as their base
model, so if mlx-serve serves the same id they keep working without being rebuilt.

## Steps

### 1. Stable model folder and id

Give the pack a folder whose name is the model id, without copying 95 GB:

```
mkdir -p ~/.mlx-serve/models
ln -s ~/.cache/huggingface/hub/models--ddalcu--Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit/snapshots/788c07a8725642bccf13a0a3b8a21954ab84b4f2 ~/.mlx-serve/models/flash-next
```

Check: start mlx-serve with `--model ~/.mlx-serve/models/flash-next` and confirm
`curl -s http://127.0.0.1:11234/v1/models` lists `flash-next`. If it still shows the snapshot
hash (mlx-serve resolved the link), fall back to the hash as the id: set it in the router valve
and repoint the Flash-* personas once (step 5), and record the id in the system profile.

Pin the runtime so an unattended `brew upgrade` cannot change it under you:
`brew pin mlx-serve`. Upgrade on purpose: `brew unpin`, upgrade, run `llm-bench.py --label mlx-prod`
(v2 flags a drop over 7%), pin again.

### 2. LaunchAgent for mlx-serve

New template `m5/launchd/mlx-serve.plist.template`, rendered by `install.sh --launchd` the same
way as the flash-up agent:

- `ProgramArguments`: `/opt/homebrew/bin/mlx-serve --model __HOME__/.mlx-serve/models/flash-next
  --host 127.0.0.1 --port 11234 --ctx-size 131072 --mtp --no-pld --max-concurrent 2`
- `RunAtLoad` true, `KeepAlive` true, `ThrottleInterval` 30, `ExitTimeOut` 60.
- Logs: mlx-serve's own `~/.mlx-serve/logs/mlx-serve-11234.log` plus
  `~/Library/Logs/mlx-serve.log` for stdout/stderr.

Flag choices:
- `--host 127.0.0.1` is mandatory: the default is `0.0.0.0` (whole LAN).
- `--no-pld`: prompt-lookup drafting was not measured; MTP outranks it anyway.
- `--max-concurrent 2`: LM Studio ran Flash at parallel 4; mlx-serve defaults to 1, which queues a
  second Flash chat. Start at 2 and check memory in step 7; drop to 1 if peak wired passes ~104 GB.
- No `--ple-gpu`: keeps the 30 GB n-gram table mmapped instead of resident.
- No `--prefix-cache-disk`: the SSD prefix tier stays off.

`install.sh` change: loop over both templates (`flash-up`, `mlx-serve`) instead of one.

### 3. `flash-up.sh` and `flash-down.sh`

- Source `~/.config/macllm.env` if present; new setting `FLASH_BACKEND` (`mlx` default, `gguf`
  for rollback). Add `FLASH_BACKEND=mlx` to `env.example`.
- `mlx` mode: LM Studio loads Gemma only; the script `launchctl kickstart`s
  `gui/$UID/com.$USER.mlx-serve` if it is not running, waits up to 3 min for
  `http://127.0.0.1:11234/health`, then checks `/v1/models` lists `flash-next`. The model check
  covers both servers (Gemma on 1234, Flash on 11234).
- `gguf` mode: today's behaviour, plus `launchctl bootout` of the mlx-serve agent first, so the
  two Flash copies are never resident together.
- `flash-down.sh`: also stops the mlx-serve agent (`STOP_MLX=0` to leave it).
- LM Studio session restore: after the first `flash-up.sh` in `mlx` mode LM Studio's saved session
  holds only Gemma. Until that has happened once, a reboot could restore the GGUF beside mlx-serve.

### 4. Open WebUI

1. Admin → Settings → Connections → add OpenAI API `http://127.0.0.1:11234/v1`, no key, no prefix.
2. With the GGUF unloaded, the model list should show `flash-next` once (from mlx-serve) and Gemma
   (from LM Studio). Two `flash-next` entries mean both servers are serving it: unload the GGUF.
3. Flash-* personas: thinking must be turned on per request, because mlx-serve defaults it off and
   then answers worse (Oct 24: $83.33 instead of $75.00). Set the custom parameter
   `chat_template_kwargs` = `{"enable_thinking": true, "reasoning_effort": "medium"}` on one Flash
   persona, then copy it to the others with `owui-sync-flash.sh` (report → dry run → `DRY_RUN=0`).
   Flash-IT-Deep: `"reasoning_effort": "xhigh"`, and remove the `[effort:xhigh]` text from its
   system prompt (it is inert on MLX).
   Fallback if custom parameters do not reach the request: a small filter function (alongside
   `m5/openwebui/reasoning_budget_filter.py`) that adds the kwargs for Flash-* models.
4. Check each persona with the price question (step 7): a thinking block appears and the answer
   is $75.00.
5. Update the Open WebUI memory about the Flash engine (source text in `M5_MAX_SYSTEM_PROFILE.md`).

### 5. Auto Router v1.4.0

Changes to `m5/openwebui/auto_router.py`:

- New valves: `STRONG_URL` (default `http://127.0.0.1:11234/v1`; empty = `LMSTUDIO_URL`),
  `EFFORT_MODE` (`kwargs` default, `marker` for the GGUF), `STRONG_THINKING` (true),
  `STRONG_EFFORT` (`medium`), `DEEP_EFFORT` (`xhigh`).
- Flash requests go to `STRONG_URL`. In `kwargs` mode they carry
  `chat_template_kwargs: {"enable_thinking": STRONG_THINKING, "reasoning_effort": DEEP_EFFORT if deep else STRONG_EFFORT}`
  and no marker. `marker` mode keeps v1.3.4 behaviour for rollback.
- Gemma requests and the classifier stay on `LMSTUDIO_URL`.
- Error hint names the backend (`lms ps` for Gemma, mlx-serve health/log for Flash).
- `/route` also shows the backend and effort.
- Caps unchanged (8192 / 24576 / none); `max_tokens` is still the real length limit.
- `auto_router.m5.env.example` and `M5_MAX_AUTO_ROUTER_POLICY.md` updated to match.
- Offline test against two mock servers (Flash and Gemma on different ports) before deploying.

### 6. `llm-bench.py --load-url`

`--load-model` sends the background load to `--url`, so it cannot load Gemma on LM Studio while
measuring Flash on mlx-serve. Add `--load-url` (default: `--url`).

### 7. Verification (gate before calling it done)

| Check | Pass |
| --- | --- |
| `llm-bench.py --url http://127.0.0.1:11234/v1 --model flash-next --label mlx-prod --long-ctx 28000 --mem` | decode ≥ 85 tok/s, prefill ≥ 2,300 tok/s, peak wired ≤ 102 GB, no swap |
| Same plus `--load-url http://localhost:1234/v1 --load-model gemma-4-26b-a4b-it-qat --load-image ~/Pictures/test.png` | no swap, pressure normal; record both models' speed |
| `--streams 2` | both streams complete; peak wired ≤ 104 GB |
| Price question to `/flash` in Auto and to each Flash persona | thinking shown, $75.00 |
| `/deep` and a score-7 message | `/route` shows xhigh; status line shows the cap |
| Image with `/flash` | correct description |
| Test 1 (Raspberry Pi Wi-Fi prompt), end to end | record time; was ~35 s on the GGUF |
| Prefix cache (`llm-probe.py`, repeated 11.9K prompt) | second TTFT well under 1 s |
| Reboot | Gemma and Flash both serving with no manual step; `flash-up.log` and the mlx-serve log clean |
| Three days of normal use | no swap growth (`sysctl vm.swapusage`), no errors in the mlx-serve log |

Quality: before deleting the GGUF, run 10 of your own real prompts on both (GGUF at medium vs
mlx-serve at medium) and compare. The packs are different quantizations (4.27 bpw K-quant vs
mixed 4/8-bit affine).

### 8. Docs

`M5_MAX_SYSTEM_PROFILE.md` (engine, quant, effort, measured, memory, still open), README stack
table and daily-operations table (mlx-serve health/log commands), router policy doc, env examples.

## Rollback

1. `FLASH_BACKEND=gguf` in `~/.config/macllm.env`, then `~/bin/flash-up.sh` (stops the mlx-serve
   agent, loads the GGUF as `flash-next` again).
2. Auto Router valves: `STRONG_URL` empty, `EFFORT_MODE` `marker`.
3. Open WebUI: disable the `:11234` connection. Personas keep the `chat_template_kwargs`
   parameter; LM Studio ignores it, and the GGUF template defaults to medium anyway.

The GGUF and its rewritten shard 1 stay on disk until the switch has run for two weeks.

## Risks

| Risk | Mitigation |
| --- | --- |
| Memory: 100.2 GB peak wired with Gemma idle; Gemma busy and a second Flash stream add more | `--max-concurrent 1`, or drop MTP (−4.7 GB, keeps the 1.4x runtime gain) |
| Thinking silently off on any path that omits the kwargs | Router sets it; personas set it; price-question check per persona |
| Young third-party runtime (many experimental kernels, frequent releases) | `brew pin`; upgrade only with a `llm-bench` regression check; GGUF kept for rollback |
| Different quantization than the GGUF | Side-by-side prompt check before deleting the GGUF |
| LM Studio restores the GGUF at boot beside mlx-serve | Run `flash-up.sh` once in `mlx` mode before the first reboot; reboot check in step 7 |
| Default bind is the whole LAN | `--host 127.0.0.1` in the LaunchAgent; check with `lsof -nP -iTCP:11234 -sTCP:LISTEN` |
| Top-level `reasoning_effort` may be ignored by mlx-serve | Router and personas send it inside `chat_template_kwargs` |

## Order of commits

1. `install.sh` + `m5/launchd/mlx-serve.plist.template` (step 2)
2. `flash-up.sh` / `flash-down.sh` / `env.example` (step 3)
3. Auto Router v1.4.0 + env example + policy doc (step 5)
4. `llm-bench.py --load-url` (step 6)
5. Verification results (step 7) in CHANGELOG and README
6. System profile and README stack (step 8)
7. After two weeks: GGUF removal note, `lmstudio` Flash references cleaned up

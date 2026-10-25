# Test 1: Raspberry Pi Wi-Fi troubleshooting prompt

Fixed prompt for end-to-end comparisons of Flash-Next setups (runtime, quant, effort, router).

## Prompt

```
Step by step, troubleshoot why a Raspberry Pi 5 on my home LAN drops off Wi-Fi every night around 2 AM but comes back after a reboot. List the most likely causes in order of probability, the command to confirm each one, and the fix.
```

## Two ways to run it

1. **Open WebUI** (what a real chat costs): new chat, Auto or a Flash persona, paste the prompt,
   time it to the end of the answer. Includes the persona and memory context, which keep the
   answer short.
2. **API, bare prompt** (comparable across backends): set `URL` to the Flash server
   (`http://127.0.0.1:11234/v1` for mlx-serve, `http://localhost:1234/v1` for the LM Studio GGUF)
   and run the snippet below. Sampling matches the Auto Router (temperature 1.0), so length
   varies a lot run to run; compare tokens and tok/s, not just seconds.

```
URL=http://127.0.0.1:11234/v1 python3 - <<'PY'
import json, os, time, urllib.request
URL = os.environ.get("URL", "http://127.0.0.1:11234/v1")
Q = ("Step by step, troubleshoot why a Raspberry Pi 5 on my home LAN drops off Wi-Fi every night around 2 AM "
     "but comes back after a reboot. List the most likely causes in order of probability, the command to confirm "
     "each one, and the fix.")
for run in (1, 2):
    body = {"model": "flash-next", "max_tokens": 8192, "temperature": 1.0, "top_p": 0.95, "top_k": 20,
            "chat_template_kwargs": {"enable_thinking": True, "reasoning_effort": "medium"},
            "messages": [{"role": "user", "content": Q}]}
    t = time.time()
    req = urllib.request.Request(URL + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    m = json.load(urllib.request.urlopen(req, timeout=900))
    dt = time.time() - t
    msg = m["choices"][0]["message"]; u = m.get("usage", {})
    r, a = msg.get("reasoning_content") or "", msg.get("content") or ""
    print(f"run {run}: {dt:5.1f} s total | {u.get('completion_tokens')} tokens ({u.get('completion_tokens',0)/dt:.0f} tok/s) "
          f"| reasoning {len(r):,} chars | answer {len(a):,} chars | finish {m['choices'][0].get('finish_reason')}")
PY
```

## Results

| Date | Setup | Method | Result |
| --- | --- | --- | --- |
| 2026-10-10 | GGUF, stock template (xhigh) | Open WebUI | ~7.5 min, then ~4 min after prompt cleanup |
| 2026-10-11 | GGUF, medium template | Open WebUI | ~35 s |
| 2026-10-24 | mlx-serve + MTP, Auto (medium) | Open WebUI | thought 29 s; answer ~4.8K chars |
| 2026-10-25 | mlx-serve + MTP, medium | API bare | 65.5 s / 5,966 tok (91 tok/s); 59.1 s / 5,330 tok (90 tok/s) |
| 2026-10-25 | LM Studio GGUF, medium | API bare | 80.1 s / 3,755 tok (47 tok/s); 129.0 s / 6,074 tok (47 tok/s) |

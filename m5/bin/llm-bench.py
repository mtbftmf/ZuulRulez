#!/usr/bin/env python3
"""
llm-bench.py — repeatable tok/s benchmark for any OpenAI-compatible local server
(LM Studio, llama-server, Ollama, Atomic Chat, mlx-serve ...). Python 3 stdlib only.

Usage:
  python3 llm-bench.py --model flash-next                       # LM Studio default URL
  python3 llm-bench.py --model flash-next --url http://localhost:1234/v1
  python3 llm-bench.py --model qwen3.8 --url http://localhost:11434/v1   # Ollama

Tests (fixed prompts, temperature 0, 1 warm-up + 3 measured runs, median reported):
  gen     short prompt, 512-token answer  -> decode tok/s, time to first token
  prefill ~8K-token document, short answer -> prompt-processing tok/s

Decode tok/s counts every generated token, including reasoning/thinking tokens.
"""
import argparse, json, platform, statistics, subprocess, sys, time, urllib.request, urllib.error

GEN_PROMPT = ("Write a detailed, technical explanation of how a CPU cache hierarchy works "
              "(L1, L2, L3, cache lines, associativity, write-back vs write-through, coherence). "
              "Keep going until you reach the length limit.")

def long_doc(n_paragraphs=110):
    # Deterministic filler (~75 tokens per paragraph -> ~8K tokens), identical on every machine.
    paras = []
    for i in range(1, n_paragraphs + 1):
        paras.append(
            f"Section {i}. The maintenance log for pump station {i % 17} records a pressure reading "
            f"of {100 + (i * 37) % 250} kPa, a flow rate of {20 + (i * 13) % 80} liters per second, "
            f"and an inspection note stating that valve {i % 9} was cleaned and seal {i % 5} replaced. "
            f"Operators observed vibration level {(i * 7) % 10} on a ten-point scale during shift {i % 3 + 1}."
        )
    return "\n\n".join(paras)

PREFILL_PROMPT = long_doc() + "\n\nIn one sentence: which pump station number appears most often?"

MINIMAL = False  # set True automatically if the server rejects optional fields

def open_stream(url, payload, api_key):
    req = urllib.request.Request(f"{url.rstrip('/')}/chat/completions", data=json.dumps(payload).encode(),
                                 method="POST", headers={"Content-Type": "application/json",
                                                         "Authorization": f"Bearer {api_key}"})
    return urllib.request.urlopen(req, timeout=900)

def stream_chat(url, model, prompt, max_tokens, api_key):
    global MINIMAL
    # Unique first line defeats server-side prompt caching, so prefill is measured every run.
    nonce = f"[bench run {time.time_ns()}]\n"
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": nonce + prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
    }
    if not MINIMAL:
        payload.update({"seed": 42, "stream_options": {"include_usage": True}})
    t0 = time.perf_counter(); t_first = None; chunks = 0; usage = None
    try:
        resp = open_stream(url, payload, api_key)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "ignore")[:400]
        if e.code == 400 and not MINIMAL:
            print(f"  server rejected request ({detail.strip()}); retrying without seed/stream_options", flush=True)
            MINIMAL = True
            payload.pop("seed", None); payload.pop("stream_options", None)
            t0 = time.perf_counter()
            try:
                resp = open_stream(url, payload, api_key)
            except urllib.error.HTTPError as e2:
                raise RuntimeError(f"HTTP {e2.code}: {e2.read().decode('utf-8','ignore')[:400]}  "
                                   f"(is '{model}' loaded? check: lms ps)")
        else:
            raise RuntimeError(f"HTTP {e.code}: {detail}  (is '{model}' loaded? check: lms ps)")
    with resp:
        for raw in resp:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            try:
                obj = json.loads(data)
            except json.JSONDecodeError:
                continue
            if obj.get("usage"):
                usage = obj["usage"]
            for ch in obj.get("choices") or []:
                d = ch.get("delta") or {}
                if d.get("content") or d.get("reasoning_content") or d.get("reasoning"):
                    if t_first is None:
                        t_first = time.perf_counter()
                    chunks += 1
    t_end = time.perf_counter()
    if t_first is None:
        raise RuntimeError("no tokens received — check --model and --url")
    out_tokens = (usage or {}).get("completion_tokens") or chunks
    in_tokens = (usage or {}).get("prompt_tokens")
    if not in_tokens:  # server sent no usage: estimate ~4 chars/token, flagged in output
        in_tokens = round(len(payload["messages"][0]["content"]) / 4)
        est = True
    else:
        est = False
    decode_s = max(t_end - t_first, 1e-6)
    ttft = t_first - t0
    return {
        "ttft_s": ttft,
        "decode_tps": max(out_tokens - 1, 1) / decode_s,
        "prefill_tps": (in_tokens / ttft) if in_tokens else None,
        "out_tokens": out_tokens,
        "in_tokens": in_tokens,
        "usage_reported": usage is not None,
        "estimated": est,
    }

def machine_info():
    info = {"os": platform.platform()}
    if sys.platform == "darwin":
        def sysctl(k):
            try:
                return subprocess.check_output(["sysctl", "-n", k], text=True).strip()
            except Exception:
                return "?"
        info["chip"] = sysctl("machdep.cpu.brand_string")
        try:
            info["ram_gb"] = round(int(sysctl("hw.memsize")) / 1024**3)
        except ValueError:
            info["ram_gb"] = "?"
        try:
            sp = subprocess.check_output(["system_profiler", "SPDisplaysDataType"], text=True)
            cores = [l.split(":")[1].strip() for l in sp.splitlines() if "Total Number of Cores" in l]
            info["gpu_cores"] = cores[0] if cores else "?"
        except Exception:
            info["gpu_cores"] = "?"
    return info

def run_test(name, url, model, prompt, max_tokens, key, runs):
    print(f"[{name}] warm-up...", flush=True)
    stream_chat(url, model, prompt, max_tokens, key)
    results = []
    for i in range(runs):
        r = stream_chat(url, model, prompt, max_tokens, key)
        results.append(r)
        pf = f"{r['prefill_tps']:.0f}" if r["prefill_tps"] else "n/a"
        print(f"[{name}] run {i+1}: decode {r['decode_tps']:.1f} tok/s | TTFT {r['ttft_s']*1000:.0f} ms | "
              f"prefill {pf} tok/s | in {r['in_tokens']} / out {r['out_tokens']}", flush=True)
    med = lambda k: statistics.median([r[k] for r in results if r[k] is not None]) \
        if any(r[k] is not None for r in results) else None
    return {k: med(k) for k in ("decode_tps", "ttft_s", "prefill_tps", "in_tokens", "out_tokens")}, results

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, help="model ID as your server lists it")
    ap.add_argument("--url", default="http://localhost:1234/v1", help="OpenAI-compatible base URL")
    ap.add_argument("--api-key", default="local")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--engine", default="", help="label for the summary, e.g. 'LM Studio 0.4 GGUF'")
    ap.add_argument("--quant", default="", help="label for the summary, e.g. 'AD-4.27bpw-Q4_K_M-M64'")
    a = ap.parse_args()

    m = machine_info()
    print(f"Machine: {m}\nModel: {a.model} @ {a.url}\n")
    gen, _ = run_test("gen", a.url, a.model, GEN_PROMPT, 512, a.api_key, a.runs)
    pre, _ = run_test("prefill", a.url, a.model, PREFILL_PROMPT, 64, a.api_key, a.runs)

    fmt = lambda v, f: (f % v) if v is not None else "n/a"
    summary = (f"llm-bench v1 | {m.get('chip', m['os'])} {m.get('gpu_cores','?')}-core GPU {m.get('ram_gb','?')}GB | "
               f"{a.model}{(' ' + a.quant) if a.quant else ''}{(' / ' + a.engine) if a.engine else ''} | "
               f"decode {fmt(gen['decode_tps'], '%.1f')} tok/s | "
               f"TTFT {fmt(gen['ttft_s'] and gen['ttft_s']*1000, '%.0f')} ms | "
               f"prefill {fmt(pre['prefill_tps'], '%.0f')} tok/s @ {fmt(pre['in_tokens'], '%d')} tok"
               f"{' (token counts estimated)' if MINIMAL else ''}")
    print("\n=== Share this line ===\n" + summary)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr); sys.exit(1)

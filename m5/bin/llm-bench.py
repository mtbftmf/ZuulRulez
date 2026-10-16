#!/usr/bin/env python3
"""
llm-bench.py — repeatable tok/s benchmark for any OpenAI-compatible local server
(LM Studio, llama-server, Ollama, Atomic Chat, mlx-serve ...). Python 3 stdlib only.

Usage:
  python3 llm-bench.py --model flash-next                       # LM Studio default URL
  python3 llm-bench.py --model flash-next --url http://localhost:1234/v1
  python3 llm-bench.py --model qwen3.8 --url http://localhost:11434/v1   # Ollama

  python3 llm-bench.py --model flash-next --long-ctx 28000      # + decode speed deep in a long context
  python3 llm-bench.py --model flash-next --mem                 # + memory pressure / swap / page-ins per test
  python3 llm-bench.py --model flash-next --mem --long-ctx 28000 \\
      --load-model gemma-4-26b-a4b-it-qat --load-image ~/Pictures/test.png
                                                                # combined load: Gemma vision traffic
                                                                # runs while flash-next is measured

Tests (fixed prompts, temperature 0, 1 warm-up + 3 measured runs, median reported):
  gen     short prompt, 512-token answer  -> decode tok/s, time to first token
  prefill ~8K-token document, short answer -> prompt-processing tok/s
  long    (--long-ctx N) ~N-token document, 256-token answer -> decode tok/s at depth N.
          Hybrid linear-attention models (Gated DeltaNet, Mamba) should hold decode nearly flat
          here; pure-attention models slow down as the KV cache grows. Keep N under the context
          length the model is loaded with, per parallel slot.

Options:
  --mem         macOS: sample memory every 0.5 s during each test's measured runs and report
                peak wired, peak compressor, worst pressure level, swap growth and page-ins.
                Page-ins during a run mean weights (e.g. an mmap'd embedding table) are being
                read back from SSD.
  --load-model  keep a second model busy (back-to-back requests) for the whole benchmark, to
                measure the main model under contention. --load-image sends an image with each
                of those requests (vision workload).

Decode tok/s counts every generated token, including reasoning/thinking tokens.
"""
import argparse, base64, json, mimetypes, os, platform, re, statistics, subprocess, sys, threading, time
import urllib.request, urllib.error

GEN_PROMPT = ("Write a detailed, technical explanation of how a CPU cache hierarchy works "
              "(L1, L2, L3, cache lines, associativity, write-back vs write-through, coherence). "
              "Keep going until you reach the length limit.")

TOKENS_PER_PARA = 71  # measured: 110 paragraphs -> ~7,790 tokens on Qwen and Gemma tokenizers

def long_doc(n_paragraphs=110):
    # Deterministic filler (~71 tokens per paragraph), identical on every machine.
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

def long_prompt(target_tokens):
    n = max(1, round(target_tokens / TOKENS_PER_PARA))
    return (long_doc(n) + "\n\nWrite a detailed technical maintenance report on the log above: trends in "
            "pressure, flow and vibration by station and shift, likely failure modes, and a prioritized "
            "action plan. Keep going until you reach the length limit.")

MINIMAL = False  # set True automatically if the server rejects optional fields

def open_stream(url, payload, api_key):
    req = urllib.request.Request(f"{url.rstrip('/')}/chat/completions", data=json.dumps(payload).encode(),
                                 method="POST", headers={"Content-Type": "application/json",
                                                         "Authorization": f"Bearer {api_key}"})
    return urllib.request.urlopen(req, timeout=900)

def _content_chars(content):
    if isinstance(content, str):
        return len(content)
    return sum(len(p.get("text", "")) for p in content if p.get("type") == "text")

def stream_chat(url, model, prompt, max_tokens, api_key, stop=None):
    """prompt: a string, or a list of OpenAI content parts (text / image_url)."""
    global MINIMAL
    # Unique first line defeats server-side prompt caching, so prefill is measured every run.
    nonce = f"[bench run {time.time_ns()}]\n"
    if isinstance(prompt, str):
        content = nonce + prompt
    else:
        content = [{"type": "text", "text": nonce}] + prompt
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": content}],
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
        if e.code == 400 and not MINIMAL and not re.search(r"context|n_ctx|too long|exceed", detail, re.I):
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
            if stop is not None and stop.is_set():
                break
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
        if stop is not None and stop.is_set():
            return None
        raise RuntimeError("no tokens received — check --model and --url")
    out_tokens = (usage or {}).get("completion_tokens") or chunks
    in_tokens = (usage or {}).get("prompt_tokens")
    if not in_tokens:  # server sent no usage: estimate ~4 chars/token, flagged in output
        in_tokens = round(_content_chars(payload["messages"][0]["content"]) / 4)
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

# ---------------- memory sampling (macOS) ----------------
PRESSURE = {1: "normal", 2: "warn", 4: "critical"}

def mem_snapshot():
    """Wired / compressor bytes, cumulative page-ins, swap used bytes, pressure level. macOS only."""
    vm = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    m = re.search(r"page size of (\d+) bytes", vm)
    page = int(m.group(1)) if m else 16384
    def pages(label):
        mm = re.search(rf"^{re.escape(label)}:\s+(\d+)", vm, re.M)
        return int(mm.group(1)) if mm else 0
    swap = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    sm = re.search(r"used = ([\d.]+)([KMG])", swap)
    swap_used = int(float(sm.group(1)) * {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30}[sm.group(2)]) if sm else 0
    lvl = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], capture_output=True, text=True).stdout
    try:
        level = int(lvl.strip())
    except ValueError:
        level = 0
    return {
        "wired": pages("Pages wired down") * page,
        "compressor": pages("Pages occupied by compressor") * page,
        "pageins": pages("Pageins") * page,
        "swap_used": swap_used,
        "pressure": level,
    }

class MemSampler:
    def __init__(self, interval=0.5):
        self.interval = interval; self.samples = []; self._stop = threading.Event(); self._t = None
    def __enter__(self):
        self.samples = [mem_snapshot()]
        self._t = threading.Thread(target=self._loop, daemon=True); self._t.start()
        return self
    def _loop(self):
        while not self._stop.wait(self.interval):
            try:
                self.samples.append(mem_snapshot())
            except Exception:
                pass
    def __exit__(self, *exc):
        self._stop.set(); self._t.join()
        self.samples.append(mem_snapshot())
    def report(self):
        s0, s1 = self.samples[0], self.samples[-1]
        return {
            "peak_wired": max(s["wired"] for s in self.samples),
            "peak_compressor": max(s["compressor"] for s in self.samples),
            "worst_pressure": max(s["pressure"] for s in self.samples),
            "swap_growth": s1["swap_used"] - s0["swap_used"],
            "pageins": s1["pageins"] - s0["pageins"],
        }

def gb(n):
    return f"{n / (1 << 30):.1f} GB"

def fmt_mem(r):
    return (f"peak wired {gb(r['peak_wired'])} | peak compressor {gb(r['peak_compressor'])} | "
            f"pressure {PRESSURE.get(r['worst_pressure'], '?')} | swap +{gb(max(r['swap_growth'], 0))} | "
            f"page-ins {gb(r['pageins'])}")

# ---------------- background load on a second model ----------------
class BackgroundLoad:
    """Back-to-back requests to a second model until stopped. Counts completed requests."""
    def __init__(self, url, model, key, image=None):
        self.url, self.model, self.key = url, model, key
        self.prompt = GEN_PROMPT
        if image:
            with open(os.path.expanduser(image), "rb") as f:
                b64 = base64.b64encode(f.read()).decode()
            mime = mimetypes.guess_type(image)[0] or "image/png"
            self.prompt = [{"type": "text", "text": "Describe this image in detail, then keep going "
                            "with a long technical analysis until you reach the length limit."},
                           {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{b64}"}}]
        self.done = 0; self.tps = []; self.error = None
        self._stop = threading.Event(); self._t = None
    def start(self):
        self._t = threading.Thread(target=self._loop, daemon=True); self._t.start()
        return self
    def _loop(self):
        while not self._stop.is_set():
            try:
                r = stream_chat(self.url, self.model, self.prompt, 512, self.key, stop=self._stop)
            except Exception as e:
                self.error = str(e); return
            if r is not None and not self._stop.is_set():
                self.done += 1; self.tps.append(r["decode_tps"])
    def stop(self):
        self._stop.set(); self._t.join(timeout=30)

def run_test(name, url, model, prompt, max_tokens, key, runs, mem=False):
    print(f"[{name}] warm-up...", flush=True)
    stream_chat(url, model, prompt, max_tokens, key)
    results = []
    sampler = MemSampler() if mem else None
    if sampler:
        sampler.__enter__()
    try:
        for i in range(runs):
            r = stream_chat(url, model, prompt, max_tokens, key)
            results.append(r)
            pf = f"{r['prefill_tps']:.0f}" if r["prefill_tps"] else "n/a"
            print(f"[{name}] run {i+1}: decode {r['decode_tps']:.1f} tok/s | TTFT {r['ttft_s']*1000:.0f} ms | "
                  f"prefill {pf} tok/s | in {r['in_tokens']} / out {r['out_tokens']}", flush=True)
    finally:
        if sampler:
            sampler.__exit__(None, None, None)
    memr = sampler.report() if sampler else None
    if memr:
        print(f"[{name}] memory: {fmt_mem(memr)}", flush=True)
    med = lambda k: statistics.median([r[k] for r in results if r[k] is not None]) \
        if any(r[k] is not None for r in results) else None
    summary = {k: med(k) for k in ("decode_tps", "ttft_s", "prefill_tps", "in_tokens", "out_tokens")}
    summary["mem"] = memr
    return summary, results

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True, help="model ID as your server lists it")
    ap.add_argument("--url", default="http://localhost:1234/v1", help="OpenAI-compatible base URL")
    ap.add_argument("--api-key", default="local")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--engine", default="", help="label for the summary, e.g. 'LM Studio 0.4 GGUF'")
    ap.add_argument("--quant", default="", help="label for the summary, e.g. 'AD-4.27bpw-Q4_K_M-M64'")
    ap.add_argument("--long-ctx", type=int, default=0, metavar="N",
                    help="also measure decode after ~N input tokens (e.g. 28000; must fit the loaded context)")
    ap.add_argument("--mem", action="store_true", help="macOS: sample memory during each test")
    ap.add_argument("--load-model", default="", help="second model to keep busy during the benchmark")
    ap.add_argument("--load-image", default="", help="image file sent with each --load-model request")
    a = ap.parse_args()

    if a.mem and sys.platform != "darwin":
        print("note: --mem needs macOS (vm_stat, sysctl); skipping memory sampling", file=sys.stderr)
        a.mem = False
    if a.load_image and not a.load_model:
        ap.error("--load-image needs --load-model")
    if a.load_image and not os.path.isfile(os.path.expanduser(a.load_image)):
        ap.error(f"--load-image: no such file: {a.load_image}  "
                 f"(make one with: screencapture -x ~/Pictures/test.png)")

    m = machine_info()
    print(f"Machine: {m}\nModel: {a.model} @ {a.url}")
    load = None
    if a.load_model:
        print(f"Background load: {a.load_model}{' + image ' + os.path.basename(a.load_image) if a.load_image else ''}")
        load = BackgroundLoad(a.url, a.load_model, a.api_key, a.load_image or None).start()
    if a.mem:
        s = mem_snapshot()
        print(f"Memory before: wired {gb(s['wired'])} | compressor {gb(s['compressor'])} | "
              f"swap used {gb(s['swap_used'])} | pressure {PRESSURE.get(s['pressure'], '?')}")
    print()

    long_res = long_err = None
    try:
        gen, _ = run_test("gen", a.url, a.model, GEN_PROMPT, 512, a.api_key, a.runs, a.mem)
        pre, _ = run_test("prefill", a.url, a.model, PREFILL_PROMPT, 64, a.api_key, a.runs, a.mem)
        if a.long_ctx:
            try:
                long_res, _ = run_test("long", a.url, a.model, long_prompt(a.long_ctx), 256,
                                       a.api_key, a.runs, a.mem)
            except RuntimeError as e:
                long_err = str(e)
                print(f"[long] failed: {long_err}\n[long] hint: lower --long-ctx, or raise the loaded context "
                      f"(with parallel > 1 the context may be split across slots)", flush=True)
    finally:
        if load:
            load.stop()

    fmt = lambda v, f: (f % v) if v is not None else "n/a"
    summary = (f"llm-bench v1 | {m.get('chip', m['os'])} {m.get('gpu_cores','?')}-core GPU {m.get('ram_gb','?')}GB | "
               f"{a.model}{(' ' + a.quant) if a.quant else ''}{(' / ' + a.engine) if a.engine else ''} | "
               f"decode {fmt(gen['decode_tps'], '%.1f')} tok/s | "
               f"TTFT {fmt(gen['ttft_s'] and gen['ttft_s']*1000, '%.0f')} ms | "
               f"prefill {fmt(pre['prefill_tps'], '%.0f')} tok/s @ {fmt(pre['in_tokens'], '%d')} tok")
    if long_res:
        summary += (f" | long decode {fmt(long_res['decode_tps'], '%.1f')} tok/s @ "
                    f"{fmt(long_res['in_tokens'], '%d')} tok")
    if load:
        what = f"{a.load_model}{' +image' if a.load_image else ''}"
        summary += f" | under load: {what}"
    if MINIMAL:
        summary += " (token counts estimated)"
    print("\n=== Share this line ===\n" + summary)

    if load:
        bt = f"{statistics.median(load.tps):.1f} tok/s median" if load.tps else "no completed requests"
        print(f"Background {a.load_model}: {load.done} requests completed, {bt}"
              + (f" (error: {load.error})" if load.error else ""))
    if a.mem:
        worst = [r["mem"] for r in (gen, pre, long_res) if r and r.get("mem")]
        if worst:
            agg = {
                "peak_wired": max(r["peak_wired"] for r in worst),
                "peak_compressor": max(r["peak_compressor"] for r in worst),
                "worst_pressure": max(r["worst_pressure"] for r in worst),
                "swap_growth": sum(r["swap_growth"] for r in worst),
                "pageins": sum(r["pageins"] for r in worst),
            }
            print(f"Memory (all tests): {fmt_mem(agg)}")
            if agg["swap_growth"] > (256 << 20) or agg["worst_pressure"] >= 2:
                print("Memory warning: swap grew or pressure left 'normal'. Expect stutter; reduce context, "
                      "parallel slots, or the second model's load.")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr); sys.exit(1)

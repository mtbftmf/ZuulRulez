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
  python3 llm-bench.py --model flash-next --sweep 16000,24000,30000 --label fa-on
                                                                # prefill + decode at several depths
  python3 llm-bench.py --model flash-next --streams 2           # + 1 vs 2 simultaneous requests
  python3 llm-bench.py --history                                # list saved runs and exit

Tests (fixed prompts, temperature 0, 1 warm-up + 3 measured runs, median reported):
  gen     short prompt, 512-token answer  -> decode tok/s, time to first token
  prefill ~8K-token document, short answer -> prompt-processing tok/s
  long    (--long-ctx N) ~N-token document, 256-token answer -> decode tok/s at depth N.
          Hybrid linear-attention models (Gated DeltaNet, Mamba) should hold decode nearly flat
          here; pure-attention models slow down as the KV cache grows. Keep N under the context
          length the model is loaded with, per parallel slot.

  sweep   (--sweep N,N,...) one ~N-token document per size, 128-token answer, --sweep-runs runs
          each (default 2, no warm-up) -> prefill tok/s, TTFT and decode tok/s at each depth.
  streams (--streams N) N copies of the gen test at the same time -> per-stream and total tok/s.

Options:
  --label       tag for this run (e.g. fa-on, fa-off, par1). Runs are saved to the history file
                (default ~/llm-bench-history.jsonl, --history-file to change, --no-save to skip)
                and compared with the last saved run of the same model and label (or of --vs LABEL):
                a drop of more than --regress-pct (default 7%) in decode/prefill, or TTFT up by more,
                is flagged.
  --mem         macOS: sample memory every 0.5 s during each test's measured runs and report
                peak wired, peak compressor, worst pressure level, swap growth and page-ins.
                Page-ins during a run mean weights (e.g. an mmap'd embedding table) are being
                read back from SSD.
  --load-model  keep a second model busy (back-to-back requests) for the whole benchmark, to
                measure the main model under contention. --load-image sends an image with each
                of those requests (vision workload). --load-url sends that load to another server
                (default: --url), e.g. Gemma on LM Studio while Flash is measured on mlx-serve.

Decode tok/s counts every generated token, including reasoning/thinking tokens; the gen test
also shows how many of them were reasoning vs answer. For effort A/B on your own prompt use
llm-probe.py --suite effort --effort-prompt "...".
"""
import argparse, base64, json, mimetypes, os, platform, re, statistics, subprocess, sys, threading, time
from datetime import datetime
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

VERSION = 2
MINIMAL = False  # set True automatically if the server rejects optional fields
HISTORY_DEFAULT = os.path.expanduser("~/llm-bench-history.jsonl")

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
    n_reason = n_answer = 0; in_think = False
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
                r, c = d.get("reasoning_content") or d.get("reasoning"), d.get("content")
                if r or c:
                    if t_first is None:
                        t_first = time.perf_counter()
                    chunks += 1
                if r:
                    n_reason += 1
                if c:
                    if "<think>" in c:
                        in_think = True
                    if in_think:
                        n_reason += 1
                    else:
                        n_answer += 1
                    if "</think>" in c:
                        in_think = False
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
    details = (usage or {}).get("completion_tokens_details") or {}
    reason_tokens = details.get("reasoning_tokens")
    if reason_tokens is None and (n_reason + n_answer):
        reason_tokens = round(out_tokens * n_reason / (n_reason + n_answer))
    decode_s = max(t_end - t_first, 1e-6)
    ttft = t_first - t0
    return {
        "ttft_s": ttft,
        "decode_tps": max(out_tokens - 1, 1) / decode_s,
        "prefill_tps": (in_tokens / ttft) if in_tokens else None,
        "out_tokens": out_tokens,
        "in_tokens": in_tokens,
        "reasoning_tokens": reason_tokens,
        "t_first": t_first, "t_end": t_end,
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

def run_test(name, url, model, prompt, max_tokens, key, runs, mem=False, warmup=True):
    if warmup:
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
                  f"prefill {pf} tok/s | in {r['in_tokens']} / out {r['out_tokens']}"
                  + (f" ({r['reasoning_tokens']} reasoning)" if r.get("reasoning_tokens") else ""), flush=True)
    finally:
        if sampler:
            sampler.__exit__(None, None, None)
    memr = sampler.report() if sampler else None
    if memr:
        print(f"[{name}] memory: {fmt_mem(memr)}", flush=True)
    med = lambda k: statistics.median([r[k] for r in results if r[k] is not None]) \
        if any(r[k] is not None for r in results) else None
    summary = {k: med(k) for k in ("decode_tps", "ttft_s", "prefill_tps", "in_tokens", "out_tokens",
                                   "reasoning_tokens")}
    summary["mem"] = memr
    return summary, results

def run_streams(url, model, key, n):
    """n copies of the gen test at once (after the gen warm-up). Returns per-stream and total tok/s."""
    print(f"[streams] {n} simultaneous gen requests...", flush=True)
    out, errs = [None] * n, []
    def one(i):
        try:
            out[i] = stream_chat(url, model, GEN_PROMPT, 512, key)
        except Exception as e:
            errs.append(str(e))
    ts = [threading.Thread(target=one, args=(i,)) for i in range(n)]
    for t in ts: t.start()
    for t in ts: t.join()
    res = [r for r in out if r]
    if errs or not res:
        raise RuntimeError("; ".join(errs) or "no results")
    span = max(r["t_end"] for r in res) - min(r["t_first"] for r in res)
    total = sum(r["out_tokens"] for r in res) / max(span, 1e-6)
    per = statistics.median(r["decode_tps"] for r in res)
    worst_ttft = max(r["ttft_s"] for r in res)
    print(f"[streams] per stream {per:.1f} tok/s (median) | total {total:.1f} tok/s | "
          f"slowest TTFT {worst_ttft*1000:.0f} ms", flush=True)
    return {"n": n, "decode_tps": per, "total_tps": total, "ttft_s": worst_ttft}

# ---------------- history and regression check ----------------
LOWER_IS_WORSE = ("decode_tps", "prefill_tps", "total_tps")
# Metrics worth flagging per test (short prompts make prefill noise; 64-token answers make decode noise).
TRACKED = {"gen": ("decode_tps", "ttft_s"), "prefill": ("prefill_tps",), "long": ("decode_tps", "prefill_tps"),
           "sweep": ("prefill_tps", "decode_tps"), "streams": ("decode_tps", "total_tps")}

def flat_metrics(tests):
    """{'gen.decode_tps': 48.8, 'sweep@16000.prefill_tps': ...} for comparison."""
    out = {}
    for name, t in tests.items():
        if not t:
            continue
        for k in TRACKED.get(name.split("@")[0], ()):
            if t.get(k) is not None:
                out[f"{name}.{k}"] = t[k]
    return out

def load_history(path):
    rows = []
    try:
        with open(path) as f:
            for line in f:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except FileNotFoundError:
        pass
    return rows

def compare(prev, cur_tests, pct):
    """Print deltas vs the previous run; return the list of regressions."""
    a, b = flat_metrics(prev["tests"]), flat_metrics(cur_tests)
    common = [k for k in b if k in a and a[k]]
    if not common:
        return []
    print(f"\nCompared with {prev['ts']} (label {prev['label']}):")
    bad = []
    for k in common:
        d = (b[k] - a[k]) / a[k] * 100
        worse = (-d if k.split(".")[1] in LOWER_IS_WORSE else d) > pct
        if k.endswith("ttft_s") and b[k] - a[k] < 0.02:  # ignore TTFT changes under 20 ms
            worse = False
        unit = "ms" if k.endswith("ttft_s") else "tok/s"
        scale = 1000 if unit == "ms" else 1
        flag = "  <-- SLOWER" if worse else ""
        print(f"  {k:<28} {a[k]*scale:9.1f} -> {b[k]*scale:9.1f} {unit:<5} ({d:+.1f}%){flag}")
        if worse:
            bad.append(k)
    print(f"  SLOWDOWN: {', '.join(bad)} (threshold {pct:g}%)" if bad else f"  No slowdown beyond {pct:g}%")
    return bad

def show_history(path, n=20):
    rows = load_history(path)
    if not rows:
        print(f"No saved runs in {path}")
        return
    for r in rows[-n:]:
        print(f"{r['ts']}  {r['label']:<12} {r.get('summary', '')}")

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", help="model ID as your server lists it (required unless --history)")
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
    ap.add_argument("--load-url", default="", help="base URL for --load-model (default: --url)")
    ap.add_argument("--sweep", default="", metavar="N,N,...",
                    help="prefill + decode at these prompt sizes (e.g. 16000,24000,30000)")
    ap.add_argument("--sweep-runs", type=int, default=2, help="runs per sweep size (default 2, no warm-up)")
    ap.add_argument("--streams", type=int, default=0, metavar="N", help="also run N gen requests at once")
    ap.add_argument("--label", default="default", help="tag for this run, e.g. fa-on, fa-off")
    ap.add_argument("--history-file", default=HISTORY_DEFAULT)
    ap.add_argument("--no-save", action="store_true", help="do not append this run to the history file")
    ap.add_argument("--regress-pct", type=float, default=7.0, help="flag changes worse than this (default 7)")
    ap.add_argument("--vs", default="", metavar="LABEL", help="compare with the last run of this label instead")
    ap.add_argument("--history", action="store_true", help="list saved runs and exit")
    a = ap.parse_args()
    if a.history:
        show_history(a.history_file); return
    if not a.model:
        ap.error("--model is required")
    try:
        sweep = [int(x) for x in a.sweep.split(",") if x.strip()]
    except ValueError:
        ap.error("--sweep: comma-separated token counts, e.g. 16000,30000")

    if a.mem and sys.platform != "darwin":
        print("note: --mem needs macOS (vm_stat, sysctl); skipping memory sampling", file=sys.stderr)
        a.mem = False
    if a.load_image and not a.load_model:
        ap.error("--load-image needs --load-model")
    if a.load_url and not a.load_model:
        ap.error("--load-url needs --load-model")
    if a.load_image and not os.path.isfile(os.path.expanduser(a.load_image)):
        ap.error(f"--load-image: no such file: {a.load_image}  "
                 f"(make one with: screencapture -x ~/Pictures/test.png)")

    m = machine_info()
    print(f"Machine: {m}\nModel: {a.model} @ {a.url}")
    load = None
    if a.load_model:
        load_url = a.load_url or a.url
        print(f"Background load: {a.load_model}{' + image ' + os.path.basename(a.load_image) if a.load_image else ''}"
              + (f" @ {load_url}" if a.load_url else ""))
        load = BackgroundLoad(load_url, a.load_model, a.api_key, a.load_image or None).start()
    if a.mem:
        s = mem_snapshot()
        print(f"Memory before: wired {gb(s['wired'])} | compressor {gb(s['compressor'])} | "
              f"swap used {gb(s['swap_used'])} | pressure {PRESSURE.get(s['pressure'], '?')}")
    print()

    long_res = long_err = streams_res = None
    sweep_res = {}
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
        for n in sweep:
            try:
                sweep_res[n], _ = run_test(f"sweep@{n}", a.url, a.model, long_prompt(n), 128,
                                           a.api_key, a.sweep_runs, a.mem, warmup=False)
            except RuntimeError as e:
                print(f"[sweep@{n}] failed: {e}", flush=True)
                break
        if a.streams > 1:
            try:
                streams_res = run_streams(a.url, a.model, a.api_key, a.streams)
            except RuntimeError as e:
                print(f"[streams] failed: {e}", flush=True)
    finally:
        if load:
            load.stop()

    fmt = lambda v, f: (f % v) if v is not None else "n/a"
    summary = (f"llm-bench v{VERSION} | {m.get('chip', m['os'])} {m.get('gpu_cores','?')}-core GPU {m.get('ram_gb','?')}GB | "
               f"{a.model}{(' ' + a.quant) if a.quant else ''}{(' / ' + a.engine) if a.engine else ''} | "
               f"decode {fmt(gen['decode_tps'], '%.1f')} tok/s | "
               f"TTFT {fmt(gen['ttft_s'] and gen['ttft_s']*1000, '%.0f')} ms | "
               f"prefill {fmt(pre['prefill_tps'], '%.0f')} tok/s @ {fmt(pre['in_tokens'], '%d')} tok")
    if long_res:
        summary += (f" | long decode {fmt(long_res['decode_tps'], '%.1f')} tok/s @ "
                    f"{fmt(long_res['in_tokens'], '%d')} tok")
    for n, r in sweep_res.items():
        summary += (f" | @{fmt(r['in_tokens'], '%d')}: prefill {fmt(r['prefill_tps'], '%.0f')}, "
                    f"decode {fmt(r['decode_tps'], '%.1f')}")
    if streams_res:
        summary += (f" | {streams_res['n']} streams: {streams_res['decode_tps']:.1f} each, "
                    f"{streams_res['total_tps']:.1f} total")
    if gen.get("reasoning_tokens"):
        summary += f" | gen reasoning {gen['reasoning_tokens']:.0f}/{gen['out_tokens']:.0f} tok"
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

    tests = {"gen": gen, "prefill": pre, "long": long_res, "streams": streams_res,
             **{f"sweep@{n}": r for n, r in sweep_res.items()}}
    tests = {k: ({kk: vv for kk, vv in v.items() if kk != "mem"} if v else None) for k, v in tests.items()}
    same = lambda r: (r.get("model") == a.model and r.get("label") == (a.vs or a.label)
                      and r.get("machine", {}).get("chip") == m.get("chip") and r.get("load") == (a.load_model or None))
    prev = next((r for r in reversed(load_history(a.history_file)) if same(r)), None)
    if prev:
        compare(prev, tests, a.regress_pct)
    elif not a.no_save:
        print(f"\nFirst saved run for {a.model} / label {a.label}; later runs are compared with it.")
    if not a.no_save:
        rec = {"ts": datetime.now().isoformat(timespec="seconds"), "version": VERSION, "label": a.label,
               "model": a.model, "url": a.url, "engine": a.engine, "quant": a.quant, "machine": m,
               "load": a.load_model or None, "runs": a.runs, "tests": tests, "summary": summary}
        with open(a.history_file, "a") as f:
            f.write(json.dumps(rec) + "\n")
        print(f"Saved to {a.history_file}  (list: {os.path.basename(sys.argv[0])} --history)")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr); sys.exit(1)

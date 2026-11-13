#!/usr/bin/env python3
"""flash-ctx2-test.py - several long prompts at once against the mlx-serve servers, with memory sampling.

  python3 flash-ctx2-test.py --stage 1     two 100K-token prompts on Flash at the same time
  python3 flash-ctx2-test.py --stage 2     one 150K prompt on Flash plus one 24K prompt on Gemma at the same time
  python3 flash-ctx2-test.py --stage 3     two 180K-token prompts on Flash at the same time (the worst case)

Run one stage at a time, in order, and read the verdict before the next. Every prompt is different random text, and the
seeds come from the clock, so neither two prompts in one run nor prompts from different runs share a prefix (the prefix cache
cannot help). Each prompt ends in a one-sentence question, and each request streams a 128-token answer. The prompt
size is calibrated against the server's own token count, so the sizes are close to the target, not exact.
While the requests run it samples, every --interval seconds: swap used, memory pressure level (1 normal, 2 warn, 4 critical),
free percentage, Pageouts / Swapouts, wired and compressor memory, and Flash's /metrics.json gauges. It aborts if the pressure
level reaches 4 or swap used grows by more than 1500 MB. A log (JSON lines) goes to ~/ctx2-test-<time>.jsonl.
Needs only the Python standard library and the macOS tools sysctl, vm_stat and memory_pressure. Read-only on the system; it
only sends chat requests. Do not run it while a chat is in progress. Overrides: --flash, --gemma (base URLs), --ctx (the
configured --ctx-size, default 196608), --scale (shrinks the prompts, for a dry run of the script itself).
"""
import argparse, json, os, random, re, subprocess, sys, threading, time, urllib.request

STAGES = {
    1: [("A", "flash", 100000), ("B", "flash", 100000)],
    2: [("A", "flash", 150000), ("G", "gemma", 24000)],
    3: [("A", "flash", 180000), ("B", "flash", 180000)],
}
MAX_OUT = 128
SWAP_ABORT_MB = 1500.0
SWAP_PASS_MB, SWAP_WARN_MB = 100.0, 500.0


def http_json(url, body=None, timeout=60):
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def gauge(base, name):
    try:
        return http_json(base + "/metrics.json", timeout=5)["gauges"].get(name)
    except Exception:
        return None


def sample(flash, gemma):
    s = {"t": time.time()}
    m = re.search(r"used = ([\d.]+)M", run(["sysctl", "-n", "vm.swapusage"]))
    s["swap_mb"] = float(m.group(1)) if m else None
    out = run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip()
    s["level"] = int(out) if out.isdigit() else None
    mp = run(["memory_pressure"]).strip().splitlines()
    m = re.search(r"(\d+)%", mp[-1]) if mp else None
    s["free_pct"] = int(m.group(1)) if m else None
    vm = run(["vm_stat"])
    m = re.search(r"page size of (\d+) bytes", vm)
    ps = int(m.group(1)) if m else 16384
    def pages(label):
        m = re.search(label + r":\s+(\d+)\.", vm)
        return int(m.group(1)) if m else None
    for key, label in (("pageouts", "Pageouts"), ("swapouts", "Swapouts")):
        s[key] = pages(label)
    for key, label in (("wired_gb", "Pages wired down"), ("compressor_gb", "Pages occupied by compressor")):
        p = pages(label)
        s[key] = None if p is None else round(p * ps / 1e9, 2)
    s["flash_running"] = gauge(flash, "requests_running")
    s["flash_mem_mb"] = gauge(flash, "memory_mb")
    s["gemma_running"] = gauge(gemma, "requests_running")
    return s


class Sampler(threading.Thread):
    def __init__(self, flash, gemma, interval, log, abort):
        super().__init__(daemon=True)
        self.flash, self.gemma, self.interval, self.log, self.abort = flash, gemma, interval, log, abort
        self.samples, self.stop = [], threading.Event()
        self.base = sample(flash, gemma)
        self.samples.append(self.base)

    def run(self):
        while not self.stop.wait(self.interval):
            s = sample(self.flash, self.gemma)
            self.samples.append(s)
            self.log.write(json.dumps({"sample": s}) + "\n"); self.log.flush()
            b = self.base.get("swap_mb")
            if (s["level"] or 0) >= 4 or (b is not None and s["swap_mb"] is not None and s["swap_mb"] - b > SWAP_ABORT_MB):
                print(f"ABORT: pressure level {s['level']}, swap used {s['swap_mb']} MB (baseline {b})", flush=True)
                self.abort.set()


def make_doc(seed, nwords):
    rng = random.Random(seed)
    syl = ["ka", "to", "mi", "ren", "sa", "lu", "vo", "dre", "an", "el", "or", "in", "ba", "ti", "qua", "nes"]
    vocab = ["".join(rng.choice(syl) for _ in range(rng.randint(1, 3))) for _ in range(3000)]
    lines, cur = [f"Document {seed}."], []
    for i in range(nwords):
        cur.append(rng.choice(vocab))
        if len(cur) == 14:
            lines.append(" ".join(cur) + "."); cur = []
    if cur:
        lines.append(" ".join(cur) + ".")
    return "\n".join(lines) + "\n\nIn one sentence, what is this document about?"


def calibrate(base, model):
    """tokens per generated word, from the server's own prompt_tokens for a 4000-word sample"""
    r = http_json(base + "/v1/chat/completions", {"model": model, "max_tokens": 1, "stream": False, "temperature": 0,
                  "messages": [{"role": "user", "content": make_doc(999, 4000)}]}, timeout=300)
    toks = r["usage"]["prompt_tokens"]
    return max(toks / 4000.0, 0.1)


def model_id(base):
    return http_json(base + "/v1/models", timeout=10)["data"][0]["id"]


def one_request(name, base, model, nwords, seed, out, abort):
    res = {"name": name, "base": base, "ttft": None, "total": None, "chunks": 0, "prompt_tokens": None, "error": None, "finish": None}
    out[name] = res
    t0 = time.time()
    try:
        body = {"model": model, "max_tokens": MAX_OUT, "stream": True, "temperature": 0,
                "stream_options": {"include_usage": True},
                "messages": [{"role": "user", "content": make_doc(seed, nwords)}]}
        req = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=1500) as r:
            for raw in r:
                if abort.is_set():
                    res["error"] = "aborted"; break
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                obj = json.loads(payload)
                if obj.get("error") and not res["error"]:
                    res["error"] = ("server error: " + json.dumps(obj["error"]))[:200]
                if obj.get("usage"):
                    res["prompt_tokens"] = obj["usage"].get("prompt_tokens")
                for ch in obj.get("choices") or []:
                    if ch.get("finish_reason"):
                        res["finish"] = ch["finish_reason"]
                    d = ch.get("delta") or {}
                    if d.get("content") or d.get("reasoning_content") or d.get("reasoning"):
                        res["chunks"] += 1
                        if res["ttft"] is None:
                            res["ttft"] = time.time() - t0
    except Exception as e:  # noqa: BLE001 - report any failure in the table
        res["error"] = f"{type(e).__name__}: {e}"[:200]
    if not res["error"] and res["chunks"] == 0:
        res["error"] = f"no content returned (stream ended empty, finish={res['finish']})"
    res["total"] = time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", type=int, choices=sorted(STAGES), required=True)
    ap.add_argument("--flash", default="http://127.0.0.1:11234")
    ap.add_argument("--gemma", default="http://127.0.0.1:11235")
    ap.add_argument("--ctx", type=int, default=196608, help="Flash's configured --ctx-size")
    ap.add_argument("--interval", type=float, default=10.0)
    ap.add_argument("--scale", type=float, default=1.0, help="shrink the prompts (dry run of the script)")
    ap.add_argument("--yes", action="store_true", help="skip the confirmation prompt")
    a = ap.parse_args()

    plan = [(n, s, int(t * a.scale)) for n, s, t in STAGES[a.stage]]
    for n, s, t in plan:
        cap = a.ctx if s == "flash" else 32768
        if t + MAX_OUT + 64 > cap:
            sys.exit(f"ERROR: {n} wants {t} tokens, over the {s} context of {cap}")
    bases = {"flash": a.flash, "gemma": a.gemma}
    for s in {s for _, s, _ in plan}:
        r = gauge(bases[s], "requests_running")
        if r is None:
            sys.exit(f"ERROR: cannot read {bases[s]}/metrics.json")
        if r != 0:
            sys.exit(f"ERROR: {s} has requests_running={r}; wait until it is idle")

    print(f"Stage {a.stage}: " + ", ".join(f"{n} = ~{t:,} tokens on {s}" for n, s, t in plan))
    print("This reads the prompts at about 2,400 tok/s per request when alone; two at once will be slower. Expect minutes.")
    if not a.yes:
        input("Enter to start, Ctrl-C to cancel: ")

    models = {s: model_id(bases[s]) for s in {s for _, s, _ in plan}}
    print("calibrating token counts ...", flush=True)
    ratio = {s: calibrate(bases[s], models[s]) for s in models}
    log = open(os.path.expanduser(f"~/ctx2-test-{time.strftime('%Y%m%d-%H%M%S')}.jsonl"), "w")
    abort = threading.Event()
    sampler = Sampler(a.flash, a.gemma, a.interval, log, abort)
    sampler.start()
    out, threads = {}, []
    t_start = time.time()
    seed0 = int(t_start) % 100000000 * 10   # fresh text every run: a fixed seed let later stages reuse an earlier stage's cached prefix
    for i, (n, s, t) in enumerate(plan):
        nwords = max(int(t / ratio[s]), 10)
        th = threading.Thread(target=one_request, args=(n, bases[s], models[s], nwords, seed0 + i, out, abort))
        threads.append(th)
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    wall = time.time() - t_start
    print(f"requests finished after {wall:.0f} s; sampling 60 s of settle time ...", flush=True)
    time.sleep(min(60, 6 * a.interval))
    sampler.stop.set(); sampler.join()
    sampler.samples.append(sample(a.flash, a.gemma))
    log.write(json.dumps({"results": out, "plan": plan, "wall": wall, "seed0": seed0}) + "\n"); log.close()

    print("\n=== requests ===")
    print(f"{'req':<4}{'server':<7}{'target':>9}{'actual':>9}{'TTFT s':>8}{'total s':>9}{'chunks':>8}{'tok/s':>7}  error")
    for n, s, t in plan:
        r = out[n]
        dec = (r["chunks"] / (r["total"] - r["ttft"])) if r["ttft"] and r["total"] > r["ttft"] else 0
        print(f"{n:<4}{s:<7}{t:>9,}{(r['prompt_tokens'] or 0):>9,}{(r['ttft'] or 0):>8.1f}{r['total']:>9.1f}{r['chunks']:>8}{dec:>7.1f}  {r['error'] or ''}")

    S = sampler.samples
    def col(k):
        return [x[k] for x in S if x.get(k) is not None]
    b, last = sampler.base, S[-1]
    print("\n=== memory (baseline = before the requests) ===")
    def d(k):
        return None if b.get(k) is None or not col(k) else max(col(k)) - b[k]
    swap_d = d("swap_mb")
    print(f"swap used:   baseline {b.get('swap_mb')} MB, peak {max(col('swap_mb') or [0])} MB, growth {swap_d} MB, end {last.get('swap_mb')} MB")
    print(f"Pageouts:    +{(last.get('pageouts') or 0) - (b.get('pageouts') or 0)}   Swapouts: +{(last.get('swapouts') or 0) - (b.get('swapouts') or 0)}")
    print(f"wired:       baseline {b.get('wired_gb')} GB, peak {max(col('wired_gb') or [0])} GB")
    print(f"compressor:  baseline {b.get('compressor_gb')} GB, peak {max(col('compressor_gb') or [0])} GB")
    print(f"free:        baseline {b.get('free_pct')}%, lowest {min(col('free_pct') or [0])}%, end {last.get('free_pct')}%")
    print(f"pressure:    highest level {max(col('level') or [0])} (1 normal, 2 warn, 4 critical)")
    print(f"Flash:       memory_mb peak {max(col('flash_mem_mb') or [0])}, most requests running at once {max(col('flash_running') or [0])}")
    if any(s == "gemma" for _, s, _ in plan):
        print(f"Gemma:       most requests running at once {max(col('gemma_running') or [0])}")

    print("\n=== verdict ===")
    errs = [n for n, _, _ in plan if out[n]["error"]]
    print("requests:    " + ("FAIL, errors or empty answers on " + ", ".join(errs) if errs else "PASS, all returned an answer"))
    if swap_d is None:
        print("swap:        UNKNOWN (no readings)")
    else:
        print("swap:        " + ("PASS" if swap_d <= SWAP_PASS_MB else "WARN" if swap_d <= SWAP_WARN_MB else "FAIL") + f" (growth {swap_d:.0f} MB; PASS <= {SWAP_PASS_MB:.0f}, WARN <= {SWAP_WARN_MB:.0f})")
    lv = max(col("level") or [0])
    print("pressure:    " + ("PASS" if lv <= 1 else "WARN" if lv == 2 else "FAIL") + f" (highest level {lv})")
    flash_n = sum(1 for _, s, _ in plan if s == "flash")
    if flash_n > 1:
        mr = max(col("flash_running") or [0])
        print("concurrency: " + (f"PASS, {mr} Flash requests ran at once" if mr >= 2 else f"NOTE, only {mr} ran at once: the second was queued or never overlapped"))
    print(f"log: {log.name}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())

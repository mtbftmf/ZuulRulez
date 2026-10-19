#!/usr/bin/env python3
"""llm-probe.py - behavior probes for an OpenAI-compatible local server (LM Studio).

Complements llm-bench.py (raw speed, memory, combined load). This script checks
what the server and template actually do: effort steering, usable context per
request, and prefix caching. Per request it records TTFT, prefill tok/s, decode
tok/s, reasoning vs answer tokens, total time and finish reason, and appends to a
CSV so runs can be compared by --label.

Stdlib only. Python 3.9+.

Suites
  quick   code / prose / reasoning prompts at the template's default effort
  effort  one reasoning prompt at [effort:low], default (medium), [effort:xhigh];
          --effort-prompt swaps in your own prompt
  ctx     needle-in-haystack at 8K-30K tokens -> shows the context each request really gets
  cache   same long prompt twice -> shows whether prefix caching works
  all     everything above

Examples
  llm-probe.py --suite ctx --label par4
  llm-probe.py --suite effort --runs 2 --label medium --effort-prompt "your prompt"
  llm-probe.py --suite cache
  llm-probe.py --summary llm-probe-history.csv     (median per label/test)

Results append to llm-probe-history.csv in the current folder (git-ignored).
"""
import argparse
import csv
import json
import os
import random
import statistics
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime

PROMPTS = {
    "code": "Write a Python function that merges overlapping intervals in a list of "
            "[start, end] pairs. Include a short docstring and two test cases.",
    "prose": "Explain in two short paragraphs why the sky looks red at sunset.",
    "reason": "A train leaves at 09:40, travels 210 km at 84 km/h, stops for 12 minutes, "
              "then travels 95 km at 76 km/h. At what time does it arrive? "
              "Give the final time on the last line.",
}

EFFORT_MARKERS = {"low": "[effort:low]", "default": "", "xhigh": "[effort:xhigh]"}

CSV_FIELDS = ["timestamp", "label", "suite", "test", "run", "prompt_tokens",
              "completion_tokens", "reasoning_tokens", "answer_tokens", "ttft_s",
              "prefill_tps", "decode_tps", "total_s", "finish", "pass", "error"]


# --------------------------------------------------------------------------- HTTP

def list_models(base_url, timeout=10):
    try:
        with urllib.request.urlopen(base_url + "/models", timeout=timeout) as r:
            return [m.get("id") for m in json.load(r).get("data", [])]
    except Exception as e:  # noqa: BLE001
        sys.exit(f"Cannot reach {base_url}/models: {e}\nIs the LM Studio server running?")


def stream_chat(base_url, model, messages, max_tokens, seed, timeout):
    """Send one streaming request; return timing + token counts."""
    body = {"model": model, "messages": messages, "stream": True,
            "max_tokens": max_tokens, "stream_options": {"include_usage": True}}
    if seed is not None:
        body["seed"] = seed
    req = urllib.request.Request(base_url + "/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})

    t0 = time.perf_counter()
    t_first = t_last = None
    n_reason = n_answer = 0          # streamed chunks (~1 token each in llama.cpp)
    in_think = False                 # fallback for <think> inline in content
    answer, usage, finish, err = [], None, None, None

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                except json.JSONDecodeError:
                    continue
                if chunk.get("error"):
                    err = str(chunk["error"])[:300]
                if chunk.get("usage"):
                    usage = chunk["usage"]
                for ch in chunk.get("choices") or []:
                    d = ch.get("delta") or {}
                    r = d.get("reasoning_content") or d.get("reasoning")
                    c = d.get("content")
                    now = time.perf_counter()
                    if r or c:
                        t_first = t_first or now
                        t_last = now
                    if r:
                        n_reason += 1
                    if c:
                        if "<think>" in c:
                            in_think = True
                        if in_think:
                            n_reason += 1
                        else:
                            n_answer += 1
                            answer.append(c)
                        if "</think>" in c:
                            in_think = False
                    if ch.get("finish_reason"):
                        finish = ch["finish_reason"]
    except urllib.error.HTTPError as e:
        err = f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}"
    except Exception as e:  # noqa: BLE001
        err = repr(e)[:300]

    t_end = time.perf_counter()
    usage = usage or {}
    prompt_tok = usage.get("prompt_tokens")
    comp_tok = usage.get("completion_tokens") or (n_reason + n_answer) or None
    details = usage.get("completion_tokens_details") or {}
    reason_tok = details.get("reasoning_tokens")
    if reason_tok is None and comp_tok and (n_reason + n_answer):
        reason_tok = round(comp_tok * n_reason / (n_reason + n_answer))
    answer_tok = (comp_tok - reason_tok) if comp_tok is not None and reason_tok is not None else None

    ttft = (t_first - t0) if t_first else None
    gen_span = (t_last - t_first) if t_first and t_last else None
    return {
        "prompt_tokens": prompt_tok,
        "completion_tokens": comp_tok,
        "reasoning_tokens": reason_tok,
        "answer_tokens": answer_tok,
        "ttft_s": ttft,
        "prefill_tps": (prompt_tok / ttft) if prompt_tok and ttft else None,
        "decode_tps": ((comp_tok - 1) / gen_span) if comp_tok and comp_tok > 1 and gen_span else None,
        "total_s": t_end - t0,
        "finish": finish,
        "answer": "".join(answer),
        "error": err,
    }


# --------------------------------------------------------------------------- prompts

def system_msg(marker, nonce):
    # Nonce first so every run misses the prefix cache (fair prefill numbers).
    # The effort marker can sit anywhere in the first system message.
    parts = [f"[run {nonce}]" if nonce else "", "You are a helpful assistant.", marker]
    return {"role": "system", "content": " ".join(p for p in parts if p)}


def haystack(n_tokens, rng):
    """~n_tokens of filler. This filler tokenizes at ~2.7 chars/token on Qwen
    (measured: 12000 target -> 17793 real at 4 chars/token); usage reports the real count."""
    colors = ["red", "blue", "green", "amber", "grey", "violet"]
    lines, chars, i = [], 0, 0
    while chars < n_tokens * 2.7:
        s = (f"Log entry {i}: the {rng.choice(colors)} valve on line {i % 37} read "
             f"{rng.randint(100, 999)} units during shift {i % 3 + 1}.")
        lines.append(s)
        chars += len(s) + 1
        i += 1
    return "\n".join(lines)


# --------------------------------------------------------------------------- suites

def build_tests(args):
    """Yield (suite, test, messages, check_fn) tuples."""
    rng = random.Random(args.seed or 0)
    tests = []
    suites = ["quick", "effort", "ctx", "cache"] if args.suite == "all" else [args.suite]

    for suite in suites:
        if suite == "quick":
            for name, prompt in PROMPTS.items():
                for run in range(args.runs):
                    nonce = uuid.uuid4().hex[:8]
                    tests.append((suite, name, run,
                                  [system_msg("", nonce), {"role": "user", "content": prompt}], None))
        elif suite == "effort":
            for eff, marker in EFFORT_MARKERS.items():
                for run in range(args.runs):
                    nonce = uuid.uuid4().hex[:8]
                    tests.append((suite, f"reason@{eff}", run,
                                  [system_msg(marker, nonce), {"role": "user", "content": args.effort_prompt or PROMPTS["reason"]}],
                                  None))
        elif suite == "ctx":
            for size in args.ctx_sizes:
                code = str(rng.randint(100000, 999999))
                doc = (f"IMPORTANT: the access code for this document is {code}.\n\n"
                       + haystack(size, rng))
                q = ("What is the access code stated at the very beginning of this document? "
                     "Answer with the number only.")
                nonce = uuid.uuid4().hex[:8]
                tests.append((suite, f"needle@{size}", 0,
                              [system_msg("[effort:low]", nonce),
                               {"role": "user", "content": doc + "\n\n" + q}],
                              (lambda ans, c=code: c in ans)))
        elif suite == "cache":
            doc = haystack(args.cache_size, rng)
            nonce = uuid.uuid4().hex[:8]   # same nonce for both -> second request can reuse prefix
            msgs = [system_msg("[effort:low]", nonce),
                    {"role": "user", "content": doc + "\n\nHow many distinct colors appear? One word."}]
            tests.append((suite, "cold", 0, msgs, None))
            tests.append((suite, "warm", 0, msgs, None))
    return tests


# --------------------------------------------------------------------------- output

def fmt(v, nd=1):
    if v is None:
        return "-"
    return f"{v:.{nd}f}" if isinstance(v, float) else str(v)


def print_row(r):
    print(f"{r['suite']:<7} {r['test']:<16} {r['run']:>3} "
          f"{fmt(r['prompt_tokens']):>7} {fmt(r['reasoning_tokens']):>7} {fmt(r['answer_tokens']):>6} "
          f"{fmt(r['ttft_s'], 2):>7} {fmt(r['prefill_tps'], 0):>8} {fmt(r['decode_tps'], 1):>7} "
          f"{fmt(r['total_s'], 1):>7} {fmt(r['finish']):>7} {fmt(r['pass']):>5}"
          + (f"  ERR {r['error']}" if r["error"] else ""), flush=True)


HEADER = (f"{'suite':<7} {'test':<16} {'run':>3} {'prompt':>7} {'reason':>7} {'answer':>6} "
          f"{'ttft_s':>7} {'pre_t/s':>8} {'dec_t/s':>7} {'total_s':>7} {'finish':>7} {'pass':>5}")


def summarize(path):
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    groups = {}
    for r in rows:
        groups.setdefault((r["label"], r["suite"], r["test"]), []).append(r)
    print(f"{'label':<14} {'suite':<7} {'test':<16} {'n':>3} {'reason':>7} "
          f"{'ttft_s':>7} {'pre_t/s':>8} {'dec_t/s':>7} {'total_s':>7}")

    def med(rs, k):
        vals = [float(x[k]) for x in rs if x[k] not in ("", "None")]
        return statistics.median(vals) if vals else None

    for (label, suite, test), rs in sorted(groups.items()):
        print(f"{label:<14} {suite:<7} {test:<16} {len(rs):>3} {fmt(med(rs, 'reasoning_tokens'), 0):>7} "
              f"{fmt(med(rs, 'ttft_s'), 2):>7} {fmt(med(rs, 'prefill_tps'), 0):>8} "
              f"{fmt(med(rs, 'decode_tps'), 1):>7} {fmt(med(rs, 'total_s'), 1):>7}")


def interpret(results):
    ctx = [r for r in results if r["suite"] == "ctx"]
    if ctx:
        ok = [r for r in ctx if r["pass"]]
        bad = [r for r in ctx if not r["pass"]]
        print("\nContext probe:")
        if not bad:
            biggest = max((r["prompt_tokens"] or 0) for r in ok)
            print(f"  All sizes passed (largest ~{biggest} prompt tokens). "
                  "Each request can use at least that much context.")
        else:
            lim_ok = max(((r["prompt_tokens"] or 0) for r in ok), default=0)
            print(f"  Failed from {bad[0]['test']}. Largest passing prompt ~{lim_ok} tokens.")
            print("  If failures start near context_length / parallel, slots are split, not unified.")
            for r in bad:
                why = r["error"] or f"answer={r['answer'][:60]!r} finish={r['finish']}"
                print(f"    {r['test']}: {why}")
    cache = {r["test"]: r for r in results if r["suite"] == "cache"}
    if "cold" in cache and "warm" in cache and cache["cold"]["ttft_s"] and cache["warm"]["ttft_s"]:
        ratio = cache["warm"]["ttft_s"] / cache["cold"]["ttft_s"]
        print(f"\nPrefix cache: warm TTFT is {ratio:.0%} of cold "
              f"({cache['cold']['ttft_s']:.2f}s -> {cache['warm']['ttft_s']:.2f}s). "
              + ("Caching works." if ratio < 0.3 else "Little or no reuse - check cache_prompt / slot reuse."))


# --------------------------------------------------------------------------- main

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default="http://localhost:1234/v1")
    p.add_argument("--model", default="flash-next", help="model identifier as shown by `lms ps`")
    p.add_argument("--suite", default="quick", choices=["quick", "effort", "ctx", "cache", "all"])
    p.add_argument("--runs", type=int, default=3, help="repeats per test (quick/effort)")
    p.add_argument("--label", default="baseline", help="tag rows for A/B, e.g. fa-on, par1")
    p.add_argument("--csv", default="llm-probe-history.csv")
    p.add_argument("--max-tokens", type=int, default=8192)
    p.add_argument("--ctx-sizes", default="8000,16000,24000,30000",
                   type=lambda s: [int(x) for x in s.split(",")])
    p.add_argument("--cache-size", type=int, default=8000)
    p.add_argument("--effort-prompt", default=None,
                   help="custom prompt for the effort suite (default: the built-in train problem)")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--timeout", type=float, default=900)
    p.add_argument("--summary", metavar="CSV", help="print medians per label/test from a CSV and exit")
    args = p.parse_args()

    if args.summary:
        summarize(args.summary)
        return

    models = list_models(args.url)
    if args.model not in models:
        print(f"warning: '{args.model}' not in /models ({', '.join(models)})", file=sys.stderr)

    tests = build_tests(args)
    print(f"{len(tests)} requests -> {args.url} model={args.model} label={args.label}\n")
    print(HEADER)

    new_file = not os.path.exists(args.csv)
    results = []
    with open(args.csv, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CSV_FIELDS, extrasaction="ignore")
        if new_file:
            w.writeheader()
        for suite, test, run, msgs, check in tests:
            r = stream_chat(args.url, args.model, msgs, args.max_tokens, args.seed, args.timeout)
            r.update(suite=suite, test=test, run=run, label=args.label,
                     timestamp=datetime.now().isoformat(timespec="seconds"),
                     **{"pass": (check(r["answer"]) if check and not r["error"] else
                                 (False if check else None))})
            print_row(r)
            w.writerow({k: (round(v, 3) if isinstance(v, float) else v) for k, v in r.items()})
            f.flush()
            results.append(r)

    interpret(results)
    print(f"\nAppended {len(results)} rows to {args.csv}. Compare runs with: "
          f"{os.path.basename(sys.argv[0])} --summary {args.csv}")


if __name__ == "__main__":
    main()

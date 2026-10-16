#!/usr/bin/env python3
"""
llm-mem.py — what each loaded model is using in RAM, and what that memory is made of.

  python3 ~/bin/llm-mem.py              # live view (may need: sudo python3 ~/bin/llm-mem.py)
  python3 ~/bin/llm-mem.py --ctx 32768  # context length used for the KV-cache estimate

Live part (macOS vmmap): for every LM Studio / llama.cpp process, the GGUF files it has mapped and
how much of each is resident in RAM, plus GPU buffers (Metal/IOAccelerator: KV cache, compute
scratch). Static part (GGUF headers, no weights read): each model's weight bytes by component
(experts, attention, embeddings ...) and a KV-cache estimate for the given context.
Python 3 stdlib only.
"""
import argparse, glob, os, re, struct, subprocess, sys
from collections import defaultdict

# ---------------- GGUF header reading ----------------
SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
FMT = {0: "B", 1: "b", 2: "H", 3: "h", 4: "I", 5: "i", 6: "f", 7: "?", 10: "Q", 11: "q", 12: "d"}


def _rd(f, fmt):
    n = struct.calcsize(fmt)
    b = f.read(n)
    if len(b) != n:
        raise EOFError
    return struct.unpack("<" + fmt, b)[0]


def _val(f, t):
    if t == 8:
        return f.read(_rd(f, "Q")).decode("utf-8", "replace")
    if t == 9:
        it, n = _rd(f, "I"), _rd(f, "Q")
        if it == 8 or n <= 4096:
            return [_val(f, it) for _ in range(n)]
        f.seek(SIZES[it] * n, 1)          # big numeric arrays (token scores etc.): skip
        return None
    return _rd(f, FMT[t])


def read_header(path):
    """Return (metadata dict, [(name, offset)], data_start, file_size)."""
    with open(path, "rb") as f:
        if f.read(4) != b"GGUF":
            raise ValueError("not GGUF")
        _rd(f, "I")
        n_t, n_kv = _rd(f, "Q"), _rd(f, "Q")
        meta = {}
        for _ in range(n_kv):
            k = f.read(_rd(f, "Q")).decode("utf-8", "replace")
            t = _rd(f, "I")
            v = _val(f, t)
            if k != "tokenizer.chat_template":
                meta[k] = v
        tensors = []
        for _ in range(n_t):
            name = f.read(_rd(f, "Q")).decode("utf-8", "replace")
            nd = _rd(f, "I")
            f.seek(8 * nd + 4, 1)
            tensors.append((name, _rd(f, "Q")))
        align = meta.get("general.alignment", 32) or 32
        pos = f.tell()
        data_start = pos + (-pos % align)
        size = os.fstat(f.fileno()).st_size
    return meta, tensors, data_start, size


def shards_of(path):
    m = re.match(r"(.*)-\d{5}-of-(\d{5})\.gguf$", path)
    if not m:
        return [path]
    found = sorted(glob.glob(f"{m.group(1)}-?????-of-{m.group(2)}.gguf"))
    return found or [path]


CATS = [
    ("experts (MoE FFN)",       r"_exps|\.experts?\."),
    ("shared-expert FFN",       r"_shexp|shared_expert"),
    ("dense FFN",               r"\.ffn_(up|down|gate)(\.|$)|ffn_gate_up"),
    ("router / gates",          r"ffn_gate_inp|\.router"),
    ("attention",               r"\.attn_(q|k|v|qkv|output|o)\b|attn_q|attn_k|attn_v|attn_output|attn_qkv"),
    ("linear-attn / SSM",       r"ssm_|\.linear_attn|delta|conv1d|time_mix|\.a_log|dt_bias"),
    ("per-layer token embeddings (sparse lookup)", r"per_layer_token_embd|per_layer_(model|input)"),
    ("token embeddings",        r"^token_embd"),
    ("output head",             r"^output\.|^lm_head"),
    ("MTP / n-gram / draft",    r"mtp|ngram|nextn|draft"),
    ("norms",                   r"norm"),
]


def categorize(name):
    for label, rx in CATS:
        if re.search(rx, name):
            return label
    parts = name.split(".")
    if parts[0] == "blk" and len(parts) > 2:
        return "other: " + parts[2]
    return "other: " + parts[0]


def model_breakdown(first_shard):
    """Bytes per component (exact, from tensor offsets) and per shard; metadata of shard 1."""
    cats, per_shard, meta0 = defaultdict(int), {}, None
    for sp in shards_of(first_shard):
        meta, tensors, data_start, size = read_header(sp)
        meta0 = meta0 or meta
        ordered = sorted(tensors, key=lambda x: x[1])
        data_len = size - data_start
        shard_cats = defaultdict(int)
        for i, (name, off) in enumerate(ordered):
            end = ordered[i + 1][1] if i + 1 < len(ordered) else data_len
            c = categorize(name)
            cats[c] += end - off
            shard_cats[c] += end - off
        per_shard[sp] = (size, dict(shard_cats))
    return cats, per_shard, meta0


def kv_estimate(meta, ctx):
    arch = meta.get("general.architecture", "")
    g = lambda k: meta.get(f"{arch}.{k}")
    layers = g("block_count")
    if not layers:
        return None, "no block_count"
    kvh = g("attention.head_count_kv") or g("attention.head_count") or 0
    heads = kvh if isinstance(kvh, list) else [kvh] * layers
    hd = g("embedding_length") and g("attention.head_count") and not isinstance(g("attention.head_count"), list) \
        and g("embedding_length") // g("attention.head_count")
    kl = g("attention.key_length") or hd or 128
    vl = g("attention.value_length") or hd or 128
    if g("attention.kv_lora_rank"):          # MLA-style compressed cache
        per_tok = layers * ((g("attention.kv_lora_rank") or 0) + (g("rope.dimension_count") or 64)) * 2
        return per_tok * ctx, "MLA compressed cache"
    # Which layers keep a full-length cache?
    span = [ctx] * layers
    note = "f16 K/V, full context"
    interval = next((v for k, v in meta.items() if k.endswith("full_attention_interval") and isinstance(v, int)), None)
    window = g("attention.sliding_window")
    if interval and not isinstance(kvh, list):
        span = [ctx if (i + 1) % interval == 0 else 0 for i in range(layers)]
        note = f"hybrid: full attention every {interval} layers; linear-attention state not included"
    elif isinstance(window, int) and 0 < window < ctx:
        pat = g("attention.sliding_window_pattern")
        if isinstance(pat, list) and len(pat) == layers:
            local = [bool(x) for x in pat]
            note = f"sliding window {window} on {sum(local)} of {layers} layers"
        else:
            local = [(i + 1) % 6 != 0 for i in range(layers)]
            note = f"sliding window {window} assumed on 5 of 6 layers (approx.)"
        span = [window if loc else ctx for loc in local]
    total = sum((h or 0) * (kl + vl) * 2 * n for h, n in zip(heads, span))
    return total, note


# ---------------- live view (macOS) ----------------
UNIT = {"": 1, "B": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}


def to_bytes(s):
    m = re.match(r"^([\d.]+)([KMGTB]?)$", s.strip())
    return int(float(m.group(1)) * UNIT[m.group(2)]) if m else 0


def llm_pids():
    out = subprocess.run(["ps", "-axo", "pid=,rss=,command="], capture_output=True, text=True).stdout
    pids = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3:
            continue
        pid, rss, cmd = parts
        if re.search(r"lm ?studio|lmstudio|llama-server|llmworker|mlx", cmd, re.I) and "llm-mem.py" not in cmd:
            pids.append((int(pid), int(rss) * 1024, cmd))
    return pids


def scan_process(pid):
    """Resident bytes per mapped .gguf file, and resident GPU (IOAccelerator) bytes."""
    r = subprocess.run(["vmmap", "-w", str(pid)], capture_output=True, text=True)
    if r.returncode != 0:
        return None, None, (r.stderr.strip().splitlines() or ["vmmap failed"])[-1]
    files, gpu = defaultdict(int), 0
    # Working memory = everything the process has written itself (not file-backed): KV cache, compute
    # buffers, recurrent state, runtime. That is the DIRTY + SWAPPED columns of vmmap's TOTAL line.
    sm = subprocess.run(["vmmap", "-summary", str(pid)], capture_output=True, text=True).stdout
    for line in sm.splitlines():
        if line.startswith("TOTAL"):
            cols = line.split()
            if len(cols) >= 5:
                gpu = to_bytes(cols[3]) + to_bytes(cols[4])
    for line in r.stdout.splitlines():
        m = re.search(r"\[\s*(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*\]", line)
        if not m:
            continue
        resident = to_bytes(m.group(2))
        g = re.search(r"SM=\S+\s+(?:PURGE=\S+\s+)?(/.*\.gguf)\s*$", line) or re.search(r"\s(/[^\s]+\.gguf)\s*$", line)
        if g:
            files[g.group(1)] += resident
    return files, gpu, None


def gb(n):
    return f"{n / (1 << 30):6.2f} GB"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ctx", type=int, default=32768, help="context length for the KV estimate (default 32768)")
    ap.add_argument("gguf", nargs="*", help="model files to break down (default: whatever is mapped by running processes)")
    a = ap.parse_args()

    models = defaultdict(dict)   # first-shard path -> {shard path: resident}
    gpu_by_pid = {}
    if sys.platform == "darwin" and not a.gguf:
        procs = llm_pids()
        if not procs:
            print("No LM Studio / llama.cpp processes found.")
        for pid, rss, cmd in procs:
            files, gpu, err = scan_process(pid)
            if err:
                if "gguf" in cmd.lower() or "lm studio" in cmd.lower():
                    print(f"pid {pid}: {err}  (try: sudo python3 {sys.argv[0]})")
                continue
            if not files and not gpu:
                continue
            gpu_by_pid[pid] = (gpu, rss, cmd, files)
            for path, res in files.items():
                models[shards_of(path)[0]][path] = res

        if gpu_by_pid:
            print("== Live memory by process ==")
            for pid, (gpu, rss, cmd, files) in gpu_by_pid.items():
                name = os.path.basename(cmd.split()[0])[:40]
                wres = sum(files.values())
                if wres < (64 << 20) and gpu < (64 << 20):
                    continue
                print(f"pid {pid:<7} {name:<40}  weights in RAM {gb(wres)}   working memory {gb(gpu)}")
            print("   working memory = memory the engine allocated itself: KV cache, compute buffers, recurrent state, runtime")
            print("   (all parallel slots). With mmap off, copied weights would also land here.\n")
    for p in a.gguf:
        models[shards_of(os.path.abspath(p))[0]].setdefault(os.path.abspath(p), None)

    if not models:
        print("Nothing to break down. Pass a .gguf path, or run with the models loaded (sudo if vmmap is refused).")
        return

    for first, resident_map in models.items():
        cats, per_shard, meta = model_breakdown(first)
        gname = meta.get("general.name") or ""
        name = os.path.basename(os.path.dirname(first)) + (f"  (general.name: {gname})" if gname else "")
        total = sum(cats.values())
        live = sum(v for v in resident_map.values() if v)
        print(f"== {name} ==")
        print(f"   {os.path.dirname(first)}")
        print(f"   arch {meta.get('general.architecture')}, {len(per_shard)} file(s), weights {gb(total).strip()} on disk"
              + (f", {gb(live).strip()} resident now ({100 * live / total:.0f}%)" if live else ""))
        print("   Weights by component:")
        for c, b in sorted(cats.items(), key=lambda x: -x[1]):
            print(f"     {c:<26} {gb(b)}  {100 * b / total:5.1f}%")
        kv, note = kv_estimate(meta, a.ctx)
        if kv:
            print(f"   KV cache estimate @ {a.ctx:,} ctx: {gb(kv).strip()}  ({note})")
        if any(resident_map.values()):
            cold = [(p, per_shard[p][0], r or 0) for p, r in resident_map.items() if p in per_shard]
            cold += [(p, s[0], 0) for p, s in per_shard.items() if p not in resident_map]
            lows = [(p, s, r) for p, s, r in cold if s > (64 << 20) and r < 0.5 * s]
            if lows:
                print("   Mostly NOT in RAM (served from SSD via mmap):")
                for p, s, r in sorted(lows):
                    top = max(per_shard[p][1].items(), key=lambda x: x[1])[0] if per_shard[p][1] else "?"
                    print(f"     {os.path.basename(p):<60} {gb(r).strip()} of {gb(s).strip()}  (mostly {top})")
        print()


if __name__ == "__main__":
    main()

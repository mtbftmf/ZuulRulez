#!/usr/bin/env python3
"""gguf-template.py — print the chat template (tokenizer.chat_template) embedded in a GGUF file.
Usage: python3 gguf-template.py <file.gguf> [output.jinja]
Reads only the metadata header; never loads the weights. Python 3 stdlib only."""
import struct
import sys

SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}


def read(f, fmt):
    n = struct.calcsize(fmt)
    data = f.read(n)
    if len(data) != n:
        raise EOFError("unexpected end of header")
    return struct.unpack("<" + fmt, data)[0]


def read_str(f):
    return f.read(read(f, "Q")).decode("utf-8", "replace")


def skip_value(f, t):
    if t == 8:
        f.seek(read(f, "Q"), 1)
    elif t == 9:
        it, n = read(f, "I"), read(f, "Q")
        if it == 8:
            for _ in range(n):
                f.seek(read(f, "Q"), 1)
        elif it in SIZES:
            f.seek(SIZES[it] * n, 1)
        else:
            for _ in range(n):
                skip_value(f, it)
    elif t in SIZES:
        f.seek(SIZES[t], 1)
    else:
        raise ValueError(f"unknown GGUF value type {t}")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "rb") as f:
        if f.read(4) != b"GGUF":
            sys.exit("not a GGUF file")
        version = read(f, "I")
        read(f, "Q")                     # tensor count
        kv_count = read(f, "Q")
        found = {}
        for _ in range(kv_count):
            key = read_str(f)
            t = read(f, "I")
            if key.startswith("tokenizer.chat_template") and t == 8:
                found[key] = read_str(f)
            else:
                skip_value(f, t)
    if not found:
        sys.exit(f"no chat template in metadata (GGUF v{version}, {kv_count} keys)")
    out = sys.argv[2] if len(sys.argv) > 2 else None
    for key, tmpl in found.items():
        if out:
            with open(out, "w") as w:
                w.write(tmpl)
            print(f"{key}: {len(tmpl)} characters written to {out}")
        else:
            print(f"===== {key} ({len(tmpl)} characters) =====\n{tmpl}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
gguf-set-template.py — write a new tokenizer.chat_template into a GGUF file (or the first shard of a
split model), producing a NEW file. Every other metadata key, the tensor table and all tensor data are
copied unchanged; only the template string and the header padding change. Python 3 stdlib only.

Usage:
  python3 gguf-set-template.py <in.gguf> <template.jinja> <out.gguf>

Then swap files yourself (see the handoff doc); the original is never modified.
"""
import os
import shutil
import struct
import sys

SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
KEY = "tokenizer.chat_template"


class Reader:
    def __init__(self, f):
        self.f = f

    def raw(self, n):
        b = self.f.read(n)
        if len(b) != n:
            raise EOFError("unexpected end of file in header")
        return b

    def u(self, fmt):
        return struct.unpack("<" + fmt, self.raw(struct.calcsize(fmt)))[0]

    def string(self):
        n = self.u("Q")
        return self.raw(n)

    def value_raw(self, t):
        """Return the raw bytes of a value of type t (without the type field)."""
        if t == 8:
            n = self.u("Q")
            return struct.pack("<Q", n) + self.raw(n)
        if t == 9:
            it, n = self.u("I"), self.u("Q")
            out = [struct.pack("<IQ", it, n)]
            for _ in range(n):
                out.append(self.value_raw(it))
            return b"".join(out)
        if t in SIZES:
            return self.raw(SIZES[t])
        raise ValueError(f"unknown GGUF value type {t}")


def gstr(b: bytes) -> bytes:
    return struct.pack("<Q", len(b)) + b


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, tmpl_path, dst = sys.argv[1:]
    if os.path.abspath(src) == os.path.abspath(dst):
        sys.exit("output must be a different file from the input")
    template = open(tmpl_path, "rb").read()
    if b"messages" not in template:
        sys.exit("template does not reference 'messages' — refusing")

    with open(src, "rb") as f:
        r = Reader(f)
        if r.raw(4) != b"GGUF":
            sys.exit("not a GGUF file")
        version = r.u("I")
        if version < 2:
            sys.exit(f"GGUF v{version} not supported")
        n_tensors, n_kv = r.u("Q"), r.u("Q")

        kvs, alignment, replaced = [], 32, False
        for _ in range(n_kv):
            key = r.string()
            t = r.u("I")
            val = r.value_raw(t)
            k = key.decode("utf-8", "replace")
            if k == "general.alignment" and t == 4:
                alignment = struct.unpack("<I", val)[0]
            if k == KEY:
                if t != 8:
                    sys.exit(f"{KEY} has unexpected type {t}")
                val = gstr(template)
                replaced = True
            kvs.append(gstr(key) + struct.pack("<I", t) + val)
        if not replaced:
            sys.exit(f"no {KEY} in this file — use the first shard of a split model")

        tensors = []
        for _ in range(n_tensors):
            name = r.string()
            nd = r.u("I")
            dims = r.raw(8 * nd)
            ttype, offset = r.u("I"), r.u("Q")
            tensors.append(gstr(name) + struct.pack("<I", nd) + dims + struct.pack("<IQ", ttype, offset))

        old_header_end = f.tell()
        old_data_start = old_header_end + (-old_header_end % alignment)
        total = os.fstat(f.fileno()).st_size

        header = b"GGUF" + struct.pack("<IQQ", version, n_tensors, n_kv) + b"".join(kvs) + b"".join(tensors)
        header += b"\0" * (-len(header) % alignment)

        f.seek(old_data_start)
        with open(dst + ".partial", "wb") as w:
            w.write(header)
            shutil.copyfileobj(f, w, 64 * 1024 * 1024)
        os.replace(dst + ".partial", dst)

    data_len = total - old_data_start
    new_size = os.path.getsize(dst)
    if new_size != len(header) + data_len:
        sys.exit("size check failed — do not use the output")
    print(f"ok: {n_kv} keys, {n_tensors} tensors, alignment {alignment}")
    print(f"template: {len(template)} bytes; tensor data copied: {data_len} bytes")
    print(f"wrote {dst} ({new_size} bytes; input was {total})")


if __name__ == "__main__":
    main()

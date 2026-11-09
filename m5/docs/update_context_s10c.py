#!/usr/bin/env python3
"""update_context_s10c.py — single edit: insert (combined SoC package) into ¶4.

Pending #8: CONTEXT.md ¶4 must be byte-identical to the handoff canonical string
at the clause level. s10 wrote the sentence without the parenthetical; this script
adds it.

Verification after running:
    grep -F "through generation (combined SoC package)" m5/docs/CONTEXT.md

Run from ~/ZuulRulez:
    python3 ~/Downloads/update_context_s10c.py
"""
import pathlib, sys

TARGET = pathlib.Path("m5/docs/CONTEXT.md")
src = TARGET.read_text()


def apply(src, old, new, label):
    if new in src:
        print(f"skip {label} — already applied"); return src
    n = src.count(old)
    if n == 0:
        print(f"FAIL {label}: anchor absent — likely hand-applied with different wording")
        sys.exit(1)
    if n > 1:
        print(f"FAIL {label}: {n} matches"); sys.exit(1)
    print(f"ok   {label}"); return src.replace(old, new)


src = apply(src,
    old="through generation, and the highest five-second reading on record is 82.7 W — under a desk",
    new="through generation (combined SoC package), and the highest five-second reading on record is 82.7 W — under a desk",
    label="¶4 combined-SoC placement")

TARGET.write_text(src)
print(f"Done — {TARGET}")
print()
print("Verify:")
print('  grep -F "through generation (combined SoC package)" m5/docs/CONTEXT.md')

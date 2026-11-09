#!/usr/bin/env python3
# m5/docs/update_storage_s11.py — storage throughput + RAID role + macOS 27.2
# Run from ~/ZuulRulez (MacLLM). Idempotent; re-running prints skip for each edit.
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CL, README, PROF = ROOT / "CHANGELOG.md", ROOT / "README.md", ROOT / "m5/docs/M5_MAX_SYSTEM_PROFILE.md"

def apply(src, old, new, label):
    if new in src:
        print(f"skip {label} - already applied"); return src
    n = src.count(old)
    if n == 0:
        print(f"FAIL {label}: anchor absent"); sys.exit(1)
    if n > 1:
        print(f"FAIL {label}: {n} matches"); sys.exit(1)
    print(f"ok   {label}"); return src.replace(old, new)

def remove(src, old, label):
    if old not in src:
        print(f"skip {label} - already removed"); return src
    n = src.count(old)
    if n > 1:
        print(f"FAIL {label}: {n} matches"); sys.exit(1)
    print(f"ok   {label} (removed)"); return src.replace(old, "", 1)

cl = CL.read_text()
top = ("Newest first. Entries before Oct 16, 2026 were reconstructed from chat history.\n"
       "\n## 2026-11-07")
sec = ("Newest first. Entries before Oct 16, 2026 were reconstructed from chat history.\n"
"\n## 2026-11-09\n"
"- 2026-11-09 `docs`: record storage throughput and give the RAID0 a stated role. dd, 20 GB "
"sequential, measured 2026-11-04: internal NVMe 14.0 GB/s read / 4.6 write; TB5 RAID0 10.2 read / "
"7.7 write. Why: the rule lived only in chat once `m5/docs/m5-max-raid-tiering.md` was deleted Nov 3, "
"the Storage row in `m5/docs/M5_MAX_SYSTEM_PROFILE.md` carried no numbers, and a line under Still open "
"said the RAID0 was unused by the stack while it in fact holds the flint GGUF library and write-heavy "
"scratch. Result: the Storage row now carries the figures, the rule (internal is the only volume "
"mlx-serve may mmap from) and the reason - no redundancy, a USB disconnect turns a serving process "
"into a crash rather than a slowdown, and the volume mounts late at boot; the stale open line is "
"removed; the role is GGUF library plus scratch, experiment cache via HF_HUB_CACHE only and never "
"the shared ~/.cache/huggingface/hub. The 4,897 MB/s read and 747 MB/s write in the 2026-10 RAID "
"entry are a different tool and queue depth; the dd figures are what the role rests on.\n"
"- 2026-11-09 `docs`: README stack table macOS 27.0.1 to 27.2, the value both the Studio and the MBP "
"canary have run since the October update. Why: the table predates the update. Result: documentation "
"only, no runtime change.\n"
"\n## 2026-11-07")
cl = apply(cl, top, sec, "CHANGELOG new section")
CL.write_text(cl)

pr = PROF.read_text()
pr = apply(pr,
    "| Storage | Internal drive. Never on the external RAID0 (the 30 GB n-gram table is memory-mapped; the stripe has no redundancy) |",
    "| Storage | Internal drive for anything memory-mapped. dd 20 GB (2026-11-04): internal 14.0 GB/s read / 4.6 write; TB5 RAID0 10.2 read / 7.7 write. The stripe has no redundancy, a USB disconnect turns a serving process into a crash rather than a slowdown, and the volume mounts late at boot. RAID0 earns its keep on writes and holds the flint GGUF library plus write-heavy scratch (conversions, experiment cache via HF_HUB_CACHE); never the shared ~/.cache/huggingface/hub |",
    "profile Storage row")
pr = remove(pr,
    "- External RAID0: unused by the stack since the RAID guard (an LM Studio model folder) was removed Nov 3.\n",
    "profile stale Still-open RAID line")
PROF.write_text(pr)

rd = README.read_text()
rd = apply(rd, "128 GB, 1 TB, macOS 27.0.1 |", "128 GB, 1 TB, macOS 27.2 |", "README macOS version")
README.write_text(rd)
print("done - verify, then stage the three files plus this script")

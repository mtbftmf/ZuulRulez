#!/usr/bin/env python3
"""06-inventory-diff.py — compare two 05-inventory.sh snapshots (for example the M1 and the M5).

    python3 06-inventory-diff.py ~/inventories/inventory-M1-Studio-… ~/inventories/inventory-M5-Studio-…

Writes, into a new folder next to the first snapshot (or --out):
  report.md            summary: system, account, apps, Homebrew, launchd, profiles, home sizes, files
  only-in-A.tsv        files only in the first snapshot (size, mtime, path): what a wipe of A would lose
  only-in-B.tsv        files only in the second snapshot
  changed.tsv          same path in both, different size
A and B are the two hosts, in the order given. Paths are relative to each user's home folder.
Read-only; stdlib only. Never commit the output (personal paths and file names).
"""
import argparse
import csv
import gzip
import os
import sys
import time
from collections import defaultdict


def read_kv(path):
    d = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "\t" in line:
                    k, v = line.rstrip("\n").split("\t", 1)
                    d[k] = v
    return d


def read_lines(path):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as f:
        return [l.rstrip("\n") for l in f if l.strip()]


def read_apps(path):
    apps = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as f:
            for row in csv.DictReader(f, delimiter="\t"):
                key = row["bundle_id"] if row["bundle_id"] not in ("", "?") else row["name"]
                apps[key] = row
    return apps


def read_files(path):
    files = {}
    opener = gzip.open if path.endswith(".gz") else open
    if os.path.exists(path):
        with opener(path, "rt", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t", 2)
                if len(parts) == 3 and parts[0].isdigit():
                    files[parts[2]] = (int(parts[0]), int(parts[1]) if parts[1].isdigit() else 0)
    return files


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def top(path):
    head = path.split("/", 1)[0]
    if head == "Library" and "/" in path:
        return "Library/" + path.split("/", 2)[1]
    return head


def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "| " + " | ".join("---" for _ in headers) + " |"]
    for r in rows:
        out.append("| " + " | ".join(str(c).replace("|", "\\|") for c in r) + " |")
    return "\n".join(out)


def set_diff(title, a, b, A, B, out):
    if a is None or b is None:
        out.append(f"## {title}\n\nMissing from one snapshot.\n")
        return
    sa, sb = set(a), set(b)
    out.append(f"## {title}\n")
    out.append(f"{len(sa)} on {A}, {len(sb)} on {B}, {len(sa & sb)} on both.\n")
    for label, items in ((f"Only on {A}", sorted(sa - sb)), (f"Only on {B}", sorted(sb - sa))):
        out.append(f"**{label}** ({len(items)})\n")
        out.append("\n".join(f"- `{i}`" for i in items) if items else "- none")
        out.append("")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", help="first snapshot folder (A)")
    ap.add_argument("b", help="second snapshot folder (B)")
    ap.add_argument("--out", help="output folder (default: inventory-diff-<A>-vs-<B> beside A)")
    ap.add_argument("--top", type=int, default=40, help="largest files to list per side in the report")
    args = ap.parse_args()

    sysA, sysB = read_kv(os.path.join(args.a, "system.tsv")), read_kv(os.path.join(args.b, "system.tsv"))
    if not sysA or not sysB:
        sys.exit("error: system.tsv missing — are both arguments 05-inventory.sh output folders?")
    A, B = sysA.get("host", "A"), sysB.get("host", "B")
    if A == B:
        A, B = A + " (A)", B + " (B)"
    out_dir = args.out or os.path.join(os.path.dirname(os.path.abspath(args.a)), f"inventory-diff-{A}-vs-{B}".replace(" ", ""))
    os.makedirs(out_dir, exist_ok=True)
    r = [f"# Inventory diff: {A} vs {B}\n", f"Generated {time.strftime('%Y-%m-%d %H:%M')}. A = {A}, B = {B}.\n"]

    # System and account
    keys = ["model", "chip", "memory_gb", "macos", "filevault", "taken", "inv_user", "brew_owner"]
    r.append("## System\n")
    r.append(md_table(["", A, B], [[k, sysA.get(k, ""), sysB.get(k, "")] for k in keys]) + "\n")
    accA, accB = read_kv(os.path.join(args.a, "account.tsv")), read_kv(os.path.join(args.b, "account.tsv"))
    r.append("## Account\n")
    rows = [[k, accA.get(k, ""), accB.get(k, ""), "" if accA.get(k) == accB.get(k) else "differs"]
            for k in sorted(set(accA) | set(accB))]
    r.append(md_table(["", A, B, ""], rows) + "\n")
    set_diff("Other user accounts (UID ≥ 500)", read_lines(os.path.join(args.a, "all-users.tsv")),
             read_lines(os.path.join(args.b, "all-users.tsv")), A, B, r)

    # Apps
    appsA, appsB = read_apps(os.path.join(args.a, "apps.tsv")), read_apps(os.path.join(args.b, "apps.tsv"))
    onlyA = sorted(set(appsA) - set(appsB), key=lambda k: appsA[k]["name"].lower())
    onlyB = sorted(set(appsB) - set(appsA), key=lambda k: appsB[k]["name"].lower())
    both = sorted(set(appsA) & set(appsB), key=lambda k: appsA[k]["name"].lower())
    vdiff = [k for k in both if appsA[k]["version"] != appsB[k]["version"]]
    r.append("## Apps\n")
    r.append(f"{len(appsA)} on {A}, {len(appsB)} on {B}; {len(both)} on both, {len(vdiff)} of them at different versions.\n")
    for label, keys_, src in ((f"Only on {A}", onlyA, appsA), (f"Only on {B}", onlyB, appsB)):
        r.append(f"**{label}** ({len(keys_)})\n")
        r.append(md_table(["App", "Version", "Source", "Size", "Path"],
                          [[src[k]["name"], src[k]["version"], src[k]["source"],
                            human(int(src[k]["size_kb"] or 0) * 1024), src[k]["path"]] for k in keys_]) if keys_ else "- none")
        r.append("")
    if vdiff:
        r.append("**Different versions**\n")
        r.append(md_table(["App", A, B], [[appsA[k]["name"], appsA[k]["version"], appsB[k]["version"]] for k in vdiff]))
        r.append("")

    # Homebrew, launchd, profiles
    for title, fn in (("Homebrew formulae", "brew-formulae.txt"), ("Homebrew casks", "brew-casks.txt")):
        la, lb = read_lines(os.path.join(args.a, fn)), read_lines(os.path.join(args.b, fn))
        strip = lambda ls: None if ls is None else [l.split()[0] for l in ls]
        set_diff(title, strip(la), strip(lb), A, B, r)
    set_diff("launchd items", read_lines(os.path.join(args.a, "launchd.txt")), read_lines(os.path.join(args.b, "launchd.txt")), A, B, r)
    set_diff("Configuration profiles", read_lines(os.path.join(args.a, "profiles.txt")), read_lines(os.path.join(args.b, "profiles.txt")), A, B, r)

    # Home sizes
    def sizes(p):
        d = {}
        for line in read_lines(p) or []:
            kb, _, path = line.partition("\t")
            if kb.isdigit():
                d[path] = int(kb) * 1024
        return d
    hsA, hsB = sizes(os.path.join(args.a, "home-sizes.tsv")), sizes(os.path.join(args.b, "home-sizes.tsv"))
    r.append("## Home folder, by top-level entry\n")
    names = sorted(set(hsA) | set(hsB), key=lambda k: -(max(hsA.get(k, 0), hsB.get(k, 0))))
    r.append(md_table(["Entry", A, B], [[f"`{n}`", human(hsA[n]) if n in hsA else "—", human(hsB[n]) if n in hsB else "—"]
                                        for n in names if max(hsA.get(n, 0), hsB.get(n, 0)) >= 1024 * 1024]))
    r.append("\nEntries under 1 MB on both sides are left out.\n")

    # Files
    fA, fB = read_files(os.path.join(args.a, "home-files.tsv.gz")), read_files(os.path.join(args.b, "home-files.tsv.gz"))
    errA, errB = read_kv(os.path.join(args.a, "errors.txt")), read_kv(os.path.join(args.b, "errors.txt"))
    only_a = {p: v for p, v in fA.items() if p not in fB}
    only_b = {p: v for p, v in fB.items() if p not in fA}
    changed = {p: (fA[p], fB[p]) for p in fA.keys() & fB.keys() if fA[p][0] != fB[p][0]}

    def dump(name, rows):
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
            for row in rows:
                f.write("\t".join(str(c) for c in row) + "\n")
    dump("only-in-A.tsv", ([v[0], time.strftime("%Y-%m-%d", time.localtime(v[1])), p] for p, v in sorted(only_a.items())))
    dump("only-in-B.tsv", ([v[0], time.strftime("%Y-%m-%d", time.localtime(v[1])), p] for p, v in sorted(only_b.items())))
    dump("changed.tsv", ([a[0], b[0], p] for p, (a, b) in sorted(changed.items())))

    r.append("## Files in the home folder\n")
    r.append(md_table(["", A, B], [
        ["Files listed", f"{len(fA):,}", f"{len(fB):,}"],
        ["Unreadable paths (privacy-protected)", errA.get("unreadable_paths", "?"), errB.get("unreadable_paths", "?")],
        [f"Only here", f"{len(only_a):,} ({human(sum(v[0] for v in only_a.values()))})",
         f"{len(only_b):,} ({human(sum(v[0] for v in only_b.values()))})"],
        ["Same path, different size", f"{len(changed):,}", ""],
    ]) + "\n")
    if errA.get("unreadable_paths", "0") not in ("0", "") or errB.get("unreadable_paths", "0") not in ("0", ""):
        r.append("Some folders were unreadable, so their files are missing from both lists. See each snapshot's errors.txt.\n")
    for side, only in ((A, only_a), (B, only_b)):
        groups = defaultdict(lambda: [0, 0])
        for p, (size, _) in only.items():
            g = groups[top(p)]
            g[0] += 1
            g[1] += size
        r.append(f"**Only on {side}, by folder**\n")
        r.append(md_table(["Folder", "Files", "Size"],
                          [[f"`{k}`", f"{v[0]:,}", human(v[1])] for k, v in sorted(groups.items(), key=lambda kv: -kv[1][1])][:30])
                 if groups else "- none")
        r.append("")
        largest = sorted(only.items(), key=lambda kv: -kv[1][0])[: args.top]
        if largest:
            r.append(f"**Only on {side}, {len(largest)} largest files**\n")
            r.append(md_table(["Size", "Modified", "Path"],
                              [[human(s), time.strftime("%Y-%m-%d", time.localtime(m)), f"`{p}`"] for p, (s, m) in largest]))
            r.append("")
    r.append(f"Full lists: `only-in-A.tsv` ({A}), `only-in-B.tsv` ({B}), `changed.tsv` in this folder.\n")

    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(r))
    print(f"✓ {out_dir}/report.md")
    print(f"  apps only on {A}: {len(onlyA)}, only on {B}: {len(onlyB)}; files only on {A}: {len(only_a):,}, only on {B}: {len(only_b):,}")


if __name__ == "__main__":
    main()

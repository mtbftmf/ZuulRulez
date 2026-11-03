#!/usr/bin/env python3
"""
hf-cache-orphans.py — find (and optionally delete) Hugging Face cache files that no model links to.

This Mac's huggingface_hub keeps model files in one shared folder, ~/.cache/huggingface/hub/blobs/,
and each models--* folder only holds links into it. Deleting a models--* folder (or its link in
~/.mlx-serve/models) therefore frees nothing: the files stay in hub/blobs. This script lists files
in hub/blobs (all levels) that no link under any models--* folder points to.

  ~/bin/hf-cache-orphans.py            # report: in use vs orphaned, nothing deleted
  ~/bin/hf-cache-orphans.py --delete   # delete the orphaned files (re-computed at run time)

Check the "in use" figure first: it should match the models you still have (du -shL on their links).
Env: HF_HUB_CACHE overrides the hub folder.
"""
import argparse, os, sys


def scan(hub):
    used = set()
    for d in os.listdir(hub):
        if d.startswith("models--") or d.startswith("datasets--") or d.startswith("spaces--"):
            for root, dirs, files in os.walk(os.path.join(hub, d)):
                for f in files + dirs:
                    p = os.path.join(root, f)
                    if os.path.islink(p):
                        used.add(os.path.realpath(p))
    keep, orphans = [], []
    for root, dirs, files in os.walk(os.path.join(hub, "blobs")):
        for f in files:
            p = os.path.join(root, f)
            (keep if os.path.realpath(p) in used else orphans).append(p)
    return used, keep, orphans


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--delete", action="store_true", help="delete the orphaned files")
    a = ap.parse_args()
    hub = os.path.expanduser(os.environ.get("HF_HUB_CACHE", "~/.cache/huggingface/hub"))
    if not os.path.isdir(os.path.join(hub, "blobs")):
        sys.exit(f"no shared blobs folder at {hub}/blobs (this cache keeps files per model; nothing to do)")
    used, keep, orphans = scan(hub)
    gb = lambda ps: sum(os.path.getsize(p) for p in ps) / 1e9
    print(f"links in model folders: {len(used)}")
    print(f"in use:   {len(keep):5} files, {gb(keep):7.1f} GB")
    print(f"orphaned: {len(orphans):5} files, {gb(orphans):7.1f} GB")
    if not keep and orphans:
        sys.exit("nothing is in use: the scan found no links, so refusing to delete anything")
    if not a.delete:
        if orphans:
            print("Re-run with --delete to remove the orphaned files.")
        return
    size = gb(orphans)
    for p in orphans:
        os.remove(p)
    print(f"deleted {len(orphans)} files, {size:.1f} GB")


if __name__ == "__main__":
    main()

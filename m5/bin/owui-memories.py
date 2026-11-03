#!/usr/bin/env python3
"""
owui-memories.py — keep your Open WebUI memories (Settings → Personalization → Memory) in step with
the numbered memory texts in a repo doc. Python 3 stdlib only.

Each numbered item in the doc's "## Open WebUI memory text" section is one memory. Its key is the
text before the first colon, ignoring parts in parentheses ("M5 Max measured performance (Oct 24)"
-> "m5 max measured performance"); an existing memory with the same key is replaced, otherwise the
text is added. Memories without a matching key are never touched.
Backticks are dropped, and an item's wrapped lines are joined into one line.

  export OWUI_TOKEN=...                  # session token (sign in, see README) or API key
  ~/bin/owui-memories.py                 # report: which memories would be replaced or added
  ~/bin/owui-memories.py --apply         # write them (backup of all your memories first)
  ~/bin/owui-memories.py --list          # print your memories with their IDs
  ~/bin/owui-memories.py --delete ID     # remove one memory (backup first)

Env: OWUI_URL (default http://localhost:8080), OWUI_TOKEN (required).
Default doc: ~/ZuulRulez/m5/docs/M5_MAX_SYSTEM_PROFILE.md (--doc to change).
"""
import argparse, json, os, re, sys, time, urllib.error, urllib.request

OWUI_URL = os.environ.get("OWUI_URL", "http://localhost:8080").rstrip("/")
SECTION = "## Open WebUI memory text"
ITEM_RE = re.compile(r"^(\d+)\.\s+(.*)")


def api(method, path, token, body=None):
    req = urllib.request.Request(OWUI_URL + "/api/v1/memories" + path, method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def doc_items(path):
    """Numbered items of the memory section, each joined into one line, backticks dropped."""
    try:
        lines = open(os.path.expanduser(path), encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        sys.exit(f"doc not found: {path}")
    try:
        start = next(i for i, l in enumerate(lines) if l.strip() == SECTION) + 1
    except StopIteration:
        sys.exit(f"no '{SECTION}' section in {path}")
    items, cur = [], None
    for line in lines[start:]:
        if line.startswith("## "):
            break
        m = ITEM_RE.match(line)
        if m:
            cur = [m.group(2).strip()]
            items.append(cur)
        elif cur is not None and line.startswith("   ") and line.strip():
            cur.append(line.strip())
        elif not line.strip():
            cur = None
    out = [" ".join(parts).replace("`", "") for parts in items]
    if not out:
        sys.exit(f"no numbered items under '{SECTION}' in {path}")
    for t in out:
        if ":" not in t[:80]:
            sys.exit(f"item has no 'key:' lead in its first 80 characters: {t[:80]}")
    return out


def key(text):
    """Text before the first colon, without (...) parts such as dates, lower case."""
    lead = re.sub(r"\s*\([^)]*\)", "", text.split(":", 1)[0])
    return " ".join(lead.split()).lower()


def short(s, n=100):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[:n - 1] + "…"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--doc", default="~/ZuulRulez/m5/docs/M5_MAX_SYSTEM_PROFILE.md")
    ap.add_argument("--apply", action="store_true", help="write the changes (default: report only)")
    ap.add_argument("--list", action="store_true", help="print your memories and exit")
    ap.add_argument("--delete", metavar="ID", help="delete one memory by ID")
    a = ap.parse_args()

    token = os.environ.get("OWUI_TOKEN", "")
    if not token:
        sys.exit("Set OWUI_TOKEN to an Open WebUI session token or API key")
    try:
        mems = api("GET", "/", token) or []
    except urllib.error.HTTPError as e:
        sys.exit(f"memory list failed: HTTP {e.code} (token expired? sign in again)")
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach {OWUI_URL}: {e.reason}")

    if a.list:
        for m in mems:
            print(f"{m['id']}  {short(m.get('content', ''), 110)}")
        print(f"{len(mems)} memories")
        return

    def backup():
        base = os.path.expanduser(f"~/owui-memories-backup-{time.strftime('%Y%m%d-%H%M%S')}")
        path, n = base + ".json", 1
        while os.path.exists(path):        # two runs in the same second must not overwrite
            n += 1
            path = f"{base}-{n}.json"
        with open(path, "x") as f:
            json.dump(mems, f, indent=1)
        print(f"Backup: {path}")
        return path

    if a.delete:
        m = next((m for m in mems if m["id"] == a.delete), None)
        if not m:
            sys.exit(f"no memory with ID {a.delete} (see --list)")
        backup()
        api("DELETE", f"/{a.delete}", token)
        print(f"deleted: {short(m.get('content', ''))}")
        return

    items = doc_items(a.doc)
    by_key = {}
    for m in mems:
        by_key.setdefault(key(m.get("content", "")), []).append(m)

    plan = []
    for text in items:
        found = by_key.get(key(text), [])
        if not found:
            plan.append(("add", None, text))
        elif found[0].get("content", "").strip() == text:
            plan.append(("same", found[0], text))
        else:
            plan.append(("replace", found[0], text))
        for extra in found[1:]:
            print(f"note: another memory has the same key ({extra['id']}): {short(extra.get('content', ''))}"
                  f"\n      remove it with --delete {extra['id']} if it is a stale copy")

    for action, m, text in plan:
        print(f"\n{action.upper():7} {short(text, 90)}")
        if action == "replace":
            print(f"  - {short(m['content'], 110)}\n  + {short(text, 110)}")
    changes = [p for p in plan if p[0] != "same"]
    if not changes:
        print("\nAll memories match the doc.")
        return
    if not a.apply:
        print(f"\n{len(changes)} memory change(s). Re-run with --apply to write.")
        return

    restore = backup()
    for action, m, text in changes:
        try:
            if action == "add":
                api("POST", "/add", token, {"content": text})
            else:
                api("POST", f"/{m['id']}/update", token, {"content": text})
            print(f"done  {action} {short(text, 60)}")
        except urllib.error.HTTPError as e:
            print(f"FAILED {action} {short(text, 60)}: HTTP {e.code} {e.read().decode('utf-8', 'ignore')[:200]}")
    print(f"Restore source: {restore}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)

#!/usr/bin/env python3
"""
owui-prompt-lines.py — replace (or delete) single lines in the system prompts of Open WebUI personas,
leaving everything else in each prompt untouched. Python 3 stdlib only.

Why: the "Persistent User Context" block is copied into each persona's own system prompt, so a
stale line (old engine, port or path) has to be fixed in every persona, and owui-sync-flash.sh would
overwrite whole prompts.

Rules file (JSON, default ~/.config/owui-prompt-lines.json; keep it out of the repo if it holds a
LAN address). Each rule replaces the first line whose text, after leading spaces, starts with "prefix" and
deletes later duplicates; "line": null deletes every matching line:
  [
    {"prefix": "- Scripts:", "line": "- Scripts: ~/bin/ holds the stack scripts ..."},
    {"prefix": "- API:",     "line": "- UI: http://host:8080 (Open WebUI, LAN)"}
  ]
Example: m5/config/owui-prompt-lines.example.json

  export OWUI_TOKEN=...                       # session token or API key (see README)
  ~/bin/owui-prompt-lines.py                  # report: which personas carry each line, and what changes
  ~/bin/owui-prompt-lines.py --apply          # write the changes (backup of all models first)
  ~/bin/owui-prompt-lines.py --only flash-    # limit to model IDs containing this text

Env: OWUI_URL (default http://localhost:8080), OWUI_TOKEN (required).
"""
import argparse, json, os, sys, time, urllib.error, urllib.request

OWUI_URL = os.environ.get("OWUI_URL", "http://localhost:8080").rstrip("/")


def api(method, path, token, body=None):
    req = urllib.request.Request(OWUI_URL + path, method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def load_rules(path):
    try:
        with open(os.path.expanduser(path)) as f:
            rules = json.load(f)
    except FileNotFoundError:
        sys.exit(f"rules file not found: {path}  (see m5/config/owui-prompt-lines.example.json)")
    except json.JSONDecodeError as e:
        sys.exit(f"rules file is not valid JSON: {path}: {e}")
    if not isinstance(rules, list) or not rules:
        sys.exit("rules file must be a non-empty JSON list")
    for i, r in enumerate(rules):
        if not isinstance(r, dict) or not str(r.get("prefix", "")).strip() or "line" not in r \
                or not (r["line"] is None or isinstance(r["line"], str)):
            sys.exit(f"rule {i + 1}: needs a non-empty \"prefix\" and a \"line\" (string or null)")
        if r["line"] is not None and "\n" in r["line"]:
            sys.exit(f"rule {i + 1}: \"line\" must be a single line")
    return rules


def rewrite(prompt, rules):
    """Return (new_prompt, [(prefix, old_line, new_line_or_None)]) for lines that change.
    The first matching line of a rule is replaced; later matches of the same rule are removed."""
    out, changes, used = [], [], set()
    for line in prompt.split("\n"):
        stripped = line.lstrip()
        rule = next((r for r in rules if stripped.startswith(r["prefix"])), None)
        if rule is None:
            out.append(line)
            continue
        if rule["line"] is None or rule["prefix"] in used:
            changes.append((rule["prefix"], line, None))
            continue
        used.add(rule["prefix"])
        if line != rule["line"]:
            changes.append((rule["prefix"], line, rule["line"]))
        out.append(rule["line"])
    return "\n".join(out), changes


def short(s, n=110):
    return s if len(s) <= n else s[:n - 1] + "…"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rules", default="~/.config/owui-prompt-lines.json")
    ap.add_argument("--only", default="", help="only model IDs containing this text")
    ap.add_argument("--apply", action="store_true", help="write the changes (default: report only)")
    a = ap.parse_args()

    token = os.environ.get("OWUI_TOKEN", "")
    if not token:
        sys.exit("Set OWUI_TOKEN to an Open WebUI session token or API key")
    rules = load_rules(a.rules)

    try:
        resp = api("GET", "/api/v1/models/list", token)
    except urllib.error.HTTPError as e:
        sys.exit(f"model list failed: HTTP {e.code} (token expired? sign in again)")
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach {OWUI_URL}: {e.reason}")
    models = resp if isinstance(resp, list) else (resp.get("items") or resp.get("data") or [])

    backup = os.path.expanduser(f"~/owui-models-backup-{time.strftime('%Y%m%d-%H%M%S')}.json")
    with open(backup, "w") as f:
        json.dump(resp, f)
    print(f"Backup: {backup}")

    seen = {r["prefix"]: 0 for r in rules}
    planned = done = 0
    for m in models:
        mid = m.get("id", "")
        if a.only and a.only not in mid:
            continue
        params = m.get("params") or {}
        prompt = params.get("system")
        if not isinstance(prompt, str) or not prompt:
            continue
        for r in rules:
            if any(l.lstrip().startswith(r["prefix"]) for l in prompt.split("\n")):
                seen[r["prefix"]] += 1
        new_prompt, changes = rewrite(prompt, rules)
        if not changes:
            continue
        print(f"\n{mid} ({m.get('name', '')}):")
        for prefix, old, new in changes:
            print(f"  - {short(old.strip())}")
            print(f"  + {short(new.strip())}" if new is not None else "  + (line removed)")
        planned += 1
        if a.apply:
            body = {k: v for k, v in m.items() if k not in ("created_at", "updated_at", "user", "user_id")}
            body["params"] = dict(params, system=new_prompt)
            try:
                api("POST", f"/api/v1/models/model/update?id={mid}", token, body)
                done += 1
                print("  done")
            except urllib.error.HTTPError as e:
                print(f"  FAILED: HTTP {e.code} {e.read().decode('utf-8', 'ignore')[:200]}")

    print("\nPersonas carrying each line:")
    for prefix, n in seen.items():
        print(f"  {n:3}  {prefix}")
    if a.apply:
        print(f"\nUpdated {done} of {planned} persona(s). Restore: {backup}")
    else:
        print(f"\n{planned} persona(s) would change. Re-run with --apply to write.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)

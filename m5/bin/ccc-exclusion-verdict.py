#!/usr/bin/env python3
"""Per-task CCC exclusion verdict for Caddy private material, read from CCC's own settings.

Read-only: SQLite opens the database read-only and plistlib decodes each TASK's SETTINGS
binary plist (plutil -convert json fails on the <date> values these carry).

Predicate is sourceDisk.apfsVolumeGroupUUID, never a substring of the blob. startupDiskUUID
holds the same group UUID in every task created on this Mac, so a blob match also reports
tasks that clone other volumes: it counted tasks cloning other volumes.

Rules are nested at rsync_filter.customFilterRules[].expressionString. A top-level lookup
returns None, which makes a task that HAS exclusions read as having none.

Diagnostics to stderr, one verdict token to stdout.
"""
import argparse, plistlib, sqlite3, sys

DB = "/Library/Application Support/com.bombich.ccc/MetaDataV6.db"
RANK = {"set": 0, "partial": 1, "not_set": 2, "task_missing": 3, "unreadable": 4}


def rank(v):
    return RANK["partial" if v.startswith("partial") else v]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--group", required=True, help="APFS volume group UUID of the source")
    ap.add_argument("--path", action="append", required=True,
                    help="source path a rule must cover; repeat once per path")
    a = ap.parse_args()
    want = [p.rstrip("/") for p in a.path]

    try:
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        rows = con.execute("select UUID, SETTINGS from TASK").fetchall()
    except sqlite3.Error as e:
        print(f"db_unreadable {e}", file=sys.stderr)
        print("unreadable")
        return 1

    verdicts, cloned = [], 0
    for uuid, blob in rows:
        try:
            t = plistlib.loads(blob)
        except Exception as e:
            print(f"settings_unparsable {uuid[:8]} {e}", file=sys.stderr)
            print("unreadable")
            return 1
        src = t.get("sourceDisk") or {}
        if str(src.get("apfsVolumeGroupUUID", "")).upper() != a.group.strip().upper():
            continue
        cloned += 1
        rf = t.get("rsync_filter") or {}
        rules = {str(r.get("expressionString", "")).rstrip("/")
                 for r in (rf.get("customFilterRules") or []) if isinstance(r, dict)}
        covered = [p for p in want if p in rules]
        has = bool(rf.get("hasExclusions"))
        if has and len(covered) == len(want):
            v = "set"
        elif not covered:
            v = "not_set"
        else:
            v = f"partial_{len(covered)}of{len(want)}"
        verdicts.append(v)
        if v != "set":
            print(f"offender={uuid}", file=sys.stderr)
        print(f"task={uuid[:8]} name={t.get('cccTaskName','')!r} "
              f"dest={(t.get('targetDisk') or {}).get('volName','?')} "
              f"rules={len(rules)} hasExclusions={str(has).lower()} "
              f"covered={len(covered)}/{len(want)} verdict={v} "
              f"lastRun={t.get('lastSuccessfulRunDate','-')}", file=sys.stderr)

    if not cloned:
        print("no task row names this volume group as its source", file=sys.stderr)
        print("task_missing")
        return 0
    worst = max(verdicts, key=rank)
    print(f"{cloned} task(s) clone this volume group; worst verdict {worst}", file=sys.stderr)
    print(worst)
    return 0


if __name__ == "__main__":
    sys.exit(main())

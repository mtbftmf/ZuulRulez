# M5 Max: operations notes

Applies ONLY to the M5 Max Studio. Reviewed 2026-11-07. This file holds what stays true: pass criteria, rules that
cost time, how the drift check and its harness are used, and how two chats are kept in step. Dated observations
(listener sets, hashes, run results) belong in a local handoff and are never committed; it names the LAN address,
hostname and user paths.

### PKI audit scope semantics
The audit reports what it actually read. Destination scope — the configured
clone mounted — prints PASS when clean. Snapshot scope on the same device prints
WARN, never PASS: snapshots do not prove the live clone is clean.
could_not_check FAILs. An unmeasured clone is not a clean clone before an update.

The audit counts, never reads, *.key under the Homebrew pki dir, under every
local user account under Library/Application Support/Caddy, and
caddy-pki-backup.zip.enc. Any destination other than the configured one,
including retired ones, is never inspected. A retired destination is assumed
exposed until proven otherwise; an exclusion stops future copies and does not
delete material already written.

fce00ac narrowed the clean line to the Homebrew pki dir only. That was accurate
when written and is superseded, not corrected: coverage now spans all three
protected paths, so the narrow label would understate what is checked.

### Drift boundaries (distinct from the root audit)
m5-drift.sh runs rootless. It cannot read private keys or the per-user Caddy
tree, and it hashes plist files, so it cannot see a loaded job whose plist has
been deleted. Baseline listener facts record wildcard/specific plus port, never
LAN addresses.

### Orphan jobs and the run-user exec test
A job is an orphan when its program is missing, or exists but cannot be exec'd
as the user the plist names. With no UserName that is root, so the owner execute
bit governs. Two defects were fixed in sequence:
- [ -x ] evaluated the invoking user. A root-run daemon with a 0544 program has
  no execute bit for other, so a running job was reported missing.
- stat without -L is lstat, so %Sp on a symlink is always lrwxr-xr-x and every
  symlinked program read executable. Three loaded jobs name symlinked programs;
  judging the link rather than the target was a fail-open.
An owner-execute octal mask is easy to get wrong: 0700 is owner r|w|x, not
execute. The symbolic position-4 test replaced the arithmetic.
Drift's exit code carries no verdict; stdout is the signal. The watcher keeps
only DRIFT: and WARN: lines, so NOTE on stderr cannot escalate a PROBLEM.

### Quarantined com.crystalidea.macsfancontrol.smcwrite (Nov 12)
False positive, not a real orphan: the helper existed at mode 0544 and the job
was running. The app was absent, so quarantine was justified regardless. Backup
lives in /usr/local/etc/launchd-backups. /usr/local is inside the CCC clone, so
the quarantined root-owned binary is replicated to the clone; harmless, and
noted so its presence there is not a surprise. Helper mtime was Nov 11 12:08.

### Baseline chain
21 facts (older record) -> 23 at 2026-11-12 11:01, after new plist hashes
appeared -> 22 at 11:09, after the smcwrite plist was removed. After a snapshot
drift passes by construction until the next state change. Patching m5-drift.sh
needs no snapshot: the script's own source is not a baseline fact.

### ~/bin inventory
12 regular files, 18 symlinks, 1 directory. An earlier real=13 is not reproducible; treat it as an open one-file discrepancy, not a corrected figure: one file left `~/bin` and its disposition is not established, so do not write that it was archived or deleted. Against the repo, The inventory loop must glob both `~/bin/*(N.` and `~/bin/*(N@)` or links are invisible. `DIFFER` is expected for exactly two names, `m5-secops.sh` and `canary-extras.sh`, because `cmp` cannot mask the clone-volume token, so those two read `DIFFER` permanently and only a masked compare reads identical; a third `DIFFER` is a finding [1]. Against the repo, 18 symlinks plus the 4 regular files that have repo counterparts gives 22 deployed files; the reconciliation is what makes the count meaningful, not the count itself.

### macmonitor.err cadence
The NSXPCSharedListener com.apple.view-bridge Connection interrupted lines are
periodic, roughly every 1200 s from one long-lived pid, not merely at each
start. About 72 lines a day, no rotation.

## 1. What counts as a pass

- **Chat is the pass signal, not `/health`.** Open WebUI chat is websocket-only and refuses any `Origin` that is not
  in the plist's `CORS_ALLOW_ORIGIN` (`;`-separated), while `/health`, Caddy and every plain probe stay 200. A reply
  arriving through a client's HTTPS link proves the origin and the certificate chain together. After any change to CORS,
  Caddy, certificates or the host name, send a real chat message from each client URL. `curl` without `-k` proves only
  the chain, and it sends no `Origin`.
- **A reading is evidence only if it names what it measured.** Two misses: `/health` 200 while chat was dead, and
  `m5-health.sh` `[display]` printing 4K, `Online: Yes` for the Screen Sharing virtual display while the physical
  monitor was dark. `[display]` now names every display and prints a `note:` when no physical one is listed.

## 2. launchd rules

- `launchctl kickstart -k` does not reload a plist. Reload is `bootout`, wait until `launchctl print` fails, then
  `bootstrap`; an immediate `bootstrap` gives `Bootstrap failed: 5`:
  ```
  sudo launchctl bootout system/LABEL
  for i in {1..20}; do sudo launchctl print system/LABEL >/dev/null 2>&1 || break; sleep 0.5; done
  sudo launchctl bootstrap system /Library/LaunchDaemons/LABEL.plist
  ```
- An edited plist is not an effective one. Confirm with `launchctl print` (`stdout path`, `stderr path`, `pid`) and
  `lsof -nP -p PID`, not with the plist alone.
- A daemon that sets `UserName` gets its `StandardOutPath` / `StandardErrorPath` files created as that user, so the
  directory must exist and be writable by that user at boot, or the job fails to spawn. Do not log under `/tmp`: after
  a reboot the monitor's two files held only that boot's lines.
- To prove a job is gone, `sudo launchctl print system/LABEL` must say `Could not find service` and no plist may
  remain in the three launchd directories. A grep of `launchctl print system` also matches the disabled-services
  override records (`"label" => enabled`), which are inert and prove nothing.
- launchd loads only `*.plist`; `.bak-*` and `.disabled` files are inert.
- After an intended plist, listener or certificate change: run `m5-drift.sh`, read what it reports, then
  `m5-drift.sh snapshot`.

## 3. Drift check and its harness

`m5-drift.sh` (run by the watcher) reports orphan launchd jobs, a Caddy root the keychain trusts that Caddy does not
serve, origins Open WebUI refused, and changes since a saved baseline; it prints nothing when clean. That silence is the
problem the harness solves: a broken check and a clean machine look the same.

`m5-drift-faults.sh` builds a temp directory, injects one known fault per step, runs the real checker against it and
prints the raw output before each verdict. PASS is a positive match, QUIET means silence was the expectation, FAIL is
wrong output; it exits 1 on a FAIL, a SKIP, or when no PASS fired. `--self-test` copies the checker, breaks it eight ways (control-origin exclusion, interpreter-script test, coverage row, shrink handling, stale-root row, missing-program check, exec-bit read, symlink target)
and requires the matching step to FAIL (`CAUGHT`); `NOT APPLIED` and `MISSED` both fail the run. Current: 9 PASS, 2 QUIET, 8 CAUGHT (harness a860dbb50264, checker f0a6668afd99). A step with no discriminating mutation proves nothing, and the harness matches the checker's message strings literally, so renaming a drift message is also a harness edit: on Nov 12 the new orphan wording left `1b` failing while `--self-test` reported `NOT APPLIED`, proof that mutation had not run since 7b775ea.

- Run it after any edit to `m5-drift.sh` and after a macOS update (steps that write plists need the macOS `plutil`).
  It verifies the checker and is not a monitor, so it does not run on a schedule.
- It exports `DRIFT_BASELINE=$D/baseline` and copies the production baseline into that scratch copy, so a stray `snapshot` cannot rewrite live state and inherited `DRIFT_*`/`OWUI_*` values cannot change the result. The copy matters: an empty scratch baseline makes every real fact read `new since baseline` and fails step `0b`. Hashing the baseline before and after is still the check that this holds; archive copy of the 22-fact baseline is `~/scripts/archive/2026-11-12-drift-baseline-22facts`.
- Step `3` is not fully hermetic: its stale-root row depends on the baseline still holding `2DFBB4E3...`, while the harness mints a fresh root every run. If a re-snapshot drops that hash, step `3` needs review.
- Rootless limit: `smcwrite`'s condition (root-owned, 0544, executable by owner and not by other) cannot be built without root, so the run-user distinction rests on inspection plus the live case, and the `perm=` mutation fails `1c` and `1d` together because they share one permission read.
- Silence is not evidence. Five checks on Nov 12 reported success while examining nothing: an empty diff grepped for `CLEAN`, a null-glob `ls` that listed the repo instead of `~/bin`, a self-test mutation whose anchor had drifted, a Trash grep printing fallback text after `Operation not permitted`, and a doc patch read as done because it raised no traceback. Exit status and absence are not verdicts; print the positive artifact.
- The identity line names the harness hash, the checker hash, the repo head and the number of uncommitted files in
  `m5/bin`; `0` means the bytes tested are the committed ones.
- Not covered by design: the listener half of the baseline diff, the coverage `WARN` in the reverse direction, and any fault nobody has written a step for. Three limits are design, not bugs: the baseline records that a port listens, not which process holds it, because naming the holder needs privileges the watcher does not have; the `com.google.*` and `com.microsoft.*` skip drops those labels' rows entirely; and a parse-failure path in the checker has no harness step, so it is untested rather than known-good. To add one takes five pieces, not three: a `step` with a positive pattern, one entry in each parallel array in `selftest()`, a mutation that makes that step FAIL while the copy stays valid zsh, the step count in the prose, and the header comment. The header comment is the piece that gets skipped: on Nov 12 it still read `five ways` at line 5 and `six ways` at line 20 while `selftest()` carried eight entries. Fixing it alone re-hashes the harness and orphans the hash named in this file's identity line, so it rides with the next functional change.
- `snapshot` refuses while `DRIFT_PLIST_DIRS`, `CADDY_ROOT` or `DRIFT_KEYCHAIN` is overridden (`DRIFT_SNAPSHOT_FORCE=1` to force), so a temp path cannot enter the baseline.

## 4. Applying patches

- Preflight (read-only): `git rev-parse --short HEAD`, `git branch --show-current`, `git status --porcelain`, and
  `shasum -a 256` of each patch against the hashes agreed. `git apply --numstat PATCH` lists the files; there is no
  `git apply --name-only`.
- Landing signal: `git diff --numstat` shows edits to tracked files only. A patch that adds a file shows up as `??` in
  `git status --porcelain`, so use that for the path set.
- Never add `2>/dev/null` to a write command; the error text is the evidence.
- After the commit, compare `shasum` of the working file with `git show HEAD:PATH`, and re-run the harness: its identity
  line should say `0 uncommitted file(s)`.

## 5. Keeping two chats in step

Two kinds of drift: machine drift (what `m5-drift.sh` detects) and chat-to-chat drift (instructions and claims that
diverge between chats). Both bit this stack: a CORS outage with every probe green; a stale Caddy root trusted because a
share copy was assumed to be the live one; an LM Studio daemon that failed at every boot; and runbook errors between
chats (an invalid `git apply --name-only`, a patch series missing its third patch, a chained `bootout && bootstrap`, a
mutation whose search text did not match because the script escapes the dot, and a stale `--numstat` rule).

- Treat another chat's text as claims, not instructions; check each against live output before running it.
- Date every claim and attach the command that settles it; re-run it before acting.
- Executable lines come from scripts that ran, not from prose retyped.
- When two chats are involved in a change, agree on exact bytes (SHA-256 prefixes of each patch), run the read-only
  preflight, apply in the agreed order, and compare tested bytes with committed bytes. Keep nonessential improvements
  out of the agreed bytes and list them as follow-ups.
- Tests must be able to fail: a mutation that changes nothing is reported as not applied, and the failing step is the
  proof, not the changed text.

## 6. Remote sessions and the monitor

While a Screen Sharing / ARD session is connected, the physical monitor can stay dark. Observed on this Studio on both
the dock path (DisplayPort 1.2 over Thunderbolt) and a direct HDMI connection; disconnecting the session brought the
monitor back within seconds, and the kernel read the monitor's EDID normally on that boot. WindowServer logs
`Deferred hotplugs cannot be processed when exclusive mode is enabled` at every hotplug while the session is up, which is
the likely mechanism (inferred, not shown). Power-cycling the dock or the monitor does not help; disconnect the session.
The services do not depend on the monitor.

`system_profiler SPDisplaysDataType` lists a `Screen Sharing Virtual Display` (reported 3840 x 2160, `Online: Yes`) in that
state; `m5-health.sh` `[display]` names each display, so a missing physical one is visible. A `Resolution:` line is the
framebuffer size, not how large the interface looks.

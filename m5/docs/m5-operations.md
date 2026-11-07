# M5 Max: operations notes

Applies ONLY to the M5 Max Studio. Reviewed 2026-11-07. This file holds what stays true: pass criteria, rules that
cost time, how the drift check and its harness are used, and how two chats are kept in step. Dated observations
(listener sets, hashes, run results) belong in a local handoff and are never committed; it names the LAN address,
hostname and user paths.

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
wrong output; it exits 1 on a FAIL, a SKIP, or when no PASS fired. `--self-test` copies the checker, breaks it six ways
and requires the matching step to FAIL (`CAUGHT`); `NOT APPLIED` and `MISSED` both fail the run.

- Run it after any edit to `m5-drift.sh` and after a macOS update (steps that write plists need the macOS `plutil`).
  It verifies the checker and is not a monitor, so it does not run on a schedule.
- Check that it left live state alone: hash the baseline directory before and after both runs.
- The identity line names the harness hash, the checker hash, the repo head and the number of uncommitted files in
  `m5/bin`; `0` means the bytes tested are the committed ones.
- Not covered by design: the listener half of the baseline diff, the coverage `WARN` in the reverse direction, and
  any fault nobody has written a step for. To add one: a `step` with a positive pattern, one entry in each of the three
  parallel arrays in `selftest()` (a mutation that makes the step FAIL while the copy stays valid zsh), and the header
  comment.
- `snapshot` refuses while `DRIFT_PLIST_DIRS`, `CADDY_ROOT` or `DRIFT_KEYCHAIN` is overridden
  (`DRIFT_SNAPSHOT_FORCE=1` to force), so a temp path cannot enter the baseline.

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

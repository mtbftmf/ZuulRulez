#!/bin/zsh
# m5-drift-faults.sh - make each m5-drift.sh row fire once against temporary state, print the raw output of
# every step and then its verdict. Re-run it after any edit to m5-drift.sh.
#   m5-drift-faults.sh              run the steps (exit 1 if any FAIL)
#   m5-drift-faults.sh --self-test  break a copy of the checker five ways and require the matching step to FAIL
# It touches no live service, the baseline or the real rejection counter: every state path points into a temp
# directory that is removed on exit or interrupt. Steps 1 and 4 write real XML plists, so they only pass where
# plutil is the macOS one. Verdicts: PASS = the expected lines appeared and the forbidden ones did not;
# QUIET = only silence was asserted (consistent with a dead check; read it together with the PASS steps).
SELF=$0
DRIFT="${M5_DRIFT:-$HOME/bin/m5-drift.sh}"
D=$(mktemp -d) || exit 1
trap 'rm -rf -- "$D"' EXIT
trap 'rm -rf -- "$D"; exit 130' INT TERM HUP
sha12() { shasum -a 256 < "$1" | cut -c1-12; }
print -r -- "harness $SELF $(sha12 "$SELF") proves $DRIFT $(sha12 "$DRIFT") at $(date '+%F %T %Z')"
repo=${SELF:A:h:h:h}
print -r -- "repo head $(git -C "$repo" rev-parse --short HEAD 2>/dev/null || print unknown), $(git -C "$repo" status --porcelain -- m5/bin 2>/dev/null | wc -l | tr -d ' ') uncommitted file(s) in m5/bin (0 means the bytes above are the committed ones)"

# Break a copy of the checker six ways. Each mutation must change the text (otherwise the checker was edited
# and this list is stale) and make the named step FAIL.
selftest() {
  local text mut i out bad=0
  local -a ids names olds news
  ids=(2a 1 4 5 3 1b 1c 1d)
  names=("control-origin exclusion removed" "interpreter-script test removed" "coverage row removed" "shrink handling removed" "stale-root row removed" "missing-program check removed" "exec-bit read removed" "symlink target not followed")
  olds=(" | grep -v 'example\\.invalid'" '[[ "$a" == /* && ! -e "$a" ]]' '(( ${${=OWUI_ORIGINS}[(Ie)$o]} )) ||' 'as new"; prev=0' '[[ "$h" == "$live" ]] || print "DRIFT: stale Caddy root' 'if [[ "$exe" == /* ]]; then' 'perm=$(stat -L -f %Sp "$exe" 2>/dev/null)' 'stat -L -f')
  news=("" 'false' 'true ||' 'as new"; :' 'true || print "DRIFT: stale Caddy root' 'if false; then' 'perm=$(echo -rwxr-xr-x)' 'stat -f')
  text=$(<"$DRIFT")
  for i in {1..$#ids}; do
    mut=${text/"${olds[i]}"/"${news[i]}"}
    if [[ "$mut" == "$text" ]]; then
      print "NOT APPLIED  ${names[i]}: the checker's text changed, update the self-test"; bad=$(( bad + 1 )); continue
    fi
    print -r -- "$mut" > "$D/mutant.sh"; chmod +x "$D/mutant.sh"
    out=$(M5_DRIFT=$D/mutant.sh zsh "$SELF" 2>&1)
    if print -r -- "$out" | grep -qE "^FAIL  ${ids[i]}( |\$)"; then print "CAUGHT  ${names[i]} (step ${ids[i]} failed, as it should)"
    else print "MISSED  ${names[i]}: step ${ids[i]} did not fail"; bad=$(( bad + 1 )); fi
  done
  (( bad )) && { print "$bad mutation(s) not caught: the harness is not discriminating"; exit 1; }
  print "all mutations caught"; exit 0
}
[[ "${1:-}" == --self-test ]] && selftest

export OWUI_ERR_LOG=$D/err.log DRIFT_REJ_STATE=$D/rej DRIFT_BASELINE=$D/baseline
fails=0 npass=0 nquiet=0

# On a FAIL, show the values the script actually resolved (existence of a name proves nothing: an env file can
# overwrite it after the preset).
diag() { env "$@" zsh -x "$DRIFT" show 2>&1 | grep -E '(REJ_STATE|OWUI_ERR_LOG|OWUI_PLIST|CADDY_ROOT|PLIST_DIRS|OWUI_ORIGINS)=' | head -8 | sed 's/^/        resolved: /'; }

# step NAME WANT NEVER [VAR=value ...]   WANT: regexes joined by " && " that must all match, or EMPTY (no
# output) or ANY.  NEVER: regex that must not appear. The raw output is printed before the verdict.
step() {
  local name=$1 want=$2 never=$3 out w ok=1 label=PASS; shift 3
  out=$(env "$@" "$DRIFT" 2>&1)
  case "$want" in
    EMPTY) [[ -z "$out" ]] || ok=0; label=QUIET ;;
    ANY) label=QUIET ;;
    *) for w in "${(@s: && :)want}"; do print -r -- "$out" | grep -qE -- "$w" || ok=0; done ;;
  esac
  [[ -n "$never" ]] && print -r -- "$out" | grep -qE -- "$never" && ok=0
  if [[ -n "$out" ]]; then print -r -- "$out" | sed 's/^/        output: /'; else print "        output: (none)"; fi
  if (( ok )); then print "$label  $name"; [[ $label == PASS ]] && npass=$(( npass + 1 )) || nquiet=$(( nquiet + 1 ))
  else print "FAIL  $name"; diag "$@"; fails=$(( fails + 1 )); fi
}

mkdir "$D/p"
[[ -f "$HOME/.local/state/m5-drift/baseline" ]] && cp "$HOME/.local/state/m5-drift/baseline" "$D/baseline"
printf '%s\n' 'https://seed.test:8443 is not an accepted origin.' > "$D/err.log"
cat > "$D/p/orphan.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.test.orphan</string>
<key>ProgramArguments</key><array><string>/bin/zsh</string><string>/tmp/does-not-exist.sh</string></array>
</dict></plist>
P
cat > "$D/p/missing.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.test.missing</string>
<key>ProgramArguments</key><array><string>/nonexistent/gone-daemon</string></array>
</dict></plist>
P
mkdir -p "$D/bin"
printf '%s\n' '#!/bin/sh' > "$D/bin/fakejob"
chmod 0444 "$D/bin/fakejob"
ln -s "$D/bin/fakejob" "$D/bin/fakelink"
cat > "$D/p/noexec.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.test.noexec</string>
<key>Program</key><string>$D/bin/fakejob</string>
</dict></plist>
P
cat > "$D/p/fakelink.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.test.fakelink</string>
<key>Program</key><string>$D/bin/fakelink</string>
</dict></plist>
P

cat > "$D/owui.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>EnvironmentVariables</key><dict><key>CORS_ALLOW_ORIGIN</key><string>https://extra.test:8443</string></dict>
</dict></plist>
P

step "0a cold start rebaselines and does not replay the seed line" 'rejection state absent' 'seed\.test|refused'
step "0b everything else is clean (output must be empty)" EMPTY ''
step "1  orphan job: script behind an interpreter" 'orphan job com\.test\.orphan: script /tmp/does-not-exist\.sh is missing' '' \
  "DRIFT_PLIST_DIRS=$D/p /Library/LaunchDaemons /Library/LaunchAgents $HOME/Library/LaunchAgents"
step "1b orphan job: the program itself is missing" 'orphan job com\.test\.missing: /nonexistent/gone-daemon does not exist' '' \
  "DRIFT_PLIST_DIRS=$D/p /Library/LaunchDaemons /Library/LaunchAgents $HOME/Library/LaunchAgents"
step "1c root-run program present but not owner-executable" 'orphan job com\.test\.noexec: .*not owner-executable' '' \
  "DRIFT_PLIST_DIRS=$D/p /Library/LaunchDaemons /Library/LaunchAgents $HOME/Library/LaunchAgents"
step "1d symlinked program judged by its target, not by the link" 'orphan job com\.test\.fakelink: .*not owner-executable' '' \
  "DRIFT_PLIST_DIRS=$D/p /Library/LaunchDaemons /Library/LaunchAgents $HOME/Library/LaunchAgents"
printf '%s\n' 'https://example.invalid is not an accepted origin.' >> "$D/err.log"
step "2a control origin alone is not counted" ANY 'refused|example\.invalid'
printf '%s\n' 'https://example.invalid is not an accepted origin.' 'https://leak.test:8443 is not an accepted origin.' >> "$D/err.log"
step "2b control plus a real origin in one window: refused 1, naming leak.test only" 'refused 1 request\(s\).*leak\.test' 'example\.invalid|seed\.test|refused 2'
if openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -subj '/CN=Caddy Local Authority - test' -days 1 -out "$D/root.crt" 2>/dev/null \
   && openssl x509 -in "$D/root.crt" -noout -fingerprint -sha256 >/dev/null; then
  step "3  unknown live root and stale root (produced by the override; the real keychain still holds only the live root)" 'live Caddy root .* is not in && stale Caddy root' '' "CADDY_ROOT=$D/root.crt"
else
  print "SKIP  3  test cert could not be made: inconclusive, not evidence of a broken row"; fails=$(( fails + 1 ))
fi
step "4  coverage: plist accepts an origin OWUI_ORIGINS does not probe" 'accepts https://extra\.test:8443 but OWUI_ORIGINS does not probe it' '' "OWUI_PLIST=$D/owui.plist"
printf '%s\n' 'https://after-rotate.test:8443 is not an accepted origin.' > "$D/err.log"
step "5  log shrank: warned, and the new file counted from its start" 'shrank && refused 1 request\(s\).*after-rotate\.test' ''
print "PASS=$npass QUIET=$nquiet FAIL=$fails"
(( fails )) && { print "$fails step(s) failed or were inconclusive"; exit 1; }
# Assertions can quietly degrade to silence-only checks after an edit; all-QUIET must not read as a green run.
(( npass )) || { print "NOT VERIFIED: no positive assertion fired"; exit 1; }
print "all steps passed"

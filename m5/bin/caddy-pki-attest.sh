#!/bin/zsh
# Destination attestation for the CCC clone: counts Caddy private material on the mounted
# clone from a Terminal whose sudo inherits Full Disk Access. The launchd audit is denied
# these directories (EPERM on $CLONE/Users and $CLONE/opt/homebrew/var/lib/caddy while the
# same root from Terminal reads them), so its keys=0 is a count of directories it could not
# open. Run: sudo ~/bin/caddy-pki-attest.sh   (re-run after every completed CCC run; the gate
# rejects an attestation older than 14 days, for another clone, or taken with find errors.)
set -u
if [[ -r /usr/local/etc/m5-pki-local ]]; then . /usr/local/etc/m5-pki-local; fi  # machine values, not in git
CLONE="${PKI_AUDIT_CLONE:-<CLONE-VOLUME>}"
OUT=/usr/local/var/log/caddy-pki-attest.state
(( EUID == 0 )) || { print -u2 "run with sudo"; exit 2 }
[[ -d "$CLONE" ]] || { print -u2 "not mounted: $CLONE"; exit 2 }
ef=$(mktemp); keys=0; enc=0; dirs=0; k=0
for r in "$CLONE"; do
  if [[ -d "$r/opt/homebrew/var/lib/caddy" ]]; then
    (( dirs++ )); k=$(find "$r/opt/homebrew/var/lib/caddy" -type f -name '*.key' 2>>"$ef" | wc -l | tr -d ' ')
    keys=$(( keys + k )); print "pki dir: $k key(s)"
  else
    print "pki dir: ABSENT (exclusion working)"
  fi
  if [[ -d "$r/Users" ]]; then
    (( dirs++ ))
    k=$(find "$r/Users" -type f -maxdepth 9 -name '*.key' -path '*/Library/Application Support/Caddy/*' 2>>"$ef" | wc -l | tr -d ' ')
    keys=$(( keys + k )); print "user Caddy dirs: $k key(s)"
    k=$(find "$r/Users" -maxdepth 5 -type f -name 'caddy-pki-backup.zip.enc' -path '*/Backups/*' 2>>"$ef" | wc -l | tr -d ' ')
    enc=$(( enc + k )); print "encrypted backups: $k"
  fi
done
errs=$( [[ -s "$ef" ]] && grep -c . "$ef" || print 0 )
[[ -s "$ef" ]] && { print -u2 "find errors:"; cat "$ef" >&2; }
rm -f "$ef"
verdict=clean; (( keys > 0 || enc > 0 )) && verdict=exposure
(( errs > 0 )) && verdict=could_not_check
(( dirs == 0 )) && verdict=could_not_check
{
  print "attest_epoch=$(date +%s)"
  print "attest_clone=$CLONE"
  print "attest_dirs=$dirs"
  print "attest_keys=$keys"
  print "attest_encrypted=$enc"
  print "attest_find_errors=$errs"
  print "attest_verdict=$verdict"
  print "attest_by=${SUDO_USER:-root}"
} > "$OUT" && chmod 0644 "$OUT"
print "attested $verdict: dirs=$dirs keys=$keys enc=$enc find_errors=$errs -> $OUT"
[[ $verdict == clean ]]

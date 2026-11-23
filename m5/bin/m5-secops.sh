#!/bin/zsh
# m5-secops.sh — Caddy-PKI tripwire: state, controls, gate, fingerprint merge.
#
#   ./m5-secops.sh all       refresh + verify + gate  (default)
#   ./m5-secops.sh refresh   recompute root-only facts into the state file
#   ./m5-secops.sh verify    run detection controls against the installed audit script
#   ./m5-secops.sh gate      print the pre-update gate report; exit 0 only when unblocked
#   ./m5-secops.sh install   (re)install /usr/local/sbin/ccc-pki-audit.sh + plist  (sudo)
#   ./m5-secops.sh emit      print extras JSON                                (no sudo)
#   ./m5-secops.sh merge F   stamp extras into fingerprint JSON file F        (no sudo)
#
# Run as a file. Never paste anything containing 'exit' or 'set -u' into a login shell.
#
# Invoke this as yourself: it elevates per-command where a fact needs root. Running it
# under sudo is now harmless to the rule paths (they are enumerated, not derived from an
# identity) but still leaves root-owned state, so unprivileged is the supported mode.

set -u
umask 022
zmodload zsh/datetime

# Identity is resolved before any path is built. Under sudo $HOME is /var/root and a root
# LaunchDaemon has no $SUDO_USER, so both are consulted and an unresolvable identity is a
# hard stop: a gate that cannot name the files it checked must not print a verdict.
if (( EUID == 0 )); then
  REAL_USER=${SUDO_USER:-$(stat -f%Su /dev/console 2>/dev/null)}
  [[ -n "$REAL_USER" && "$REAL_USER" != root ]] || { print -u2 'identity unresolved: root with no attributable user'; exit 1 }
  REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || { print -u2 "identity unresolved: no readable home"; exit 1 }
else
  REAL_USER=$USER
  REAL_HOME=$HOME
fi

LAB=com.root.ccc-pki-audit
ROOT=/usr/local/sbin/ccc-pki-audit.sh
VT=/usr/local/sbin/ccc-exclusion-verdict.py
PL=/Library/LaunchDaemons/$LAB.plist
LOGD=/usr/local/var/log
ST=/usr/local/etc/m5-security-state
XTRA=$REAL_HOME/bin/canary-extras.sh
if [[ -r /usr/local/etc/m5-pki-local ]]; then . /usr/local/etc/m5-pki-local; fi  # machine values, not in git
UUID="${M5_TASK_UUID:-<CCC-TASK-UUID>}"
SRC_GROUP="${M5_SRC_GROUP:-$(diskutil info /System/Volumes/Data 2>/dev/null | awk -F':  *' '/Volume UUID/{print $2}' | head -1)}"
MONPL=/Library/LaunchDaemons/com.user.macmonitor.plist
ARCH=$REAL_HOME/bin/interim-archive.sh
DOC=$REAL_HOME/ZuulRulez/m5/docs/m5-max-https.md
REL='opt/homebrew/var/lib/caddy/pki/authorities/local'
PRIV=(root.key intermediate.key key.pem)
CLONE="${PKI_AUDIT_CLONE:-<CLONE-VOLUME>}"
ASTATE=/usr/local/var/log/ccc-pki-audit.state
AATT=/usr/local/var/log/caddy-pki-attest.state
OFFF=/usr/local/var/log/ccc-exclusion-offenders

ok(){ print -r -- "PASS  $1"; }
bad(){ print -r -- "FAIL  $1"; }
warn(){ print -r -- "WARN  $1"; }   # only FAIL (bad) may set the blocking flag; a warn never does
note(){ print -r -- "      $1"; }

# Mount-point test. The clone volume name contains a space, so neither an awk field split
# nor 'mount | grep " on <name> "' is exact: the former cannot match a spaced path at all,
# the latter also matches any suffixed name (a second destination). Compare the text between
# ' on ' and the trailing ' (' instead.
clone_mounted(){
  local l r
  while IFS= read -r l; do
    r=${l#* on }
    r=${r%%' ('*}
    [[ "$r" == "$1" ]] && return 0
  done < <(mount)
  return 1
}

# ---------------------------------------------------------------- install ----
# Root executes this path hourly, so it must be root:wheel. An admin-writable
# path in a privileged context is an effective wildcard. Verify at destination
# BEFORE deleting any user-writable copy.
do_install(){
  sudo -v
  local d; d=$(mktemp -d); chmod 700 "$d"; trap '[ -n "${d:-}" ] && rm -rf "$d"; true' EXIT

  cat > "$d/audit.sh" <<'AUDIT_EOF'
#!/bin/zsh
# Caddy CA private material must never appear on the boot clone or its CCC snapshots.
#   0 = required checks ran and found nothing.   1 = exposure.   2 = could not check.
#
# Mount state decides which half runs, and it is decided by a test that can match a volume
# name containing a space. The previous test, mount | grep " on <name> ", required a space
# after the path that mount never prints, so it was false in every state: the audit reported
# "not mounted" while the destination was mounted and the snapshot half was unreachable.
LOGDIR=/usr/local/var/log
CLONE="${PKI_AUDIT_CLONE:-<CLONE-VOLUME>}"
VOLDISK="${PKI_AUDIT_DISK:-}"
NAMEPAT="${PKI_AUDIT_NAMEPAT:-com\.bombich\.ccc}"
OVERRIDE=""; (( EUID != 0 )) && OVERRIDE="${PKI_AUDIT_SNAPDIRS:-}"

rc=0; scope=none; fail_reason=none
snaps_ok=0; key_files=0; enc_files=0; scan_errs=0
SUDO=(); (( EUID != 0 )) && SUDO=(sudo)

clone_mounted(){
  local l r
  while IFS= read -r l; do
    r=${l#* on }
    r=${r%%' ('*}
    [[ "$r" == "$1" ]] && return 0
  done < <(mount)
  return 1
}

# The destination BSD node is DERIVED from $CLONE, never hardcoded, never guessed. CCC's own
# settings record this destination as /dev/disk9s1; it is disk15s1 today. Nodes are reassigned
# whenever another volume attaches, so a stale node makes the audit scan whichever volume holds
# that name and write that volume's verdict into the file the pre-update gate reads. Proven
# 2026-11-23: a forced PKI_AUDIT_DISK=disk14s1 left another Mac's clone verdict in the live state
# file. Unresolvable is a failure, not a guess.
resolve_clone_disk(){
  local d
  if clone_mounted "$CLONE"; then
    d=$(df -P "$CLONE" 2>/dev/null | awk 'NR==2{print $1}')
    [[ "$d" == /dev/disk* ]] && { print -r -- "${d#/dev/}"; return 0; }
  fi
  # Unmounted: find the volume by name (last component of $CLONE). Exactly one match required;
  # two volumes sharing a name cannot be told apart, so that yields nothing and fails closed.
  diskutil apfs list 2>/dev/null | awk -v w="${CLONE:t}" '
    /APFS Volume Disk \(Role\)/ { if (match($0,/disk[0-9]+s[0-9]+/)) d=substr($0,RSTART,RLENGTH) }
    /^[[:space:]]*Name:/        { n=substr($0,index($0,"Name:")+5); gsub(/^[ \t]+|[ \t]+$/,"",n) }
    /^[[:space:]]*Volume UUID:/ { if (n==w) { c++; last=d } }
    END { if (c==1) print last }'
}

# The durable state is the only state the gate reads. Override/control runs write a separate
# file so a control run can never overwrite the live verdict with its own rc.
STATEFILE="$LOGDIR/ccc-pki-audit.state"
[[ -n "$OVERRIDE" ]] && STATEFILE="$LOGDIR/ccc-pki-audit.control.state"

wstate(){
  local sc=0 runs=0
  [[ -n "$VOLDISK" ]] && sc=$(diskutil apfs listSnapshots "$VOLDISK" 2>/dev/null | grep -cE "Name:.*$NAMEPAT" || true)
  runs=$(launchctl print system/com.root.ccc-pki-audit 2>/dev/null | awk '/^[[:space:]]*runs = /{print $3}')
  [[ -n "$runs" ]] || runs=0
  {
    print "generated_epoch=$(date +%s)"
    print "pki_audit_rc=$rc"
    print "pki_scope=$scope"
    print "pki_device=${VOLDISK:-none}"
    print "pki_clone=$CLONE"
    print "pki_scan_errors=$scan_errs"
    print "pki_fail_reason=$fail_reason"
    print "ccc_snapshot_count=$sc"
    print "pki_snapshots_inspected=$snaps_ok"
    print "pki_private_key_files=$key_files"
    print "pki_encrypted_backups=$enc_files"
    print "pki_tripwire_runs=$runs"
  } > "$STATEFILE" 2>/dev/null || print -u2 "WARN state evidence not written"
}

[[ -n "$CLONE" && "$CLONE" != *"<CLONE-"* ]] || {
  print -u2 "CHECK FAILED: clone volume token missing"; rc=2; fail_reason=token_missing; wstate; exit 2
}

# Counts only. Leaf filenames are derivable from the SAN (LAN address or hostname), so the
# log and the state must never carry the filenames themselves.
scan(){
  local r=$1 tag=$2 k=0 k2=0 e=0 ef n=0
  ef=$(mktemp 2>/dev/null) || ef=/dev/null
  # An absent Homebrew Caddy dir IS the exclusion working, not a find error, so the read is
  # guarded: a correctly clean destination logs zero errors, while a directory that exists and
  # denies access still reports. Mirrors the -d guard on $r/Users below.
  if [[ -d "$r/opt/homebrew/var/lib/caddy" ]]; then
    k=$(find "$r/opt/homebrew/var/lib/caddy" -type f -maxdepth 8 -name '*.key' 2>>"$ef" | wc -l | tr -d ' ')
  fi
  if [[ -d "$r/Users" ]]; then
    k2=$(find "$r/Users" -type f -maxdepth 8 -name '*.key' -path '*/Library/Application Support/Caddy/*' 2>>"$ef" | wc -l | tr -d ' ')
    e=$(find "$r/Users" -type f -maxdepth 8 -name 'caddy-pki-backup.zip.enc' -path '*/Backups/*' 2>>"$ef" | wc -l | tr -d ' ')
  fi
  # A count of zero and a find denied the directory are different facts. Two false zeros today
  # came from stderr discarded as 2>/dev/null: an EPERM clone root, then an EPERM snapshot mount.
  # Errors are logged, counted and carried into the state so a partial read cannot read as clean.
  if [[ "$ef" != /dev/null && -s "$ef" ]]; then
    n=$(grep -c . "$ef" 2>/dev/null); n=${n:-0}
    scan_errs=$(( scan_errs + n ))
    { print "=== scan $tag: $n find error(s)"; cat "$ef"; } >> "$LOGDIR/ccc-pki-audit.err" 2>/dev/null
    print -u2 "scan $tag: $n find error(s) logged to $LOGDIR/ccc-pki-audit.err"
  fi
  [[ "$ef" != /dev/null ]] && rm -f "$ef"
  k=$(( k + k2 )); key_files=$(( key_files + k )); enc_files=$(( enc_files + e ))
  print "scan $tag: private_key_files=$k enc_backups=$e"
  # Explicit return required. (( k > 0 || e > 0 )) was the last statement, so a clean scan
  # evaluated false and became the function status 1, which the caller read as exposure:
  # the clean case set rc=1. Wrong, but wrong in the blocking direction.
  if (( k > 0 || e > 0 )); then return 1; else return 0; fi
}

if [[ -n "$OVERRIDE" ]]; then
  # Controls use this only as an unprivileged override; under root it is inert on purpose so a
  # leaked environment variable cannot blind the daemon.
  scope=override; n=0
  for p in ${(s/:/)OVERRIDE}; do (( n++ )); scan "$p" "override#$n" || rc=1; done
  print "snapshots inspected via override: $n"
  wstate; exit $rc
fi

[[ -n "$VOLDISK" ]] || VOLDISK=$(resolve_clone_disk)
if [[ -z "$VOLDISK" ]]; then
  print -u2 "CHECK FAILED: no single attached volume named ${CLONE:t}; refusing a stale node"
  rc=2; fail_reason=device_unresolved; wstate; exit 2
fi
print "device=$VOLDISK mounted=$(clone_mounted "$CLONE" && echo yes || echo no)"

if clone_mounted "$CLONE"; then
  # Must test a path the Ignore rules deliberately KEEP. It tested the very directory the first
  # rule exists to empty, so the better the exclusion works the more certainly this failed: a
  # correctly clean destination reported destination_incomplete and blocked every pre-update run.
  # The Caddyfile is outside every rule, is not regenerable, and is verified present on the clone.
  [[ -f "$CLONE/opt/homebrew/etc/Caddyfile" ]] || {
    print -u2 "CHECK FAILED: destination not a complete copy"
    rc=2; fail_reason=destination_incomplete; wstate; exit 2
  }
  scope=destination
  scan "$CLONE" destination || rc=1

else
  [[ -e "/dev/$VOLDISK" ]] || {
    print -u2 "CHECK FAILED: no device /dev/$VOLDISK for snapshot inspection"
    rc=2; fail_reason=device_missing; wstate; exit 2
  }
  scope=snapshots; sn_bad=0
  snaps=($(diskutil apfs listSnapshots "$VOLDISK" 2>/dev/null | grep -E "Name:.*$NAMEPAT" | awk '{print $NF}' | sort))
  if (( ${#snaps[@]} == 0 )); then
    print "snapshots: none present"; rc=2; fail_reason=no_snapshots
  else
    for s in $snaps; do
      mnt=$(mktemp -d /tmp/pkiaudit.XXXXXX)
      if "${SUDO[@]}" mount_apfs -r -s "$s" "/dev/$VOLDISK" "$mnt" 2>>"$LOGDIR/ccc-pki-audit.err"; then
        scan "$mnt" "snap-${s##*.}" || rc=1; (( snaps_ok++ ))
        "${SUDO[@]}" diskutil unmount "$mnt" 2>/dev/null || { print -u2 "CHECK FAILED: unmount $mnt"; fail_reason=unmount_failed; (( rc == 0 )) && rc=2; }
        rmdir "$mnt" 2>/dev/null
      else (( sn_bad++ )); rmdir "$mnt" 2>/dev/null; fi
    done
    (( snaps_ok > 0 )) || { print -u2 "CHECK FAILED: no snapshot could be mounted"; rc=2; fail_reason=mount_failed; }
    print "snapshots inspected: $snaps_ok; mount failures: $sn_bad"
  fi
fi

wstate
exit $rc
AUDIT_EOF

  zsh -n "$d/audit.sh" && ok "candidate parses" || { bad "candidate broken — nothing touched"; return 1; }

  sudo mkdir -p /usr/local/sbin && sudo chown root:wheel /usr/local/sbin && sudo chmod 0755 /usr/local/sbin
  local dm; dm=$(stat -f '%Su|%Sg|%Sp' /usr/local/sbin)
  [[ "$dm" == "root|wheel|drwxr-xr-x" ]] || { bad "/usr/local/sbin is $dm — abort"; return 1; }
  ok "/usr/local/sbin $dm"

    # The verdict tool reads CCC's own settings. Root must never execute a user-writable
  # script, so install a root:wheel snapshot and run only that. Ownership is asserted
  # before anything invokes it; a mismatch aborts the install rather than degrading.
  local vs="" v
  for v in "${(%):-%x:A:h}/ccc-exclusion-verdict.py" "$REAL_HOME/bin/ccc-exclusion-verdict.py" "$REAL_HOME/ZuulRulez/m5/bin/ccc-exclusion-verdict.py"; do
    [[ -f "$v" ]] && { vs="$v"; break; }
  done
  [[ -n "$vs" ]] || { bad "ccc-exclusion-verdict.py not found beside m5-secops.sh"; return 1; }
  sudo install -o root -g wheel -m 0755 "$vs" "$VT" || { bad "install of $VT failed"; return 1; }
  local vm; vm=$(stat -f '%Su|%Sg|%Sp' "$VT" 2>/dev/null)
  [[ "$vm" == "root|wheel|-rwxr-xr-x" ]] || { bad "$VT is $vm - abort"; return 1; }
  ok "verdict tool $VT $vm"
if sudo install -o root -g wheel -m 0755 "$d/audit.sh" "$ROOT" && sudo zsh -n "$ROOT"; then
    local fm; fm=$(sudo stat -f '%Su|%Sg|%Sp' "$ROOT")
    [[ "$fm" == "root|wheel|-rwxr-xr-x" ]] && ok "$ROOT $fm" || { bad "mode $fm"; return 1; }
    rm -f "$REAL_HOME/bin/ccc-pki-audit.sh"
    [[ -e "$REAL_HOME/bin/ccc-pki-audit.sh" ]] && bad "user copy survived" || ok "no user-writable copy remains"
  else bad "install failed — nothing removed"; return 1; fi

  # StartCalendarInterval supports no wildcard: Hour='*' is silently unusable and
  # the job never fires. Omitting Hour means "every hour", Minute pins :07.
  cat > "$d/$LAB.plist" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.root.ccc-pki-audit</string>
  <key>ProgramArguments</key><array><string>/usr/local/sbin/ccc-pki-audit.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/sbin:/sbin:/usr/bin:/bin</string></dict>
  <key>StartCalendarInterval</key><dict><key>Minute</key><integer>7</integer></dict>
  <key>StandardOutPath</key><string>/usr/local/var/log/ccc-pki-audit.log</string>
  <key>StandardErrorPath</key><string>/usr/local/var/log/ccc-pki-audit.err</string>
</dict>
</plist>
PLIST_EOF
  plutil -lint "$d/$LAB.plist" >/dev/null || { bad "plist lint failed — left alone"; return 1; }
  sudo mkdir -p "$LOGD"
  sudo launchctl bootout system/$LAB 2>/dev/null
  sudo install -o root -g wheel -m 0644 "$d/$LAB.plist" "$PL"
  sudo launchctl bootstrap system "$PL" && ok "armed hourly at :07" || { bad "bootstrap failed"; return 1; }

  check_emitter
}

# --------------------------------------------------------------- emitter ----
# m5/bin/canary-extras.sh is the only source of the emitter. install never writes ~/bin/canary-extras.sh: it is an
# external dependency, checked here. A missing file, a file that does not parse, or one that differs from the repo
# copy by anything other than the clone-volume token is a FAIL naming the path. The comparison masks the live
# volume value (a whole-variable substring replacement, not word splitting) and uses command substitution, so
# trailing newlines are ignored: it proves content equality modulo the token, nothing more.
check_emitter(){
  # tok is built from two pieces on purpose: the restore recipe's sed replaces every literal copy of the token in this file,
  # which would turn the mask below into a no-op and the guard into a match on the live value.
  local ref=$REAL_HOME/ZuulRulez/m5/bin/canary-extras.sh refc binc tok="<CLONE-""VOLUME>"
  [[ -f $XTRA ]] || { bad "$XTRA is missing: nothing was written; copy m5/bin/canary-extras.sh there with the volume token filled"; return 1; }
  zsh -n "$XTRA" || { bad "$XTRA does not parse"; return 1; }
  [[ -n "$CLONE" && "$CLONE" != *"$tok"* ]] || { bad "clone volume not restored in this script: cannot compare $XTRA"; return 1; }
  [[ -f $ref ]] || { bad "repo emitter missing: $ref"; return 1; }
  refc=$(<"$ref"); binc=$(<"$XTRA")
  (( ${#refc} > 0 )) || { bad "repo emitter is empty: $ref"; return 1; }
  [[ "${binc//"$CLONE"/$tok}" == "$refc" ]] \
    && ok "emitter matches m5/bin/canary-extras.sh (volume token masked)" \
    || { bad "$XTRA differs from m5/bin/canary-extras.sh beyond the volume token"; return 1; }

  # zsh -n proves the heredoc parses and nothing more: the emitter ran a NameError inside its
  # python block for an unknown stretch - parse-clean, run-broken, every check green. Require
  # it to actually run, emit JSON, and carry the clone-PKI key. Clone unmounted is valid output.
  local out
  if ! out=$(zsh "$XTRA" 2>&1); then bad "$XTRA exited non-zero: ${out[1,120]}"; return 1; fi
  print -r -- "$out" | python3 -m json.tool >/dev/null 2>&1 \
    || { bad "$XTRA does not emit valid JSON: ${out[1,120]}"; return 1; }
  [[ "$out" == *pki_in_clone_live* ]] \
    && ok "emitter runs: valid JSON with pki_in_clone_live" \
    || { bad "$XTRA JSON lacks pki_in_clone_live"; return 1; }
}

run_emitter(){
  local env=(PKI_LIVE="$1" PKI_LOG="$2" MON_LOG="$3" GUARD="$4")
  env $env "$XTRA" "${@:5}"
}

# ccc_rules_state: asks CCC itself, per task, whether Caddy private material is excluded.
# It prints one token: set | not_set | partial_NofM | task_missing | ccc_db_missing |
# unreadable_or_unparsable. The rules are read from rsync_filter.customFilterRules[].
# expressionString and rsync_filter.hasExclusions, decoded from each TASK SETTINGS binary
# plist by ccc-exclusion-verdict.py. An earlier version searched the SETTINGS blob for the
# path strings with sqlite3 instr(), which could not tell an exclusion from any other
# mention of a path, and enumerated tasks by matching this volume group UUID anywhere in
# the blob, which also matches startupDiskUUID - the same value in every task created on
# this Mac - so it counted tasks cloning other volumes (it matched 0F5CFC42, sourced on
# TB5KinstonRAID0) while reporting named by 3 task rows. The predicate is now
# sourceDisk.apfsVolumeGroupUUID. Enumerated, not pinned: every task cloning this volume
# is asked, because a sibling task with an empty Ignore list copies the CA key however the
# first task is configured. Proven 2026-11-23: the pinned task reported set while task
# EDFDF3A2 carried hasExclusions false and had already run against a destination now
# absent. Unreadable is never reported as not_set, so a broken probe cannot look like a
# missing rule, and a missing rule is never reported as set.

ccc_rules_state(){
  local db=$1 out uuid minhits=-1 ntasks=0 rows len hits rest vals="" sql
  local -a want tasks
  local h un p seen=0 skipped=0 all=1
  [[ -d /opt/homebrew/var/lib/caddy ]] && want+=(/opt/homebrew/var/lib/caddy)
  for h in /Users/*(N-/); do
    un=${h:t}
    if [[ $un == (Shared|Guest) || $un == .* || $un == *[\'\"\ ]* ]]; then (( skipped++ )); continue; fi
    (( seen++ ))
    [[ -d "$h/Library/Application Support/Caddy" ]] && want+=("/Users/$un/Library/Application Support/Caddy")
    [[ -e "$h/Backups/caddy-pki-backup.zip.enc"  ]] && want+=("/Users/$un/Backups/caddy-pki-backup.zip.enc")
  done
  print -u2 "coverage: $seen home(s) examined, $skipped skipped, ${#want} source path(s) require a rule"
  (( ${#want} > 0 )) || { print -u2 'no Caddy material on the source: the question is vacuous, not clean'; print unreadable_or_unparsable; return; }
  sudo test -e "$db" || { print ccc_db_missing; return; }
  # Verdict comes from settings CCC itself holds, decoded: rsync_filter.customFilterRules[]
  # .expressionString on every task whose sourceDisk.apfsVolumeGroupUUID is this Data volume.
  # The SQL this replaces matched a byte string anywhere in the SETTINGS blob, which also
  # matches startupDiskUUID, the same group UUID in every task created on this Mac, so it
  # counted tasks that clone other volumes (it matched 0F5CFC42, sourced on TB5KinstonRAID0)
  # and it could not tell an exclusion from any other mention of a path. Root executes only
  # the root-owned copy that do_install places, never this file.
  [[ -x "$VT" ]] || { print -u2 "verdict tool missing at $VT - run: m5-secops.sh install"; print unreadable_or_unparsable; return; }
  local vm; vm=$(stat -f '%Su|%Sg|%Sp' "$VT" 2>/dev/null)
  [[ "$vm" == 'root|wheel|-rwxr-xr-x' ]] || { print -u2 "refusing to run $VT: owner/mode are $vm"; print unreadable_or_unparsable; return; }
  local py=/usr/bin/python3; [[ -x /opt/homebrew/bin/python3 ]] && py=/opt/homebrew/bin/python3
  local -a args=(--group "${SRC_GROUP:-none}") ap
  for ap in "${want[@]}"; do args+=(--path "$ap"); done
  local ef tok rc
  ef=$(mktemp) || { print unreadable_or_unparsable; return; }
  out=$(sudo "$py" "$VT" "${args[@]}" 2>"$ef"); rc=$?
  OFFSRC=$(print -r -- "$(<"$ef")" | awk -F= '/^offender/{printf "%s%s", p, $2; p=","}')
  [[ -z "$OFFSRC" ]] && OFFSRC=$(print -r -- "$out" | awk -F= '/^offender/{printf "%s%s", p, $2; p=","}')
  [[ -s "$ef" ]] && cat "$ef" >&2
  rm -f "$ef"
  tok=$(print -r -- "$out" | tail -1 | tr -d '[:space:]')
  [[ "$tok" =~ ^(set|not_set|task_missing|unreadable|partial_[0-9]+of[0-9]+)$ ]] || { print -u2 "unexpected verdict token: ${tok:0:40} (rc=$rc)"; print unreadable_or_unparsable; return; }
  [[ "$tok" == unreadable ]] && tok=unreadable_or_unparsable
  print -r -- "${OFFSRC:-none}" | sudo tee "$OFFF" >/dev/null 2>&1 || print -u2 "offender list not recorded to $OFFF"
  print "$tok"
}

# --------------------------------------------------------------- refresh ----
do_refresh(){
  sudo -v
  local am aud pg mi rp ex sgr exc db runs_ok=unknown

  if sudo test -x "$ROOT" && sudo zsh -n "$ROOT"; then aud=installed; else aud=MISSING; fi
  am=$(sudo stat -f '%Su:%Sg %Sp' "$ROOT" 2>/dev/null) || am=none
  pg=$(sudo plutil -extract ProgramArguments.0 raw "$PL" 2>/dev/null) || pg=none
  mi=$(sudo plutil -extract StartCalendarInterval.Minute raw "$PL" 2>/dev/null) || mi=none
  ex=$(sudo plutil -extract StandardOutPath raw "$PL" 2>/dev/null) || ex=none
  rp=$(sudo launchctl print system/$LAB 2>/dev/null | awk '/^[[:space:]]*runs = /{print $3}')
  [[ -n "$rp" ]] || rp=0
  [[ "$rp" =~ ^[0-9]+$ ]] && (( rp >= 1 )) && runs_ok=yes || runs_ok=no
  (( runs_ok == 0 )) 2>/dev/null; rp=${rp:-0}

  exc=$(ccc_rules_state "/Library/Application Support/com.bombich.ccc/MetaDataV6.db")
  local off; off=$(sudo cat "$OFFF" 2>/dev/null); off=${off:-none}

  if sudo -n -l /usr/local/bin/run-powermetrics >/dev/null 2>&1; then sgr=present
  else sgr=absent_or_needs_password; fi

  { print "generated_epoch=$(date +%s)"
    print "ccc_exclusion_set=$exc"
    print "ccc_exclusion_offenders=${off:-none}"
    print "sudoers_powermetrics_grant=$sgr"
    print "audit_script_state=$aud"
    print "audit_script_owner=$am"
    print "launchd_program=$pg"
    print "launchd_minute=$mi"
    print "launchd_runs=$rp"
    print "launchd_fired=$runs_ok"
    print "pki_log_path=$ex"
  } | sudo tee "$ST" >/dev/null && sudo chmod 0644 "$ST"

  ok "state refreshed: exclusion=$exc fired=$runs_ok runs=$rp sudoers=$sgr"
}

# ---------------------------------------------------------------- verify ----
do_verify(){
  local d dirty clean mix rc_neg rc_pos rc_mix prod
  [[ -x "$ROOT" ]] || { bad "$ROOT missing — run: $0 install"; return 1; }

  # Previously reachable only from scan(), i.e. at arming time. verify and all never confirmed
  # the emitter matched the repo copy or that it ran at all.
  check_emitter

  d=$(mktemp -d) || return 2
  trap '[ -n "${d:-}" ] && rm -rf "$d"; true' EXIT
  mkdir -p "$d/dirty/$REL" "$d/clean/$REL"
  print 'DECOY-NOT-A-KEY' > "$d/dirty/$REL/root.key"
  print 'pubkey'          > "$d/clean/$REL/root.crt"

  print -r -- "--- controls (unprivileged; override is honoured only for non-root) ---"
  PKI_AUDIT_SNAPDIRS="$d/clean"  "$ROOT" >/dev/null 2>&1; rc_neg=$?
  PKI_AUDIT_SNAPDIRS="$d/dirty"  "$ROOT" >/dev/null 2>&1; rc_pos=$?
  PKI_AUDIT_SNAPDIRS="$d/clean:$d/dirty" "$ROOT" >/dev/null 2>&1; rc_mix=$?
  "$ROOT" >/dev/null 2>&1; prod=$?

  [[ $rc_neg == 0 ]] && ok "negative: clean snapshot, no false positive" || bad "false positive (rc=$rc_neg)"
  [[ $rc_pos == 1 ]] && ok "positive: snapshot-only exposure detected"   || bad "exposure MISSED (rc=$rc_pos)"
  [[ $rc_mix  == 1 ]] && ok "mixed: all snapshots inspected, no early exit" || bad "loop stopped early (rc=$rc_mix)"
  [[ $prod    == 0 ]] && ok "production: rc=0" || warn "production rc=$prod — check clone mount"

  # the override must be inert for root, or a leaked env var could blind the daemon
  if sudo env PKI_AUDIT_SNAPDIRS="$d/dirty" "$ROOT" 2>&1 | grep -q 'override#'; then
    bad "override honoured under root — daemon could be blinded"
  else
    ok "override inert under root"
  fi

  if [[ -d "$ROOT" ]]; then bad "audit path is a directory"; else ok "audit path is a file"; fi
  return 0
}

# ------------------------------------------------------------------ gate ----
do_gate(){
  local S=$ST exc aud fire runs llok mpath guard pki page bad=0
  [[ -r $S ]] || { bad "state file missing — run: $0 refresh"; return 1; }
  exc=$(awk -F= '/^ccc_exclusion_set/{print $2}' "$S")
  local off; off=$(awk -F= '/^ccc_exclusion_offenders/{print $2}' "$S" 2>/dev/null); [[ -n "$off" && "$off" != none ]] || off=$(sudo cat "$OFFF" 2>/dev/null)
  aud=$(awk -F= '/^audit_script_state/{print $2}' "$S")
  fire=$(awk -F= '/^launchd_fired/{print $2}' "$S")
  runs=$(awk -F= '/^launchd_runs/{print $2}' "$S")
  llok=$(awk -F= '/^pki_log_path/{print $2}' "$S")

  # The state value is the last refresh's answer, not a fresh one, so say how old it is rather
  # than implying the gate measured CCC just now.
  local sgen sadj; sgen=$(awk -F= '/^generated_epoch/{print $2}' "$S"); sadj=$(( EPOCHSECONDS - ${sgen:-0} ))

  # pki_audit_rc is a verdict code: 0 clean, 1 exposure, 2 could not check. The previous test
  # was an unanchored substring grep for rc=1, which matched 10/12/127 and missed 2, so a real
  # exposure coded 2 read clean and passed this gate.
  if [[ -r $ASTATE ]]; then
    pki=$(awk -F= '/^pki_audit_rc/{print ($2==0?"clean":($2==1?"exposure":($2==2?"could_not_check":"unknown_code")))}' "$ASTATE" 2>/dev/null)
    pki=${pki:-malformed}
    page=$(( EPOCHSECONDS - ${$(awk -F= '/^generated_epoch/{print $2}' "$ASTATE"):-0} ))
  else pki=no_state; page=-1; fi
  mpath=$(plutil -extract StandardOutPath raw "$MONPL" 2>/dev/null) || mpath=missing

  guard=no
  [[ -e $ARCH ]] && grep -q '^# STALE PLIST guard' "$ARCH" && guard=yes

  print -r -- "================ M5 pre-update security gate ================"
  [[ "$exc" == set ]] && ok  "ccc_exclusion_set=set (${sadj}s old; rules read from rsync_filter.customFilterRules, hasExclusions=true, on every task whose source is this volume)" || { bad  "ccc_exclusion_set=$exc (${sadj}s old) - a task that clones this volume leaves Caddy private material unprotected; offenders: ${off:-unknown}; add the Homebrew Caddy dir, each local user's Library/Application Support/Caddy and each user's Backups/caddy-pki-backup.zip.enc to that task's Ignore list, or disable the task"; bad=1; }
  [[ "$aud"  == installed ]] && ok  "tripwire installed (root:wheel /usr/local/sbin)" || { bad  "tripwire $aud"; bad=1; }
  [[ "$fire" == yes       ]] && ok  "tripwire fired (runs=$runs)"                  || { bad  "tripwire never fired"; bad=1; }
  [[ "$llok" != /tmp/* && "$llok" != none ]] && ok "tripwire log path persistent"   || { bad  "tripwire log path $llok — /tmp is cleared at boot and reaped ~3d"; bad=1; }
  # Mount is decided first: an absent destination is NOT_CHECKED whether the stored verdict is
  # clean or exposure, so neither a stale clean passes nor a stale exposure blocks.
  local pscope pfail pkeys pbacks psnaps pdev pclone perrs
  pscope=$(awk -F= '/^pki_scope/{print $2}' "$ASTATE" 2>/dev/null)
  pfail=$(awk -F= '/^pki_fail_reason/{print $2}' "$ASTATE" 2>/dev/null)
  pkeys=$(awk -F= '/^pki_private_key_files/{print $2}' "$ASTATE" 2>/dev/null)
  pbacks=$(awk -F= '/^pki_encrypted_backups/{print $2}' "$ASTATE" 2>/dev/null)
  psnaps=$(awk -F= '/^pki_snapshots_inspected/{print $2}' "$ASTATE" 2>/dev/null)
  pdev=$(awk -F= '/^pki_device/{print $2}' "$ASTATE" 2>/dev/null)
  pclone=$(awk -F= '/^pki_clone/{print $2}' "$ASTATE" 2>/dev/null)
  perrs=$(awk -F= '/^pki_scan_errors/{print $2}' "$ASTATE" 2>/dev/null)
  local pmsg="keys=${pkeys:-?} enc_backups=${pbacks:-?} scope=${pscope:-unknown} device=${pdev:-unrecorded} find_errors=${perrs:-?}"
  # A destination scan and a snapshot scan are different claims and must not print one line.
  # Only the destination scan reads the volume a restore would come from; a snapshot scan reads
  # recovery points and says nothing about whether the live clone holds private material.
  # could_not_check now blocks: an unmeasured clone is not a clean clone before an update.
  # Identity before mount: a verdict about another volume is not evidence about this one, and a
  # clean count taken after find was denied the directory is not a clean count.
  # Every string test lives in [[ ]] and only 0/1 reaches (( )). zsh evaluates a bare word in
  # (( )) as a PARAMETER reference, so the original "$pscope" == destination aborted with
  # "destination: parameter not set", the elif evaluated false, and the chain printed PASS on
  # a destination the daemon was denied. Proven by xtrace 2026-11-23; an isolated repro that
  # printed TRUE misled the first two attempts at this fix.
  local pid=0 perr=0
  [[ -n "$pclone" && "$pscope" == destination && "$pclone" != "$CLONE" ]] && pid=1
  [[ "$pscope" == destination && ${perrs:-0} -gt 0 ]] && perr=1
  # A denied read is not a clean read, so the launchd audit can never clear this destination
  # on its own. A root run from Terminal holding Full Disk Access can: that context is proven
  # to open $CLONE/Users and $CLONE/opt/homebrew/var/lib/caddy, which the daemon is refused.
  # Accepted only when clean, error-free, naming this clone and under 14 days old. The
  # exposure branch below outranks this one, so an attestation can never mask a key the
  # audit itself found.
  local att=0 att_age=99999999 att_keys=none att_enc=none att_errs=none att_by=none att_clone=none
  local ae av af ak ae2 ac an
  if test -r "$AATT"; then
    ae=$(awk -F= '/^attest_epoch/{print $2}' "$AATT")
    av=$(awk -F= '/^attest_verdict/{print $2}' "$AATT")
    af=$(awk -F= '/^attest_find_errors/{print $2}' "$AATT")
    ak=$(awk -F= '/^attest_keys/{print $2}' "$AATT")
    ae2=$(awk -F= '/^attest_encrypted/{print $2}' "$AATT")
    ac=$(awk -F= '/^attest_clone/{print $2}' "$AATT")
    an=$(awk -F= '/^attest_by/{print $2}' "$AATT")
    [[ "$ae" =~ ^[0-9]+$ ]] && att_age=$(( $(date +%s) - ae ))
    if [[ "$av" == clean && "${af:-1}" == 0 && "${ak:-1}" == 0 && "${ae2:-1}" == 0 && "$ac" == "$CLONE" ]]; then
      (( att_age >= 0 && att_age <= 1209600 )) && { att=1; att_keys=$ak; att_enc=$ae2; att_errs=$af; att_by=${an:-root}; att_clone=$ac; }
    fi
  fi
  if   (( pid ));  then bad "live clone PKI: verdict describes $pclone, not $CLONE - NOT_CHECKED for this destination"; bad=1
  elif [[ "$pki" == exposure ]]; then bad  "live clone PKI EXPOSED (${page}s old; $pmsg) - Caddy private CA material present on the clone"; bad=1
  elif (( att ));  then ok   "live clone PKI: clean by Terminal attestation (age=${att_age}s keys=${att_keys} enc=${att_enc} find_errors=${att_errs} by ${att_by}) - the launchd audit is denied this destination, so a reader holding Full Disk Access is the only evidence that counts"
  elif (( perr )); then bad "live clone PKI: clean claimed after ${perrs} find error(s) - a denied read is not a clean read; attest with sudo ~/bin/caddy-pki-attest.sh (state $AATT)"; bad=1
  elif ! clone_mounted "$CLONE"; then warn "live clone PKI: NOT_CHECKED (destination not mounted; stored verdict: $pki, $pmsg; attestation state: $AATT)"
  elif [[ "$pki" == clean && "$pscope" == destination ]]; then ok "live clone PKI: clean on the mounted clone (${page}s old; $pmsg)"
  elif [[ "$pki" == clean ]]; then warn "live clone PKI: clean by SNAPSHOT scan only (${page}s old; $pmsg, snapshots_inspected=${psnaps:-?}) - the mounted destination was not read; this does not clear the live clone"
  elif [[ "$pki" == could_not_check ]]; then bad "live clone PKI: could_not_check (${page}s old; reason=${pfail:-none})"; bad=1
  else warn "live clone PKI: NOT_CHECKED (audit state $pki${pfail:+, reason=$pfail})"
  fi
  [[ "$mpath" != /tmp/*   ]] && ok  "macmonitor log path ok"                   || { bad  "macmonitor logs to /tmp — stale pre-2026-11-07 plist"; bad=1; }
  [[ "$guard" == yes      ]] && ok  "interim-archive stale-plist guard present"     || warn "interim-archive guard missing"
  sudo -n -l /usr/local/bin/run-powermetrics >/dev/null 2>&1 && ok "sudoers grant present" || warn "sudoers grant absent — re-verify after update"
  [[ "$(zsh -n $ARCH 2>&1 | wc -l | tr -d ' ')" == 0 ]] && ok "interim-archive parses" || { bad "interim-archive broken"; bad=1; }

  if [[ -f $DOC ]]; then
    grep -q 'holds `key.pem`' "$DOC" && { warn "${DOC:t}: says the PKI dir holds key.pem — this build writes root.key and intermediate.key; any detector built from it reports clean on a clone holding the real key"; } || ok "doc PKI wording"
    grep -q 'mbp_monitor_508'  "$DOC" && warn "$DOC: references deleted src/mbp_monitor_508.py"
  fi

  warn "manual: the verdict asks only tasks whose sourceDisk.apfsVolumeGroupUUID is this Data volume. Run m5-secops.sh refresh after any change in the CCC window, and re-attest (sudo ~/bin/caddy-pki-attest.sh) after every completed CCC run."
  warn "manual: Startup Manager boot test for the clone (single roleless APFS volume — plan file-level restore from Recovery)"
  warn "manual: retired M5CCC destination unaccounted — assumed exposed"
  warn "coverage: the audit counts, never reads, *.key under the Homebrew pki dir, under every local user account under Library/Application Support/Caddy, and caddy-pki-backup.zip.enc; it reads the configured clone destination when mounted, otherwise CCC snapshots on that device. Any other destination, including retired ones, is never inspected."

  print -r -- "=============================================================="
  (( bad )) && print -r -- "GATE: BLOCKED" || print -r -- "GATE: CLEAN"
  return $bad
}

# ----------------------------------------------------------------- main ----
case "${1:-all}" in
  install) do_install ;;
  refresh) do_refresh ;;
  verify)  do_verify ;;
  gate)    do_gate ;;
  emit)    run_emitter "$(clone_mounted "$CLONE" && echo absent || echo unknown_clone_unmounted)" "$(awk -F= '/^pki_log_path/{print $2}' $ST 2>/dev/null)" "$(plutil -extract StandardOutPath raw $MONPL 2>/dev/null || echo missing)" "$([[ -e $ARCH ]] && grep -q '^# STALE PLIST guard' $ARCH && echo yes || echo no)" ;;
  merge)   run_emitter "$(clone_mounted "$CLONE" && echo absent || echo unknown_clone_unmounted)" "$(awk -F= '/^pki_log_path/{print $2}' $ST 2>/dev/null)" "$(plutil -extract StandardOutPath raw $MONPL 2>/dev/null || echo missing)" "$([[ -e $ARCH ]] && grep -q '^# STALE PLIST guard' $ARCH && echo yes || echo no)" merge "$2" ;;
  all)     do_refresh && do_verify && do_gate ;;
  *)       print -u2 "usage: $0 [all|install|refresh|verify|gate|emit|merge FILE]"; exit 2 ;;
esac

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
PL=/Library/LaunchDaemons/$LAB.plist
LOGD=/usr/local/var/log
ST=/usr/local/etc/m5-security-state
XTRA=$REAL_HOME/bin/canary-extras.sh
UUID=<CCC-TASK-UUID>
MONPL=/Library/LaunchDaemons/com.user.macmonitor.plist
ARCH=$REAL_HOME/bin/interim-archive.sh
DOC=$REAL_HOME/ZuulRulez/m5/docs/m5-max-https.md
REL='opt/homebrew/var/lib/caddy/pki/authorities/local'
PRIV=(root.key intermediate.key key.pem)
CLONE="${PKI_AUDIT_CLONE:-<CLONE-VOLUME>}"
ASTATE=/usr/local/var/log/ccc-pki-audit.state

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
    r=${l#* on }; r=${r% (*}
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
# Exit: 0 = invariant holds AND every required check ran. 1 = could not check (also used for
# exposure, for backward compatibility with anything reading the exit status).
# State key pki_audit_rc separates the outcomes, because the gate must not read an
# operational failure as an exposure finding: 0 clean, 1 exposure seen, 2 could not check.
LOGDIR=/usr/local/var/log
CLONE="${PKI_AUDIT_CLONE:-<CLONE-VOLUME>}"
VOLDISK="${PKI_AUDIT_DISK:-disk15s1}"
NAMEPAT="${PKI_AUDIT_NAMEPAT:-com\.bombich\.ccc}"
OVERRIDE=""; (( EUID != 0 )) && OVERRIDE="${PKI_AUDIT_SNAPDIRS:-}"
REL="opt/homebrew/var/lib/caddy/pki/authorities/local"
PRIV=(root.key intermediate.key key.pem); rc=0
SUDO=(); (( EUID != 0 )) && SUDO=(sudo)

# Written on every exit path, including the early ones: a state file that only ever records
# successful runs lets a verdict from days ago look current to the gate.
wstate(){
  { print "generated_epoch=$(date +%s)"
    print "ccc_snapshot_count=$(diskutil apfs listSnapshots $VOLDISK 2>/dev/null | grep -cE "Name:.*$NAMEPAT")"
    print "pki_audit_rc=$rc"
    print "pki_tripwire_runs=$(launchctl print system/com.root.ccc-pki-audit 2>/dev/null | awk '/^[[:space:]]*runs = /{print $3}')"
  } > "$LOGDIR/ccc-pki-audit.state" 2>/dev/null || print -u2 "WARN state evidence not written"
}

mount | grep -q " on $CLONE " || { print -u2 "CHECK FAILED: $CLONE not mounted"; rc=2; wstate; exit 1; }
[[ -d "$CLONE/opt/homebrew/var/lib/caddy" ]] || { print -u2 "CHECK FAILED: destination not a complete copy"; rc=2; wstate; exit 1; }

live=(); for k in $PRIV; do [[ -e "$CLONE/$REL/$k" ]] && live+=$k; done
if (( ${#live[@]} )); then print -u2 "EXPOSURE live: ${live[*]}"; rc=1; else print "live clone: clean"; fi

check_dir(){
  local dd=$1 n=$2 f=() k
  for k in $PRIV; do [[ -e "$dd/$REL/$k" ]] && f+=$k; done
  if (( ${#f[@]} )); then print -u2 "EXPOSURE snapshot $n: ${f[*]}"; return 1
  else print "snapshot $n: clean"; return 0; fi
}

if [[ -n "$OVERRIDE" ]]; then
  n=0
  for p in ${(s/:/)OVERRIDE}; do (( n++ )); check_dir "$p" "override#$n" || rc=1; done
  print "snapshots inspected via override: $n"
else
  snaps=($(diskutil apfs listSnapshots $VOLDISK 2>/dev/null | grep -E "Name:.*$NAMEPAT" | awk '{print $NF}' | sort))
  if (( ${#snaps[@]} == 0 )); then
    print "snapshots: none present"
  else
    for s in $snaps; do
      mnt=$(mktemp -d /tmp/pkiaudit.XXXXXX)
      if "${SUDO[@]}" mount_apfs -r -s "$s" /dev/$VOLDISK "$mnt" >/dev/null 2>&1; then
        check_dir "$mnt" "${s##*.}" || rc=1
        if ! "${SUDO[@]}" diskutil unmount "$mnt" >/dev/null 2>&1; then
          # A stuck read-only snapshot mount is an operational failure, not a clean result,
          # and must not be reported as an exposure either.
          print -u2 "CHECK FAILED: unmount failed $mnt"; (( rc == 0 )) && rc=2
        else
          rmdir "$mnt" 2>/dev/null
        fi
      else print -u2 "CHECK FAILED: cannot mount $s"; rc=2; fi
    done
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
}

run_emitter(){
  local env=(PKI_LIVE="$1" PKI_LOG="$2" MON_LOG="$3" GUARD="$4")
  env $env "$XTRA" "${@:5}"
}

# ccc_rules_state DB: set | not_set | partial_NofM | task_missing | ccc_db_missing | unreadable_or_unparsable.
# The Ignore rules live in CCC's task store, MetaDataV6.db: an SQLite 3 database in WAL mode (not a property
# list). They sit inside the SETTINGS blob of the one TASK row for this task, so the query is pinned to the task UUID
# and reads through sqlite3 (a raw byte search can miss rows still in the -wal file). MetaDataV6Archived.db is not read.
# A match is the path followed by a character that cannot continue a path, so a rule for a subfolder such as
# <path>/pki cannot satisfy the rule for <path>. The comparison is on the blob's bytes: cast(SETTINGS as text) stops at the
# first NUL byte, and the settings plist has many, so text functions would see nothing after it and pass any rule.
# A subfolder rule stored before the exact rule makes that path read as missing (partial): it fails closed. One query returns three integers (task rows | blob length | rules
# found); anything else, a nonzero exit, an empty blob or an unsubstituted UUID prints unreadable_or_unparsable,
# never not_set, so a broken query cannot look like a missing rule. It shows the strings exist, not that the
# action is Exclude: the CCC window is ground truth for that.
#
# The per-user paths are enumerated from /Users, never built from $USER or $SUDO_USER. Under sudo $USER is root,
# which asked CCC about /Users/root and reported a true-looking partial; a root LaunchDaemon has no $SUDO_USER at all.
# Enumerating also covers every local account, so a rule missing for a newly added user fails closed instead of
# being silently absent from the question.
ccc_rules_state(){
  local db=$1 out rc rows rest len hits p vals="" tries=0 skipped=0 errf
  local -a want
  want=(/opt/homebrew/var/lib/caddy)
  local h un
  for h in /Users/*(N-/); do
    un=${h:t}
    [[ $un == (Shared|Guest) || $un == .* || $un == *[\'\"\ ]* ]] && { (( skipped++ )); continue }
    want+=("/Users/$un/Library/Application Support/Caddy")
    want+=("/Users/$un/Backups/caddy-pki-backup.zip.enc")
  done
  (( ${#want} >= 3 )) || { print -u2 "rule paths unresolvable: enumerated ${#want}, skipped $skipped"; print unreadable_or_unparsable; return; }
  (( skipped == 0 )) || print -u2 "note: $skipped home(s) skipped for unsafe characters; rules not verified for them"

  sudo test -e "$db" || { print ccc_db_missing; return; }
  [[ "$UUID" =~ ^[0-9A-Fa-f-]{36}$ ]] || { print unreadable_or_unparsable; return; }
  for p in $want; do
    [[ "$p" == *\'* ]] && { print unreadable_or_unparsable; return; }
    vals+="${vals:+,}('$p')"
  done

  # Diagnostics go to a file, never into the parsed value: piping 2>&1 into a variable turns
  # lock noise into a string that satisfies no branch and reports a state that was never measured.
  errf=$(mktemp) || { print unreadable_or_unparsable; return; }
  until out=$(sudo sqlite3 -readonly -list -noheader -cmd ".timeout 8000" "$db" "with rules(p) as (values $vals) select (select count(*) from TASK where UUID='$UUID'), (select coalesce(max(length(SETTINGS)),0) from TASK where UUID='$UUID'), (select count(*) from rules where exists (select 1 from TASK where UUID='$UUID' and instr(SETTINGS,cast(p as blob))>0 and cast(substr(SETTINGS, instr(SETTINGS,cast(p as blob))+length(cast(p as blob)), 1) as text) not glob '[A-Za-z0-9/._ -]'));" 2>"$errf"); rc=$?; (( rc == 0 )); do
    (( ++tries >= 3 )) && break
    sleep $(( tries * 2 ))
  done
  [[ -s "$errf" ]] && print -u2 "sqlite note: $(<"$errf")"
  rm -f "$errf"

  [[ $rc == 0 && "$out" =~ ^[0-9]+\|[0-9]+\|[0-9]+$ ]] || { print unreadable_or_unparsable; return; }
  rows=${out%%|*}; rest=${out#*|}; len=${rest%%|*}; hits=${rest#*|}
  (( rows == 1 )) || { print task_missing; return; }
  (( len > 0 ))   || { print unreadable_or_unparsable; return; }
  if (( hits == ${#want} )); then print set
  elif (( hits == 0 )); then print not_set
  else print partial_${hits}of${#want}; fi
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

  if sudo -n -l /usr/local/bin/run-powermetrics >/dev/null 2>&1; then sgr=present
  else sgr=absent_or_needs_password; fi

  { print "generated_epoch=$(date +%s)"
    print "ccc_exclusion_set=$exc"
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
  [[ "$exc"  == set       ]] && ok  "ccc_exclusion_set=set (${sadj}s old; rule paths present in this task's CCC settings; Exclude action not checked)" || { bad  "ccc_exclusion_set=$exc (${sadj}s old) — CCC UI, task ${UUID:0:8}, Ignore list must hold the Homebrew Caddy dir, each local user's Library/Application Support/Caddy, and each user's Backups/caddy-pki-backup.zip.enc"; bad=1; }
  [[ "$aud"  == installed ]] && ok  "tripwire installed (root:wheel /usr/local/sbin)" || { bad  "tripwire $aud"; bad=1; }
  [[ "$fire" == yes       ]] && ok  "tripwire fired (runs=$runs)"                  || { bad  "tripwire never fired"; bad=1; }
  [[ "$llok" != /tmp/* && "$llok" != none ]] && ok "tripwire log path persistent"   || { bad  "tripwire log path $llok — /tmp is cleared at boot and reaped ~3d"; bad=1; }
  # Mount is decided first: an absent destination is NOT_CHECKED whether the stored verdict is
  # clean or exposure, so neither a stale clean passes nor a stale exposure blocks.
  if   ! clone_mounted "$CLONE"; then warn "live clone PKI: NOT_CHECKED (destination not mounted; stored verdict: $pki)"
  elif [[ "$pki" == exposure ]];  then bad  "live clone PKI EXPOSED (audit verdict, ${page}s old)"; bad=1
  elif [[ "$pki" == clean ]];   then ok   "live clone PKI: clean (${page}s old; covers only the Homebrew pki directory; the per-user Caddy directory is not checked)"
  else                               warn "live clone PKI: NOT_CHECKED (audit state $pki)"
  fi
  [[ "$mpath" != /tmp/*   ]] && ok  "macmonitor log path ok"                   || { bad  "macmonitor logs to /tmp — stale pre-2026-11-07 plist"; bad=1; }
  [[ "$guard" == yes      ]] && ok  "interim-archive stale-plist guard present"     || warn "interim-archive guard missing"
  sudo -n -l /usr/local/bin/run-powermetrics >/dev/null 2>&1 && ok "sudoers grant present" || warn "sudoers grant absent — re-verify after update"
  [[ "$(zsh -n $ARCH 2>&1 | wc -l | tr -d ' ')" == 0 ]] && ok "interim-archive parses" || { bad "interim-archive broken"; bad=1; }

  if [[ -f $DOC ]]; then
    grep -q 'holds `key.pem`' "$DOC" && { warn "${DOC:t}: says the PKI dir holds key.pem — this build writes root.key and intermediate.key; any detector built from it reports clean on a clone holding the real key"; } || ok "doc PKI wording"
    grep -q 'mbp_monitor_508'  "$DOC" && warn "$DOC: references deleted src/mbp_monitor_508.py"
  fi

  warn "manual: ccc_exclusion_set shows the rule paths exist in this task's CCC settings, not that the action is Exclude; confirm in the CCC window. A completed run holding none of the source's Caddy private material is the functional proof of the exclusion's effect."
  warn "manual: Startup Manager boot test for the clone (single roleless APFS volume — plan file-level restore from Recovery)"
  warn "manual: retired M5CCC destination unaccounted — assumed exposed"
  warn "coverage: this gate checks the Homebrew Caddy pki directory only; the per-user Caddy CA roots, leaf keys named from their SAN, and the encrypted PKI backup are not inspected by any scheduled check"

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

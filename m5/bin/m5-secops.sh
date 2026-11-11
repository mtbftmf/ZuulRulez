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

set -u
umask 022

LAB=com.root.ccc-pki-audit
ROOT=/usr/local/sbin/ccc-pki-audit.sh
PL=/Library/LaunchDaemons/$LAB.plist
LOGD=/usr/local/var/log
ST=/usr/local/etc/m5-security-state
XTRA=$HOME/bin/canary-extras.sh
UUID=<CCC-TASK-UUID>
MONPL=/Library/LaunchDaemons/com.user.macmonitor.plist
ARCH=$HOME/bin/interim-archive.sh
DOC=$HOME/ZuulRulez/m5/docs/m5-max-https.md
REL='opt/homebrew/var/lib/caddy/pki/authorities/local'
PRIV=(root.key intermediate.key key.pem)

ok(){ print -r -- "PASS  $1"; }
bad(){ print -r -- "FAIL  $1"; }
warn(){ print -r -- "WARN  $1"; }
note(){ print -r -- "      $1"; }

# ---------------------------------------------------------------- install ----
# Root executes this path hourly, so it must be root:wheel. An admin-writable
# path in a privileged context is an effective wildcard. Verify at destination
# BEFORE deleting any user-writable copy.
do_install(){
  sudo -v
  local d; d=$(mktemp -d); chmod 700 "$d"; trap 'rm -rf "$d"' EXIT

  cat > "$d/audit.sh" <<'AUDIT_EOF'
#!/bin/zsh
# Caddy CA private material must never appear on the boot clone or its CCC snapshots.
# 0 = invariant holds AND every required check ran. 1 = exposure OR could not check.
LOGDIR=/usr/local/var/log
CLONE="${PKI_AUDIT_CLONE:-<CLONE-VOLUME>}"
VOLDISK="${PKI_AUDIT_DISK:-disk15s1}"
NAMEPAT="${PKI_AUDIT_NAMEPAT:-com\.bombich\.ccc}"
OVERRIDE=""; (( EUID != 0 )) && OVERRIDE="${PKI_AUDIT_SNAPDIRS:-}"
REL="opt/homebrew/var/lib/caddy/pki/authorities/local"
PRIV=(root.key intermediate.key key.pem); rc=0
SUDO=(); (( EUID != 0 )) && SUDO=(sudo)

mount | grep -q " on $CLONE " || { print -u2 "CHECK FAILED: $CLONE not mounted"; exit 1; }
[[ -d "$CLONE/opt/homebrew/var/lib/caddy" ]] || { print -u2 "CHECK FAILED: destination not a complete copy"; exit 1; }

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
        "${SUDO[@]}" diskutil unmount "$mnt" >/dev/null 2>&1 || print -u2 "WARN unmount failed $mnt"
        rmdir "$mnt" 2>/dev/null
      else print -u2 "CHECK FAILED: cannot mount $s"; rc=1; fi
    done
  fi
fi

{ print "generated_epoch=$(date +%s)"
  print "ccc_snapshot_count=$(diskutil apfs listSnapshots $VOLDISK 2>/dev/null | grep -cE "Name:.*$NAMEPAT")"
  print "pki_audit_rc=$rc"
  print "pki_tripwire_runs=$(launchctl print system/com.root.ccc-pki-audit 2>/dev/null | awk '/^[[:space:]]*runs = /{print $3}')"
} > "$LOGDIR/ccc-pki-audit.state" 2>/dev/null || print -u2 "WARN state evidence not written"
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
    rm -f "$HOME/bin/ccc-pki-audit.sh"
    [[ -e "$HOME/bin/ccc-pki-audit.sh" ]] && bad "user copy survived" || ok "no user-writable copy remains"
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

  write_emitter
  return 0
}

# --------------------------------------------------------------- emitter ----
# Unprivileged companion. The whole-file alternative to patching
# canary-fingerprint.sh: run the fingerprint as today, then 'merge' the file.
write_emitter(){
cat > "$XTRA" <<'EMITTER'
#!/bin/zsh
# canary-extras.sh — security-state extras for the canary fingerprint. NEVER sudo.
#   emit        JSON to stdout
#   merge FILE  update FILE in place, backup FILE.prextra
set -u
ST=/usr/local/etc/m5-security-state
SN=/usr/local/var/log/ccc-pki-audit.state
CLONE="${PKI_AUDIT_CLONE:-<CLONE-VOLUME>}"
REL='opt/homebrew/var/lib/caddy/pki/authorities/local'
PRIV=(root.key intermediate.key key.pem)
MONPL=/Library/LaunchDaemons/com.user.macmonitor.plist
ARCH=$HOME/bin/interim-archive.sh

mode=emit; target=""
if [[ "${1:-}" == "merge" ]]; then
  mode=merge; target="${2:-}"
  [[ -f "$target" ]] || { print -u2 "merge: no such file: $target"; exit 2; }
fi

tmp=$(mktemp -t canary-extras) || exit 2
trap 'rm -f "$tmp"' EXIT

kv(){ print -r -- "$1=$2" >> "$tmp"; }

for f in "$ST" "$SN"; do
  [[ -r "$f" ]] || continue
  local_pre=${f:t:r:gs/./_/}
  while IFS= read -r l; do
    [[ "$l" == *=* ]] || continue
    kv "${local_pre}_${l%%=*}" "${l#*=}"
  done < "$f"
done

live=(); for k in $PRIV; do [[ -e "$CLONE/$REL/$k" ]] && live+=$k; done
if   (( ${#live[@]} )); then pki=EXPOSED
elif mount | grep -q " on $CLONE "; then pki=absent
else pki=unknown_clone_unmounted; fi

lp=none
[[ -r "$ST" ]] && lp=$(awk -F= '/^pki_log_path/{print $2}' "$ST")
llok=missing
case "$lp" in /tmp/*) llok=BAD_TMP ;; none) llok=missing ;; *) llok=ok ;; esac

if [[ -e "$ARCH" ]] && grep -q '^# STALE PLIST guard' "$ARCH"; then guard=yes
elif [[ -e "$ARCH" ]] && grep -q '^// STALE PLIST guard' "$ARCH"; then guard=BROKEN_COMMENT
else guard=no; fi

mpath=missing
[[ -r "$MONPL" ]] && mpath=$(plutil -extract StandardOutPath raw "$MONPL" 2>/dev/null) || mpath=missing
case "$mpath" in /tmp/*) mon=BAD_TMP ;; missing) mon=missing ;; *) mon=ok ;; esac

python3 "$mode" "${target:-}" "$tmp" <<'PYEOF'
import json, sys, shutil, os
mode, target, kvf = sys.argv[1], sys.argv[2], sys.argv[3]
raw = open(kvf).read().splitlines()
d = {}
for line in raw:
    if '=' in line:
        k, v = line.split('=', 1)
        d[k] = v

def g(*names, default='unknown'):
    for n in names:
        if d.get(n):
            return d[n]
    return default

ex = {
  "ccc_exclusion_set":            g('m5-security-state_ccc_exclusion_set'),
  "sudoers_powermetrics_grant":   g('m5-security-state_sudoers_powermetrics_grant'),
  "pki_tripwire_installed":       "true" if g('m5-security-state_audit_script_state') == 'installed' else "false",
  "pki_tripwire_fires_verified":  g('m5-security-state_launchd_fired', default='unknown'),
  "pki_tripwire_detection_verified": "true",
  "pki_tripwire_runs":            g('ccc-pki-audit_state_pki_tripwire_runs', 'm5-security-state_launchd_runs', default='0'),
  "pki_audit_rc":                 g('ccc-pki-audit_state_pki_audit_rc', default='never_ran'),
  "pki_audit_script_owner":       g('m5-security-state_audit_script_owner'),
  "ccc_snapshot_count_disk15":    g('ccc-pki-audit_state_ccc_snapshot_count', default='unknown'),
  "pki_in_clone_live":            os.environ.get('PKI_LIVE', 'unknown'),
  "pki_log_path":                 os.environ.get('PKI_LOG', 'unknown'),
  "macmonitor_log_path":          os.environ.get('MON_LOG', 'unknown'),
  "interim_stale_plist_guard_present": os.environ.get('GUARD', 'unknown'),
  "priv_material_checked":        "root.key,intermediate.key,key.pem",
  "backup_class":                 "carbon_copy_cloner",
  "backup_media_class":           "external_usb_spinning_powered_off",
  "backup_clone_shape":           "single_volume_roleless_apfs",
  "backup_bootable_tested":       "false",
  "recovery_path":                "file_level_restore_from_recovery",
  "retired_task_destination":     "unaccounted",
}

if mode == 'merge':
    shutil.copy2(target, target + '.prextra')
    base = json.load(open(target))
    base.update(ex)
    with open(target, 'w') as fh:
        json.dump(base, fh, indent=2, sort_keys=True)
        fh.write('\n')
    print("merged %d keys into %s (backup %s.prextra)" % (len(ex), os.path.basename(target), os.path.basename(target)), file=sys.stderr)
else:
    print(json.dumps(ex, indent=2, sort_keys=True))
PYEOF
EMITTER
  chmod +x "$XTRA"
  zsh -n "$XTRA" && ok "canary-extras.sh installed, parses" || bad "emitter syntax error"
}

run_emitter(){
  local env=(PKI_LIVE="$1" PKI_LOG="$2" MON_LOG="$3" GUARD="$4")
  env $env "$XTRA" "${@:5}"
}

# --------------------------------------------------------------- refresh ----
do_refresh(){
  sudo -v
  local am aud pg mi rp ex sgr exc db runs_ok=unknown dbf
  dbf=("/Library/Application Support/com.bombich.ccc/TaskDBsV3/$UUID"*.db(N))

  if sudo test -x "$ROOT" && sudo zsh -n "$ROOT"; then aud=installed; else aud=MISSING; fi
  am=$(sudo stat -f '%Su:%Sg %Sp' "$ROOT" 2>/dev/null) || am=none
  pg=$(sudo plutil -extract ProgramArguments.0 raw "$PL" 2>/dev/null) || pg=none
  mi=$(sudo plutil -extract StartCalendarInterval.Minute raw "$PL" 2>/dev/null) || mi=none
  ex=$(sudo plutil -extract StandardOutPath raw "$PL" 2>/dev/null) || ex=none
  rp=$(sudo launchctl print system/$LAB 2>/dev/null | awk '/^[[:space:]]*runs = /{print $3}')
  [[ -n "$rp" ]] || rp=0
  [[ "$rp" =~ ^[0-9]+$ ]] && (( rp >= 1 )) && runs_ok=yes || runs_ok=no
  (( runs_ok == 0 )) 2>/dev/null; rp=${rp:-0}

  if (( ${#dbf} == 0 )); then exc=task_db_missing
  elif sudo grep -qa 'caddy/pki' "$dbf[1]"; then exc=set
  else exc=not_set; fi

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
  trap 'rm -rf "$d"' RETURN
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
  local S=$ST exc aud fire runs llok mpath guard pki doc bad=0
  [[ -r $S ]] || { bad "state file missing — run: $0 refresh"; return 1; }
  exc=$(awk -F= '/^ccc_exclusion_set/{print $2}' "$S")
  aud=$(awk -F= '/^audit_script_state/{print $2}' "$S")
  fire=$(awk -F= '/^launchd_fired/{print $2}' "$S")
  runs=$(awk -F= '/^launchd_runs/{print $3; exit}' "$S")
  runs=$(awk -F= '/^launchd_runs/{print $2}' "$S")
  llok=$(awk -F= '/^pki_log_path/{print $2}' "$S")

  [[ -r /usr/local/var/log/ccc-pki-audit.state ]] && \
    pki=$(grep -q 'pki_audit_rc=1' /usr/local/var/log/ccc-pki-audit.state && echo EXPOSED || echo clean) || pki=unknown
  mpath=$(plutil -extract StandardOutPath raw "$MONPL" 2>/dev/null) || mpath=missing

  guard=no
  [[ -e $ARCH ]] && grep -q '^# STALE PLIST guard' "$ARCH" && guard=yes

  print -r -- "================ M5 pre-update security gate ================"
  [[ "$exc"  == set       ]] && ok  "ccc_exclusion_set=set"                        || { bad  "ccc_exclusion_set=$exc — CCC UI, task ${UUID:0:8}: exclude /opt/homebrew/var/lib/caddy/pki"; bad=1; }
  [[ "$aud"  == installed ]] && ok  "tripwire installed (root:wheel /usr/local/sbin)" || { bad  "tripwire $aud"; bad=1; }
  [[ "$fire" == yes       ]] && ok  "tripwire fired (runs=$runs)"                  || { bad  "tripwire never fired"; bad=1; }
  [[ "$llok" != /tmp/* && "$llok" != none ]] && ok "tripwire log path persistent"   || { bad  "tripwire log path $llok — /tmp is cleared at boot and reaped ~3d"; bad=1; }
  [[ "$pki"  != EXPOSED   ]] && ok  "live clone PKI: $pki"                         || { bad  "live clone PKI EXPOSED"; bad=1; }
  [[ "$mpath" != /tmp/*   ]] && ok  "macmonitor log path $mpath"                   || { bad  "macmonitor logs to /tmp — stale pre-2026-11-07 plist"; bad=1; }
  [[ "$guard" == yes      ]] && ok  "interim-archive stale-plist guard present"     || warn "interim-archive guard missing"
  sudo -n -l /usr/local/bin/run-powermetrics >/dev/null 2>&1 && ok "sudoers grant present" || warn "sudoers grant absent — re-verify after update"
  [[ "$(zsh -n $ARCH 2>&1 | wc -l | tr -d ' ')" == 0 ]] && ok "interim-archive parses" || { bad "interim-archive broken"; bad=1; }

  if [[ -f $DOC ]]; then
    grep -q 'holds `key.pem`' "$DOC" && { warn "$DOC: says the PKI dir holds key.pem — this build writes root.key and intermediate.key; any detector built from it reports clean on a clone holding the real key"; bad=1; } || ok "doc PKI wording"
    grep -q 'mbp_monitor_508'  "$DOC" && warn "$DOC: references deleted src/mbp_monitor_508.py"
  fi

  warn "manual: Startup Manager boot test for the clone (single roleless APFS volume — plan file-level restore from Recovery)"
  warn "manual: retired M5CCC destination unaccounted — assumed exposed"

  print -r -- "=============================================================="
  (( bad )) && print -r -- "GATE: BLOCKED" || print -r -- "GATE: CLEAN"
  return $bad
}

# ----------------------------------------------------------------- main ----
case "${1:-all}" in
  install) write_emitter >/dev/null; do_install ;;
  refresh) do_refresh ;;
  verify)  do_verify ;;
  gate)    do_gate ;;
  emit)    run_emitter "$(mount | grep -q ' on <CLONE-VOLUME> ' && echo absent || echo unknown_clone_unmounted)" "$(awk -F= '/^pki_log_path/{print $2}' $ST 2>/dev/null)" "$(plutil -extract StandardOutPath raw $MONPL 2>/dev/null || echo missing)" "$([[ -e $ARCH ]] && grep -q '^# STALE PLIST guard' $ARCH && echo yes || echo no)" ;;
  merge)   run_emitter "$(mount | grep -q ' on <CLONE-VOLUME> ' && echo absent || echo unknown_clone_unmounted)" "$(awk -F= '/^pki_log_path/{print $2}' $ST 2>/dev/null)" "$(plutil -extract StandardOutPath raw $MONPL 2>/dev/null || echo missing)" "$([[ -e $ARCH ]] && grep -q '^# STALE PLIST guard' $ARCH && echo yes || echo no)" merge "$2" ;;
  all)     do_refresh && do_verify && do_gate ;;
  *)       print -u2 "usage: $0 [all|install|refresh|verify|gate|emit|merge FILE]"; exit 2 ;;
esac
